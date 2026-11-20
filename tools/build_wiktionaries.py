#!/usr/bin/env python3
"""Build every fully downloaded snapshot; publish verified extreme-XZ blobs."""
import sys as _prepared_bootstrap_sys
if _prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')=='1':
    _prepared_bootstrap_sys.path=[_prepared_bootstrap_sys._stdlib_dir,
                                  _prepared_bootstrap_sys._stdlib_dir+'/lib-dynload']
import argparse
import errno
import bz2
try:
    from compression import zstd
except ImportError:
    zstd = None
import concurrent.futures
from collections import defaultdict, deque
from contextlib import contextmanager, ExitStack
import fcntl
import gzip
import hashlib
import inspect
import json
import os
import re
import resource
from pathlib import Path
import stat
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zlib
def sha256_file(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def prepared_metadata(reference):
    """Read one caller-selected immutable metadata descriptor with bracketing."""
    path=Path(reference['path'])
    if (not path.is_absolute() or any(p.is_symlink() for p in (path,*path.parents))
            or not path.is_file() or path.stat().st_uid!=os.geteuid()):
        raise ValueError('Unsafe prepared authorization metadata')
    before=path.stat()
    if not 0<before.st_size<=64*1024*1024:
        raise ValueError('Prepared metadata exceeds the existing seal bound')
    raw=path.read_bytes()
    after=path.stat()
    fields=('st_dev','st_ino','st_mode','st_size','st_mtime_ns','st_ctime_ns')
    if (any(getattr(before,k)!=getattr(after,k) for k in fields)
            or set(reference)!={'path','bytes','sha256'}
            or len(raw)!=reference['bytes'] or hashlib.sha256(raw).hexdigest()!=reference['sha256']):
        raise ValueError('Prepared metadata changed during authentication')
    return json.loads(raw)


class PreparedSourceGeneration:
    """Consume an explicitly parent-bound generation; never discover/rebuild one.

    This object is not a ready-marker policy. Its caller must authenticate the
    parent authorization descriptor against the existing attempt/config before
    constructing it. The default builder never constructs or installs a scope.
    """
    def __init__(self, record, *, source, build_identity, now_unix, context, _authenticated_roles=None):
        import extraction_cache as cache
        import copy
        if (record.get('schema') != 'wikidict.prepared-source-generation.v1'
                or record.get('source') != source
                or record.get('build_identity') != build_identity
                or record.get('now_unix') != now_unix
                or record.get('context') != context):
            raise ValueError('Prepared generation does not match the original attempt')
        if build_identity.get('source')!=source.get('fingerprint'):
            raise ValueError('Prepared build identity belongs to another qualified source')
        self.record = copy.deepcopy(record)
        self.identity = copy.deepcopy(build_identity)
        record = self.record
        self.cache = cache
        self.retired = False
        if record.get('python_tooling')!=build_identity.get('python_tooling'):
            raise ValueError('Prepared original Python catalog differs from build identity')
        bootstrap=globals().get('_PREPARED_BOOTSTRAP_PYTHON_GUARD')
        self._python_stamps = (dict(bootstrap._python_stamps)
            if isinstance(bootstrap,PreparedSourceGeneration) and bootstrap.record['python']==record['python'] else {})
        self._library_stamps = {}
        self._seal = None
        self.root = Path(record['expander'])
        self.dump = Path(record['dump'])
        self.workspace = Path(record['workspace'])
        if (record['workspace_state'].get('source')!=self.identity['source']
                or record['workspace_state'].get('now_unix')!=record['now_unix']):
            raise ValueError('Prepared source and shard epoch differ')
        if record['seal_archive']['sha256'] != record['seal_sha256']:
            raise ValueError('Retained seal does not match the original generation')
        prepared_metadata(record['seal_archive'])
        retained=record.get('retained_dispatch')
        if _authenticated_roles is None:
            self.retained_roles = (RetainedNativeToolRoles.from_prepared_dispatch(retained)
                                   if retained is not None else None)
        else:
            # Parent-local reuse only: its complete dispatch was independently
            # authenticated in this call. Children still reconstruct normally.
            if (not isinstance(_authenticated_roles,RetainedNativeToolRoles)
                    or retained is None or _authenticated_roles.prepared_dispatch()!=retained):
                raise ValueError('Authenticated retained roles differ from prepared generation')
            _authenticated_roles.require_unchanged()
            self.retained_roles = _authenticated_roles
        expected_root=(self.retained_roles.initial_sealed_context[0] if self.retained_roles is not None
                       else self.workspace / 'expander' / '.bundle-expander')
        if (self.root != expected_root
                or not self.workspace.is_absolute()
                or any(p.is_symlink() for p in (self.workspace, *self.workspace.parents))):
            raise ValueError('Prepared generation workspace differs')
        if self.retained_roles is not None:
            context=self.retained_roles.initial_sealed_context
            if (context!=(self.root,self.dump,record['seal_sha256'])
                    or self.retained_roles.records!=self.identity.get('native_tool_roles')):
                raise ValueError('Prepared readonly generation differs from retained selection')
            expected=dict(seal_sha256=record['seal_sha256'],dump=str(self.dump),
                build_inputs=self.identity,retained_expander_root=str(self.root))
            if self.retained_roles.closed_whole_execution is not None:
                expected['closed_whole_execution']=self.retained_roles.closed_whole_execution
            if record['workspace_state'].get('native_generation')!=expected:
                raise ValueError('Prepared retained state differs from its original binding')
        self.tools = {}
        if set(record['tools']) != set(BLOB_TOOL_NAMES):
            raise ValueError('Incomplete prepared native tool inventory')
        for name, expected in record['tools'].items():
            origin=(self.retained_roles.records[name]['artifact'] if self.retained_roles is not None else None)
            path = Path(expected['path'])
            allowed={str(self.workspace / 'native-blob-tools' / 'bin' / name)}
            if origin is not None:allowed.add(origin['path'])
            if (str(path) not in allowed or (origin is not None and expected['sha256']!=origin['sha256'])):
                raise ValueError('Prepared tool escaped its original generation')
            if (not isinstance(expected['stamp'],list) or len(expected['stamp'])!=6
                    or any(type(value) is not int for value in expected['stamp'])
                    or not isinstance(expected['sha256'],str)
                    or re.fullmatch('[0-9a-f]{64}',expected['sha256']) is None):
                raise ValueError('Invalid original prepared tool proof')
            # prepare_blob_tools already hashed this exact private inode and
            # recorded its post-read stamp. Reopen that proof, not another copy
            # or another full tool hash in each parent/child authorization.
            tool=object.__new__(PreparedBlobTool)
            tool.path=path;tool.stamp=tuple(expected['stamp']);tool.sha256=expected['sha256']
            tool.require_unchanged()
            if self.retained_roles is not None:
                if self.retained_roles.bind_input(path)['sha256']!=tool.sha256:
                    raise ValueError('Prepared retained tool bytes differ')
                tool.retained_roles=self.retained_roles
                self.retained_roles.tools[name]=tool
            self.tools[name] = tool
        self.require_unchanged()

    def require_python(self, *, force=False):
        if not hasattr(self,'_python_stamps'):self._python_stamps={}
        tooling=self.record.get('python_tooling')
        if tooling is not None:
            selected=bootstrap_python_tooling(tooling)
            if (selected is None or selected.spec!=tooling
                    or (_prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')=='1'
                        and sys.path!=[sys._stdlib_dir,sys._stdlib_dir+'/lib-dynload'])):
                raise ValueError('Prepared selected Python import authority changed')
            selected.require_unchanged()
            return
        if _prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')=='1':
            standard=[sys._stdlib_dir,sys._stdlib_dir+'/lib-dynload']
            if sys.path not in (standard,standard+[str(PROJECT/'tools')]):
                raise ValueError('Prepared child import search roots changed')
        inventory = self.record['python']
        # Keep all non-test Python, including lazy validators and orchestration.
        # No source exclusion is inferred from whether a helper is imported yet.
        from importlib.machinery import EXTENSION_SUFFIXES
        actual=set()
        for path in (PROJECT/'tools').rglob('*'):
            relative=path.relative_to(PROJECT/'tools')
            # The bound absent pycache prefix makes old __pycache__ inert.
            # Direct sourceless modules/extensions remain import candidates.
            if '__pycache__' in relative.parts:continue
            if path.is_symlink() or path.name.endswith(('.pyc',*EXTENSION_SUFFIXES)):
                raise ValueError('Unbound Python import artifact in consumed helper root')
            if path.is_file() and path.suffix=='.py' and not path.name.startswith('test_'):
                actual.add(path.relative_to(PROJECT).as_posix())
        if actual != set(inventory):
            raise ValueError('Prepared generation Python membership changed')
        for name, expected in inventory.items():
            path = PROJECT / name
            if (not name.startswith('tools/') or path.suffix != '.py'
                    or path.name.startswith('test_')
                    or any(p.is_symlink() for p in (path, *path.parents))):
                raise ValueError('Invalid consumed Python path')
            from importlib.util import cache_from_source
            cached = Path(cache_from_source(str(path)))
            if os.path.lexists(cached):
                raise ValueError('Prepared source can consume unbound Python bytecode')
            before = path.stat()
            stamp = (before.st_dev, before.st_ino, before.st_mode, before.st_size,
                     before.st_mtime_ns, before.st_ctime_ns)
            previous=self._python_stamps.get(name)
            if (stat.S_IMODE(before.st_mode) != expected['mode']
                    or (previous is not None and previous!=stamp)
                    or ((previous is None or force) and sha256_file(path) != expected['sha256'])):
                raise ValueError('Consumed Python helper changed: ' + name)
            after = path.stat()
            if stamp != (after.st_dev, after.st_ino, after.st_mode, after.st_size,
                         after.st_mtime_ns, after.st_ctime_ns):
                raise ValueError('Python helper changed during authentication')
            self._python_stamps[name]=stamp
        helper_names={Path(name).stem for name in inventory if Path(name).parent.as_posix()=='tools'}
        for module_name,module in tuple(sys.modules.items()):
            origin = getattr(module, '__file__', None)
            if not origin:
                continue
            path = Path(origin).absolute()
            if module_name in helper_names or path.is_relative_to(PROJECT / 'tools'):
                if not path.is_relative_to(PROJECT) or path.suffix != '.py' or path.relative_to(PROJECT).as_posix() not in inventory:
                    raise ValueError('Loaded project helper is outside the bound Python inventory')

    def require_library(self, name, expected, *, force=False):
        path=Path(name)
        before=self.cache._full_stamp(path.stat())
        prior=self._library_stamps.get(name)
        if (prior is not None and prior!=before) or ((prior is None or force) and sha256_file(path)!=expected):
            raise ValueError('Prepared native runtime library changed')
        if self.cache._full_stamp(path.stat())!=before:
            raise ValueError('Native runtime library changed during authentication')
        self._library_stamps[name]=before

    def require_unchanged(self, *, full_context=True, force=False):
        self.require_python(force=force)
        if self.retired:
            raise ValueError('Prepared native generation has already been finalized')
        if getattr(self,'retained_roles',None) is not None:self.retained_roles.require_unchanged()
        seal = (self.cache.frozen_runtime_context(self.root, self.dump, self.record['seal_sha256'],
                    **getattr(getattr(self,'retained_roles',None),'_closed_native_context_options',{}))
                if full_context or self._seal is None else self._seal)
        if seal is None:
            raise ValueError('Prepared source authorization has no complete generation seal')
        self._seal=seal
        for tool in self.tools.values():
            tool.require_unchanged()
            if force:
                if sha256_file(tool.path)!=tool.sha256:
                    raise ValueError('Prepared tool final content differs from its original proof')
                tool.require_unchanged()
            for name, expected in self.record['tools'][tool.path.name]['libraries']:
                self.require_library(name,expected,force=force)
        # The seal already hashed native assets. Recheck live linked libraries,
        # not the corpus-sized assets or the current compiler graph.
        for name, expected in seal['identity']['runtime_libraries']['libraries']:
            self.require_library(name,expected,force=force)
        unicode=seal['identity']['producer']['unicode']
        if full_context or force:
            if self.cache.unicode_case_identity() != unicode:
                raise ValueError('Prepared worker Unicode runtime changed')
            if self.cache.tool_identity(self.root/'dict-bundle-expander') != seal['identity']['runtime_libraries']:
                raise ValueError('Prepared worker library resolution changed')
        for item in unicode['libraries']:
            self.require_library(item['path'],item['sha256'],force=force)
        if read_build_envelope(self.workspace / 'state.json') != self.record['workspace_state']:
            raise ValueError('Prepared generation shard state changed')
        return seal

    def require_identity(self, identity):
        if identity != self.identity:
            raise ValueError('Prepared attempt would mix original and current build inputs')
        self.require_unchanged(full_context=False)

    def finalize(self, staging):
        self.require_unchanged(force=True)
        if (not (staging / VERIFIED_MARKER).is_file()
                or (staging / VERIFIED_MARKER).read_text() != VERIFIED_CONTENT
                or read_build_envelope(staging / BUILD_IDENTITY_NAME) != self.identity):
            raise ValueError('Prepared generation retirement lacks verified original staging')
        # A retired scope authorizes only Python publication finalization. It can
        # never reopen tools, prepare a worker, or consume another shard prefix.
        self.retired = True


_PREPARED_SOURCE = threading.local()
_PREPARED_BOOTSTRAP_PYTHON_GUARD = None
COMPLETED_EXPANDER_PROOF = '.completed-expander.json'




def require_build_source(identity):
    generation = getattr(_PREPARED_SOURCE, 'value', None)
    if generation is None:
        scope = identity.get('retained_runtime_source')
        if scope is not None:
            source, production, selected = retained_runtime_fingerprints(scope, identity['native_tool_roles'])
            if selected != identity.get('python_tooling') or source != identity['source']:
                raise ValueError('Retained production Python source changed; refusing publication')
            return source, production
        elif source_fingerprint() != identity['source']:
            raise ValueError('Compiler source changed during build; refusing publication')
    elif generation.retired:
        generation.require_python(force=True)
        if identity != generation.identity:
            raise ValueError('Publication differs from the finalized original generation')
    else:
        generation.require_identity(identity)


def prepared_child_imports():
    """Authenticate original Python before adding project imports in this CLI."""
    if _prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')!='1':return
    global PROJECT,_PREPARED_BOOTSTRAP_PYTHON_GUARD
    PROJECT=(_PYTHON_TOOLING.source_root if _PYTHON_TOOLING is not None else Path(__file__).resolve().parent.parent)
    reference=json.loads(os.environ['WIKIDICT_PREPARED_SOURCE_ATTEMPT'])
    start=prepared_metadata(reference)
    control=start.get('prepared_source_control',{})
    cfg=control.get('configuration',{})
    prefix=str(Path(reference['path']).parent/'unwritten-python-cache')
    if (not sys.flags.isolated or not sys.flags.no_site
            or control.get('version')!=1 or cfg.get('prepared_source_custody') is not True
            or control.get('bytecode_prefix')!=prefix or sys.pycache_prefix!=prefix
            or os.path.lexists(prefix)
            or (cfg['source'].get('root') is not None and Path(cfg['source']['root'])!=PROJECT)):
        raise ValueError('Prepared CLI bootstrap differs from its bound attempt')
    inventory=prepared_metadata(cfg['source']['inventory'])
    if inventory.get('head')!=cfg['source']['head']:
        raise ValueError('Prepared CLI Python inventory belongs to another source')
    python={}
    for name,reference in inventory['files'].items():
        if name.startswith('tools/') and name.endswith('.py') and not Path(name).name.startswith('test_'):
            if reference['path']!=str(PROJECT/name):
                raise ValueError('Prepared CLI Python path belongs to another source root')
            python[name]=dict(sha256=reference['sha256'],mode=inventory['modes'][name])
    guard=object.__new__(PreparedSourceGeneration)
    guard.record=dict(python=python)
    if _PYTHON_TOOLING is not None:
        if cfg.get('python_tooling')!=_PYTHON_TOOLING.spec:
            raise ValueError('Prepared selected Python catalog differs from attempt')
        guard.record['python_tooling']=_PYTHON_TOOLING.spec
    guard.require_python(force=True)
    _PREPARED_BOOTSTRAP_PYTHON_GUARD=guard
    # Stdlib stays ahead of tools, including for future lazy imports. No cwd,
    # PYTHONPATH or site-packages search path is silently restored.
    if _PYTHON_TOOLING is None:sys.path.append(str(PROJECT/'tools'))


def prepared_watchdog_options(options):
    if _PYTHON_TOOLING is not None:
        _PYTHON_TOOLING.require_unchanged()
        if (not sys.flags.isolated or not sys.flags.no_site or not sys.dont_write_bytecode
                or not sys.pycache_prefix or not Path(sys.pycache_prefix).is_absolute()
                or os.path.lexists(sys.pycache_prefix)):
            raise ValueError('Selected Python watchdog requires its original isolated absent-prefix startup')
        prepared=(['-X','wikidict_prepared_source=1'] if _prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')=='1' else [])
        return dict(options,argv=['-I','-S','-B',*prepared,'-X','pycache_prefix='+sys.pycache_prefix,*sys.argv])
    if _prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')!='1':return options
    return dict(options,argv=['-I','-S','-B','-X','wikidict_prepared_source=1',
                              '-X','pycache_prefix='+sys.pycache_prefix,*sys.argv])


def prepared_metadata_ref(path):
    path=Path(path)
    before=path.stat()
    value=dict(path=str(path.absolute()),bytes=before.st_size,sha256=sha256_file(path))
    prepared_metadata(value)
    return value


def _publish_prepared_metadata_no_replace(temporary,path):
    # This producer is Linux-only. Atomic no-clobber rename avoids both a
    # partially visible JSON file and a post-publication hardlink/ctime change.
    import ctypes
    import errno
    library=ctypes.CDLL(None,use_errno=True)
    rename=getattr(library,'renameat2',None)
    if rename is None:
        raise OSError(errno.ENOSYS,'Atomic no-clobber metadata publication is unavailable',str(path))
    rename.argtypes=(ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint)
    rename.restype=ctypes.c_int
    if rename(-100,os.fsencode(temporary),-100,os.fsencode(path),1)!=0:
        number=ctypes.get_errno()
        raise OSError(number,os.strerror(number),str(path))


def write_prepared_metadata(path,value):
    # New names only. Keep the final name absent until every byte is closed.
    path=Path(path)
    temporary=path.with_name('.'+path.name+'.'+uuid.uuid4().hex+'.part')
    created=False
    try:
        with temporary.open('x') as stream:
            created=True
            json.dump(value,stream,sort_keys=True)
            stream.write('\n')
        _publish_prepared_metadata_no_replace(temporary,path)
    finally:
        if created:temporary.unlink(missing_ok=True)
    return prepared_metadata_ref(path)


def prepared_authorized_generation(configuration, start, launch_reference, *, retired=False):
    """Explicit import-prefix/controller API; no discovery constitutes authority."""
    if configuration.get('prepared_source_custody') is not True:
        raise ValueError('Prepared source custody was not explicitly selected')
    launch=prepared_metadata(launch_reference)
    authorization=launch.get('prepared_source_authorization')
    if (not isinstance(authorization,dict)
            or authorization.get('schema')!='wikidict.prepared-source-authorization.v1'
            or authorization.get('configuration')!=configuration
            or authorization.get('context')!=start['context']
            or authorization.get('attempt_start')!=start
            or authorization.get('decision')!='parent-verified-original-source'):
        raise ValueError('Prepared source parent authorization differs from this attempt')
    original=authorization.get('original_source_observation')
    if (not isinstance(original,dict) or original.get('qualified_head')!=configuration['source']['head']
            or original.get('producer_inventory')!=configuration['source'].get('inventory')
            or original.get('apps_acceptance') is not False
            or (configuration.get('retained_native_roles') is not None
                and original.get('current_head')!=configuration['source']['head'])):
        raise ValueError('Parent original source observation differs')
    record=prepared_metadata(authorization['generation'])
    if (record.get('python_tooling')!=configuration.get('python_tooling')
            or (record.get('retained_dispatch',{}).get('selection')!=configuration.get('retained_native_roles'))
            or record['source']!=configuration['source'] or record['context']!=start['context']
            or record['now_unix']!=configuration['now_unix']):
        raise ValueError('Prepared generation provenance changed')
    if retired:
        # The caller must additionally authenticate the explicit child final
        # receipt. Retired assets are not reopened or claimed present here.
        instance=object.__new__(PreparedSourceGeneration)
        import copy
        instance.record=copy.deepcopy(record)
        instance.identity=copy.deepcopy(record['build_identity'])
        instance.retired=True
        instance.tools={}
        instance.require_python()
    else:
        instance=PreparedSourceGeneration(record,source=configuration['source'],
            build_identity=record['build_identity'],now_unix=configuration['now_unix'],context=start['context'])
    instance.authorization=launch_reference
    instance.generation_reference=authorization['generation']
    return instance


class PreparedSourceRequest:
    """An optional existing-attempt handshake; default builds never enter it."""
    def __init__(self, reference):
        if _prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')!='1':
            raise ValueError('Prepared child lacks the bound interpreter bootstrap')
        self.reference=reference
        self.start=prepared_metadata(reference)
        control=self.start.get('prepared_source_control')
        if (not isinstance(control,dict) or control.get('version')!=1
                or type(control.get('configuration')) is not dict):
            raise ValueError('Missing explicit prepared source request')
        self.configuration=control['configuration']
        self.folder=Path(reference['path']).parent
        if Path(reference['path']).name!='start.json':
            raise ValueError('Prepared request is not the existing attempt start')
        prefix=control.get('bytecode_prefix')
        if (prefix!=str(self.folder/'unwritten-python-cache')
                or sys.pycache_prefix!=prefix or os.path.lexists(prefix)):
            raise ValueError('Prepared child did not start with the bound absent bytecode prefix')
        self.generation=None
        resume=control.get('resume')
        if resume is not None:
            old_start=prepared_metadata(resume['start'])
            if resume.get('finalization') is not None:
                raise ValueError('Finalized generation requires an explicit publication-only whole attempt')
            self.generation=prepared_authorized_generation(self.configuration,old_start,resume['authorization'])
            # An outer retry binds the same original generation before any
            # identity/workspace selection; it never performs a current probe.
            self.generation=self.await_authorization(self.generation.generation_reference)
            _PREPARED_SOURCE.value=self.generation

    def await_authorization(self, reference):
        from build_resource_limits import MAX_WATCHDOG_WALL_SECONDS
        timeout=self.configuration['build_timeout_seconds']
        if type(timeout) not in (int,float) or not 0<timeout<=MAX_WATCHDOG_WALL_SECONDS:
            raise ValueError('Prepared authorization lacks the selected finite build deadline')
        # The existing whole-build watchdog remains authoritative; do not add
        # a short handshake cutoff while the parent authenticates cold files.
        deadline=time.monotonic()+timeout
        launch_path=self.folder/'launch.json'
        pending_stamp = None
        while time.monotonic()<deadline:
            try:
                info = launch_path.lstat()
            except FileNotFoundError:
                pending_stamp = None
            else:
                # The parent publishes authorization by atomic replacement. Only cache a
                # pending decision. Every changed receipt still takes the authenticated path.
                stamp = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                if stamp != pending_stamp:
                    launch_ref=prepared_metadata_ref(launch_path)
                    launch=prepared_metadata(launch_ref)
                    auth=launch.get('prepared_source_authorization')
                    if auth is not None:
                        if auth.get('generation')!=reference:
                            raise ValueError('Parent authorized another prepared generation')
                        return prepared_authorized_generation(self.configuration,self.start,launch_ref)
                    pending_stamp = stamp
            time.sleep(.1)
        raise ValueError('Prepared source parent authorization did not complete')

    def require_retained_preparation(self, roles, workspace, identity, edition, date, expander_args):
        """Select blob tools before offering this exact adopted generation."""
        cfg=self.configuration
        context=roles.initial_sealed_context
        selection=roles.provenance()
        kind='closed_whole_execution' if roles.closed_whole_execution is not None else 'initial_sealed_generation'
        selection['dict-bundle-build'][kind]=getattr(roles,kind)
        if (self.generation is not None or expander_args is not None or context is None
                or (roles.initial_sealed_generation is None and roles.closed_whole_execution is None) or cfg.get('prepared_source_custody') is not True
                or cfg.get('retained_native_roles')!=selection
                or cfg.get('source',{}).get('fingerprint')!=identity['source']
                or cfg.get('date')!=date or set(cfg.get('edition_options',{}))!={edition}
                or workspace!=Path(cfg['output'])/edition/(date+'.shards')
                or prepared_metadata(self.reference)!=self.start
                or self.start.get('prepared_source_control',{}).get('configuration')!=cfg):
            raise ValueError('Pending retained preparation differs from its selected attempt')
        state=read_build_envelope(workspace/'state.json')
        binding=dict(seal_sha256=context[2],dump=str(context[1]),build_inputs=identity,retained_expander_root=str(context[0]))
        if roles.closed_whole_execution is not None:binding['closed_whole_execution']=roles.closed_whole_execution
        if (state.get('edition')!=edition or state.get('date')!=date
                or state.get('now_unix')!=cfg['now_unix'] or state.get('native_generation')!=binding):
            raise ValueError('Pending retained preparation differs from its adopted state')
        roles.require_unchanged()

    def offer(self, workspace, dump, tools, identity, now_unix):
        import extraction_cache as cache
        if self.generation is not None:
            self.generation.require_identity(identity)
            return self.generation
        cfg=self.configuration
        if (cfg.get('prepared_source_custody') is not True
                or identity['source']!=cfg['source']['fingerprint']
                or now_unix!=cfg['now_unix']):
            raise ValueError('Prepared source request differs from original inputs')
        retained=next((getattr(tool,'retained_roles',None) for tool in tools.values()
                       if getattr(tool,'retained_roles',None) is not None),None)
        if (cfg.get('retained_native_roles') is not None) != (retained is not None):
            raise ValueError('Prepared retained role selection differs from attempt')
        if retained is not None:
            retained.require_unchanged()
            if retained.initial_sealed_context is None:
                raise ValueError('Prepared retained tools have no adopted sealed context')
            if any(getattr(tool,'retained_roles',None) is not retained for tool in tools.values()):
                raise ValueError('Prepared tools mix retained selections')
            root=retained.initial_sealed_context[0]
        else:root=workspace/'expander'/'.bundle-expander'
        marker=root/COMPLETED_EXPANDER_PROOF
        if not marker.is_file():return None
        seal_reference=prepared_metadata_ref(marker)
        seal=cache.frozen_runtime_context(root,dump,seal_reference['sha256'],
            **getattr(retained,'_closed_native_context_options',{}))
        if seal is None:return None
        inventory=prepared_metadata(cfg['source']['inventory'])
        if inventory['head']!=cfg['source']['head']:
            raise ValueError('Prepared Python inventory belongs to another qualification')
        python={name:dict(sha256=ref['sha256'],mode=inventory['modes'][name])
                for name,ref in inventory['files'].items()
                if name.startswith('tools/') and name.endswith('.py') and not Path(name).name.startswith('test_')}
        bound_tools={}
        for name,tool in tools.items():
            tool.require_unchanged()
            libraries=tool.runtime_identity
            if retained is not None and libraries is None:
                libraries=cache.tool_identity(tool.path); tool.require_unchanged()
            if not isinstance(libraries,dict) or libraries['extractor_sha256']!=tool.sha256:
                raise ValueError('Prepared tool changed while binding libraries')
            bound_tools[name]=dict(path=str(tool.path),stamp=list(tool.stamp),sha256=tool.sha256,
                                  libraries=libraries['libraries'])
        # Preserve the already-hashed seal metadata once, not native payloads.
        archive=self.folder/'prepared-expander-seal.json'
        with archive.open('xb') as out:out.write(marker.read_bytes())
        archive_ref=prepared_metadata_ref(archive)
        if (archive_ref['bytes'],archive_ref['sha256'])!=(seal_reference['bytes'],seal_reference['sha256']):
            raise ValueError('Prepared seal changed while retaining metadata')
        record=dict(schema='wikidict.prepared-source-generation.v1',source=cfg['source'],
            build_identity=identity,now_unix=now_unix,context=self.start['context'],
            workspace=str(workspace),dump=str(dump),expander=str(root),
            workspace_state=read_build_envelope(workspace/'state.json'),python=python,tools=bound_tools,
            seal_sha256=seal_reference['sha256'],seal_archive=archive_ref,
            prepared_by_start=self.reference,
            tracked_process=prepared_metadata(prepared_metadata_ref(self.folder/'launch.json'))['identity'])
        if cfg.get('python_tooling') is not None:record['python_tooling']=cfg['python_tooling']
        if retained is not None:
            record['retained_dispatch']=retained.prepared_dispatch()
            if record['retained_dispatch']['selection']!=cfg['retained_native_roles']:
                raise ValueError('Prepared retained map differs from attempt')
        if retained is not None:
            verdict=prepared_figure_verdict(cfg)
            if verdict is not None:
                record['figure_validation']=verdict
                # Do not grow beyond the existing generation metadata bound.
                # Oversized optional proof simply takes normal parent replay.
                if len(json.dumps(record,sort_keys=True).encode())+1>64*1024*1024:
                    del record['figure_validation']
        # This is a request, not authority. The parent validates these bindings
        # and original source before authorizing, then the child reopens them.
        reference=write_prepared_metadata(self.folder/'prepared-generation.json',record)
        self.generation=self.await_authorization(reference)
        _PREPARED_SOURCE.value=self.generation
        return self.generation

    def finalize(self, generation, staging):
        generation.finalize(staging)
        reference=write_prepared_metadata(self.folder/'prepared-finalization.json',dict(
            schema='wikidict.prepared-source-finalization.v1',generation=generation.generation_reference,
            authorization=generation.authorization,attempt_start=self.reference,
            native_work_complete=True,publication_verified=False,
            staging_identity=generation.identity,seal_archive=generation.record['seal_archive']))
        return reference


@contextmanager
def prepared_source_request(reference):
    if getattr(_PREPARED_SOURCE,'request',None) is not None or getattr(_PREPARED_SOURCE,'value',None) is not None:
        raise ValueError('Nested prepared source request')
    request=PreparedSourceRequest(reference)
    _PREPARED_SOURCE.request=request
    try:
        yield request
    finally:
        _PREPARED_SOURCE.request=None
        _PREPARED_SOURCE.value=None


def bootstrap_python_tooling(selection=None):
    """Load only an explicitly authenticated tooling selector; preserve script origins."""
    import importlib.util
    if selection is None:
        count=sys.argv.count('--python-tooling-json')
        if count:
            if count!=1 or sys.argv.index('--python-tooling-json')+1>=len(sys.argv):
                raise ValueError('Invalid selected Python tooling CLI')
            selection=json.loads(sys.argv[sys.argv.index('--python-tooling-json')+1])
        elif 'wikidict_python_tooling' in sys.modules:
            active=getattr(sys.modules['wikidict_python_tooling'],'_ACTIVE',None)
            selection=active.spec if active is not None else None
    if selection is None:return None
    reference=selection['selector'];path=Path(reference['path'])
    if (not path.is_absolute() or str(path)!=os.path.normpath(str(path))
            or any(p.is_symlink() for p in (path,*path.parents))):
        raise ValueError('Unsafe Python tooling selector path')
    with path.open('rb') as stream:
        before=os.fstat(stream.fileno());data=stream.read();after=os.fstat(stream.fileno())
    fields=('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns','st_mode')
    if (not all(getattr(before,k)==getattr(after,k)==getattr(path.stat(),k) for k in fields)
            or len(data)!=reference['bytes'] or hashlib.sha256(data).hexdigest()!=reference['sha256']
            or stat.S_IMODE(before.st_mode)!=reference['mode'] or before.st_uid!=os.geteuid()):
        raise ValueError('Selected Python tooling selector changed')
    module=sys.modules.get('wikidict_python_tooling')
    if module is None:
        module=importlib.util.module_from_spec(importlib.util.spec_from_loader('wikidict_python_tooling',loader=None))
        module.__file__=str(path);sys.modules['wikidict_python_tooling']=module
        try:exec(compile(data,str(path),'exec'),module.__dict__)
        except BaseException:
            sys.modules.pop('wikidict_python_tooling',None);raise
    elif Path(module.__file__)!=path:
        raise ValueError('Different Python tooling selector is already imported')
    return module.select(selection,role='build_wiktionaries',origin=__file__)


_PYTHON_TOOLING=bootstrap_python_tooling()
prepared_child_imports()

from compress_blobs import compress, compress_many, compress_small_batch_keep, default_workers, verify_round_trip
from build_disk_limits import BUILD_DISK_RESERVE_BYTES, require_merge_disk_space, compressed_blob_size
from build_artifact_root import configure_artifact_root, artifact_path, remove_artifact_tree, unlink_artifact, execution_paths, refuse_execution_destinations, PRODUCER_SOURCE_FILES, PRODUCER_SOURCE_DIRECTORIES
from download_wiktionaries import digest, language_registry_snapshot, validate_item, write_language_registry, select_manifest_files, derived_registry_paths, load_input_manifest
import reviewed_nonlexical as nonlexical

PROJECT = _PYTHON_TOOLING.source_root if _PYTHON_TOOLING is not None else Path(__file__).resolve().parent.parent
SHARD_PAGES = 100_000


def selected_shard_pages(value=None):
    if value is None:
        return SHARD_PAGES
    if type(value) is not int or value <= 0:
        raise ValueError('Shard pages must be a positive integer')
    return value


def shard_page_options(value):
    selected_shard_pages(value)
    return {} if value is None else {'shard_pages': value}

SHARD_RETRIES = 3
SHARD_STATE_VERSION = 3
AUXILIARY_SNAPSHOT_NAMES = (
    'stylesheet-imports', 'site-info', 'site-statistics-format', 'category-statistics-format', 'commons-data', 'category-stats', 'interface-messages', 'category-tree',
    'wikibase-sitelinks', 'wikibase-entity-text', 'wikibase-entities',
    'wikibase-entity-terms', 'wikibase-page-links', 'language-fallbacks', 'language-names', 'date-numbering', 'file-metadata', 'page-language',
    'transclusion-redirects', 'namespace-registry', 'language-registry', 'magic-words', 'behavior-switches', 'image-options',
    'figure-siteinfo', 'figure-sizing', 'figure-sizing-raw', 'figure-sizing-site', 'figure-page-observations', 'parser-function-facts',
)
FIGURE_SNAPSHOT_FILES = {
    'figure-siteinfo': 'figure-siteinfo.raw.json',
    'figure-sizing': 'figure-sizing.json',
    'figure-sizing-raw': 'figure-sizing.raw.json',
    'figure-sizing-site': 'figure-sizing.site.json',
}
MAX_TOTAL_BUILD_WORKERS = 8
MAX_PIPELINE_WORKERS = 4
MAX_PAGE_EXPANSION_WORKERS = 8
MAX_EXPANSION_TIMEOUT_MS = 3_600_000
MAX_PAGE_INDEX_LINE_BYTES = 1024 * 1024
MAX_PAGE_COVERAGE_BYTES = 64 * 1024
MEMORY_PER_BUILD_WORKER = 1536 * 1024 * 1024
CPU_UTILIZATION_TARGET = 0.75
RESOURCE_ADMISSION_WAIT_SECONDS = 10 * 60
RESOURCE_ADMISSION_POLL_SECONDS = 5

def workspace_root(spec=None):
    if spec is None:
        return PROJECT
    if (not isinstance(spec,dict) or set(spec)!={'path','device','inode','uid','mode'}
            or not isinstance(spec['path'],str)
            or any(type(spec[key]) is not int for key in ('device','inode','uid','mode'))):
        raise ValueError('Invalid workspace directory identity')
    root=Path(spec['path'])
    if (not root.is_absolute() or str(root)!=os.path.normpath(str(root))
            or any(node.is_symlink() for node in (root,*root.parents)) or not root.is_dir()):
        raise ValueError('Workspace directory is not canonical and regular')
    actual=root.stat()
    if ((actual.st_dev,actual.st_ino,actual.st_uid,actual.st_mode & 0o7777)
            !=tuple(spec[key] for key in ('device','inode','uid','mode'))
            or actual.st_uid!=os.geteuid()):
        raise ValueError('Workspace directory identity changed')
    if ((PROJECT!=Path(__file__).resolve().parent.parent and _PYTHON_TOOLING is None)
            or (_PYTHON_TOOLING is None and (PROJECT==root or not PROJECT.is_relative_to(root/'.tmp')))
            or (_PYTHON_TOOLING is not None and root!=_PYTHON_TOOLING.workspace_root)):
        raise ValueError('Workspace override requires an enclosed retained producer')
    return root


def expansion_deadline_args(value):
    if value is None:
        return []
    if type(value) is not int or not 1 <= value <= MAX_EXPANSION_TIMEOUT_MS:
        raise ValueError('Expansion timeout must be 1 through 3600000 milliseconds')
    return ['--expansion-timeout-ms',str(value)]


def acquire_build_resource_lock(path):
    """Serialize corpus envelopes so two snapshots cannot spend the same RAM."""
    from build_resource_limits import ContainmentUnavailable
    path.parent.mkdir(parents=True,exist_ok=True)
    fd=os.open(path,os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,0o600)
    lock=os.fdopen(fd,'r+')
    try:
        fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise ContainmentUnavailable('Another Wikidict corpus build holds the resource lock') from None
    except BaseException:
        lock.close()
        raise
    return lock


def selected_execution_paths(args, workspace):
    spec = json.loads(args.execution_root_spec) if args.execution_root_spec is not None else None
    if spec is None:
        refuse_execution_destinations(workspace, (args.output, args.raw_shard_root,
            args.extraction_cache_root, Path.cwd() / '.tmp'))
        return None
    if not isinstance(spec,dict):raise ValueError('Invalid execution root binding')
    if ((PROJECT != Path(__file__).resolve().parent.parent and _PYTHON_TOOLING is None)
            or (args.workspace_root_spec is None and workspace != PROJECT)
            or args.resource_mode != 'watchdog'
            or args.cpu_admission != 'affinity' or args.jobs != 1
            or args.downloads is None or args.input_manifest is None or args.input_manifest_sha256 is None):
        raise ValueError('Independent execution requires the bound producer, watchdog affinity, one job and explicit inputs')
    layout = execution_paths(spec, workspace, PROJECT,
        artifact_spec=json.loads(args.artifact_root_spec) if args.artifact_root_spec is not None else None,
        state=spec.get('state', {}).get('path'), output=args.output, raw=args.raw_shard_root,
        cache=args.extraction_cache_root, downloads=args.downloads,
        manifest=args.input_manifest, manifest_sha256=args.input_manifest_sha256)
    attempt = Path.cwd()
    if (not attempt.is_relative_to(layout['state']) or attempt.resolve() != attempt
            or any(path.is_symlink() for path in (attempt, *attempt.parents))):
        raise ValueError('Independent watchdog receipts require an owned state directory')
    if args.wikis != [layout['edition']]:
        raise ValueError('Independent execution requires the exact manifest edition')
    return layout


@contextmanager
def selected_build_resource_lock(args, workspace, execution):
    path = workspace / '.tmp/build-resources.lock' if execution is None else execution['root'] / 'build-resources.lock'
    with acquire_build_resource_lock(path) as lock:
        original = os.fstat(lock.fileno())
        def check():
            if execution is not None:
                selected_execution_paths(args, workspace)
                held, live = os.fstat(lock.fileno()), path.lstat()
                if (not stat.S_ISREG(live.st_mode) or held.st_nlink != live.st_nlink or live.st_nlink != 1
                        or (held.st_dev, held.st_ino) != (live.st_dev, live.st_ino)
                        or (held.st_dev, held.st_ino) != (original.st_dev, original.st_ino)):
                    raise ValueError('Execution resource lock was removed or replaced')
        check()
        try:
            yield
        finally:
            check()


def require_execution_parent_lock(execution):
    # inside_watchdog already authenticated this parent. A generic watchdog
    # envelope alone does not prove ownership of these mutable destinations.
    path = execution['root'] / 'build-resources.lock'
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError('Execution parent lock is not a private regular file')
    expected = (os.major(info.st_dev), os.minor(info.st_dev), info.st_ino)
    found = False
    for line in Path('/proc/locks').read_text().splitlines():
        fields = line.split()
        if len(fields) < 6 or fields[1:4] != ['FLOCK', 'ADVISORY', 'WRITE']:
            continue
        device = fields[5].split(':')
        if (len(device) == 3 and int(fields[4]) == os.getppid()
                and (int(device[0],16),int(device[1],16),int(device[2])) == expected):
            found = True
    after = path.lstat()
    if (not found or (info.st_dev,info.st_ino,info.st_mode,info.st_nlink)
            != (after.st_dev,after.st_ino,after.st_mode,after.st_nlink)):
        raise ValueError('Authenticated watchdog parent does not own the execution lock')

def load_average():
    try:return max(0.0,os.getloadavg()[0])
    except OSError:return None

def affinity_worker_capacity(cpu_count, address_space_bytes):
    """Memory heuristic for a planned/actual affinity; not an aggregate PSS cap."""
    from build_resource_limits import MAX_BUILD_MEMORY, SUPERVISOR_CHILD_RESERVE
    if type(cpu_count) is not int or not 1 <= cpu_count <= MAX_PIPELINE_WORKERS:
        raise ValueError('Affinity admission requires one through four allowed CPUs')
    if type(address_space_bytes) is not int or not 0 < address_space_bytes <= MAX_BUILD_MEMORY:
        raise ValueError('Affinity admission requires a finite address-space bound of at most 8 GiB')
    memory_workers=max(0,address_space_bytes-SUPERVISOR_CHILD_RESERVE)//MEMORY_PER_BUILD_WORKER
    return min(cpu_count,memory_workers)


def affinity_worker_budget():
    from build_resource_limits import (ContainmentUnavailable, inside_watchdog, MAX_BUILD_MEMORY,
                                       CHILD_CGROUP, child_memory_limit_bytes, watchdog_physical_memory_limit_bytes)
    if not inside_watchdog():
        raise ContainmentUnavailable('Affinity admission requires a verified watchdog child')
    soft,hard=resource.getrlimit(resource.RLIMIT_AS)
    if soft == hard == resource.RLIM_INFINITY:
        physical_budget = watchdog_physical_memory_limit_bytes()
        if type(physical_budget) is not int or not 0 < physical_budget <= MAX_BUILD_MEMORY:
            raise ContainmentUnavailable('Invalid authenticated physical watchdog budget')
        if not 0 <= os.getpriority(os.PRIO_PROCESS, 0) <= 19:
            raise ContainmentUnavailable('Affinity admission requires watchdog nice priority from 0 through 19')
        cpus = len(os.sched_getaffinity(0))
        if not 1 <= cpus <= MAX_PIPELINE_WORKERS:
            raise ContainmentUnavailable('Affinity admission requires one through four allowed CPUs')
        return cpus
    if (soft==resource.RLIM_INFINITY or hard==resource.RLIM_INFINITY or
            not 0 < soft <= hard <= MAX_BUILD_MEMORY):
        raise ContainmentUnavailable('Affinity admission requires finite watchdog address-space limits of at most 8 GiB')
    if not 0 <= os.getpriority(os.PRIO_PROCESS,0) <= 19:
        raise ContainmentUnavailable('Affinity admission requires watchdog nice priority from 0 through 19')
    address_space_budget=soft
    if CHILD_CGROUP in os.environ:
        try:group_limit=child_memory_limit_bytes()
        except (OSError,ValueError):return 0
        if type(group_limit) is not int or group_limit<=0:return 0
        address_space_budget=min(address_space_budget,group_limit)
    return affinity_worker_capacity(len(os.sched_getaffinity(0)),address_space_budget)


def validate_llvm_workers(llvm_workers):
    if llvm_workers is not None and (type(llvm_workers) is not int or not 1 <= llvm_workers <= MAX_PIPELINE_WORKERS):
        raise ValueError('LLVM workers must be one through four')


def validate_affinity_workers(threads,jobs,expansion_workers=None,llvm_workers=None):
    expansion_workers=threads if expansion_workers is None else expansion_workers
    llvm_workers=threads if llvm_workers is None else llvm_workers
    if type(jobs) is not int or jobs!=1:
        raise ValueError('Affinity admission requires exactly one edition job')
    if any(type(n) is not int or not 1 <= n <= MAX_PIPELINE_WORKERS for n in (threads,expansion_workers,llvm_workers)):
        raise ValueError('Affinity admission requires one through four compiler and expansion workers')
    budget=affinity_worker_budget()
    if max(threads,expansion_workers,llvm_workers)>budget:
        raise ValueError(f'Affinity workers exceed allowed affinity/address-space budget {budget}')
    return budget


def safe_worker_budget(owned_workers=0, *, cpu_admission='load'):
    if cpu_admission=='affinity':return affinity_worker_budget()
    if cpu_admission!='load':raise ValueError('Unknown CPU admission policy')
    cpu=max(1,os.cpu_count() or 1)
    load=load_average()
    if load is None:
        cpu_workers=cpu
    else:
        external_load=max(0.0,load-owned_workers)
        cpu_workers=max(0,int(cpu*CPU_UTILIZATION_TARGET-external_load))
    from build_resource_limits import CHILD_CGROUP, MAX_BUILD_MEMORY, SUPERVISOR_CHILD_RESERVE, child_memory_limit_bytes
    memory_limit=MAX_BUILD_MEMORY
    if CHILD_CGROUP in os.environ:
        try:
            group_limit = child_memory_limit_bytes()
        except (OSError, ValueError):
            return 0
        if group_limit is None:
            return 0
        if type(group_limit) is not int or group_limit<=0:
            return 0
        memory_limit=min(memory_limit,group_limit)
    memory_workers=max(0,memory_limit-SUPERVISOR_CHILD_RESERVE)//MEMORY_PER_BUILD_WORKER
    return min(MAX_TOTAL_BUILD_WORKERS,cpu_workers,memory_workers)

def reduced_automatic_workers(current, budget):
    """Lower an automatic count through the finite 4/2/1 policy; never raise it."""
    return next((n for n in (4,2,1) if n < current and n <= budget),current)


def default_build_threads():
    return max(1,min(MAX_PIPELINE_WORKERS,safe_worker_budget()))

def ensure_language_registry(downloads, output, edition, date):
    source = downloads / edition / date / 'language-registry.tsv'
    if source.is_file():
        return source
    cached = output / edition / (date + '.language-registry.tsv')
    if cached.is_file():
        return cached
    content_language, text = language_registry_snapshot(edition)
    cached.parent.mkdir(parents=True, exist_ok=True)
    temp = cached.with_suffix(cached.suffix + '.part')
    temp.write_text(text, encoding='utf-8')
    os.replace(temp, cached)
    return cached




def read_small_json(path, max_bytes=64*1024):
    if path.is_symlink(): raise ValueError(f'Unsafe snapshot provenance path: {path}')
    with path.open('rb') as source:
        raw=source.read(max_bytes+1)
    if len(raw)>max_bytes: raise ValueError(f'Oversized snapshot provenance: {path}')
    return json.loads(raw)


# State and build identities retain full native role/source authority. Use the
# existing prepared-seal metadata ceiling, not the small snapshot bound.
BUILD_ENVELOPE_MAX_BYTES = 64 * 1024 * 1024
NATIVE_ROLE_DETAILS_NAME = '.native-tool-roles.json.gz'
NATIVE_ROLE_DETAILS_KEY = 'native_tool_roles_details'
NATIVE_ROLE_DETAILS_MIN_BYTES = 64 * 1024


def _native_role_summary(roles):
    if not isinstance(roles, dict) or not all(isinstance(row, dict) for row in roles.values()):
        raise ValueError('Invalid native role provenance')
    return {name: {key: value for key, value in row.items()
                   if key not in ('source_paths', 'source_payload_files')}
            for name, row in roles.items()}


def _read_native_role_details(root, reference, max_bytes):
    import io
    keys = {'version', 'member', 'size', 'sha256', 'decoded_size', 'decoded_sha256'}
    if (not isinstance(reference, dict) or set(reference) != keys
            or type(reference['version']) is not int or reference['version'] != 1
            or reference['member'] != NATIVE_ROLE_DETAILS_NAME
            or any(type(reference[key]) is not int or not 0 < reference[key] <= BUILD_ENVELOPE_MAX_BYTES
                   for key in ('size', 'decoded_size'))
            or reference['decoded_size'] > max_bytes or reference['size'] > max_bytes
            or any(not isinstance(reference[key], str) or not re.fullmatch('[0-9a-f]{64}', reference[key])
                   for key in ('sha256', 'decoded_sha256'))):
        raise ValueError('Invalid native role detail reference')
    path = Path(root) / NATIVE_ROLE_DETAILS_NAME
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size != reference['size']:
            raise ValueError('Invalid native role detail member')
        encoded = source.read(reference['size'] + 1)
        after = os.fstat(source.fileno())
    fields = ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
    linked = path.lstat()
    if (any(getattr(before, key) != getattr(after, key) or getattr(after, key) != getattr(linked, key)
            for key in fields) or len(encoded) != reference['size']
            or hashlib.sha256(encoded).hexdigest() != reference['sha256']):
        raise ValueError('Native role detail member changed')
    with gzip.GzipFile(fileobj=io.BytesIO(encoded), mode='rb') as source:
        decoded = source.read(reference['decoded_size'] + 1)
    if (len(decoded) != reference['decoded_size']
            or hashlib.sha256(decoded).hexdigest() != reference['decoded_sha256']):
        raise ValueError('Native role detail decoded identity differs')
    roles = json.loads(decoded)
    _native_role_summary(roles)
    return roles


def restore_publication_build_identity(root, identity, *, max_bytes=BUILD_ENVELOPE_MAX_BYTES):
    """Recover full producing authority; runtime and state identities stay full."""
    if not isinstance(identity, dict) or NATIVE_ROLE_DETAILS_KEY not in identity:
        return identity
    roles = _read_native_role_details(root, identity[NATIVE_ROLE_DETAILS_KEY], max_bytes)
    if identity.get('native_tool_roles') != _native_role_summary(roles):
        raise ValueError('Native role detail summary differs')
    restored = dict(identity, native_tool_roles=roles)
    del restored[NATIVE_ROLE_DETAILS_KEY]
    return restored


def restore_publication_metadata(root, metadata, *, max_bytes=8*1024*1024):
    if isinstance(metadata, dict) and isinstance(metadata.get('build_inputs'), dict):
        identity = restore_publication_build_identity(root, metadata['build_inputs'], max_bytes=max_bytes)
        if identity is not metadata['build_inputs']:
            restored = dict(metadata, build_inputs=identity)
            if len(json.dumps(restored).encode('utf-8')) > max_bytes:
                raise ValueError('Decoded publication metadata exceeds its existing bound')
            return restored
    return metadata


def read_publication_metadata(path, max_bytes=8*1024*1024):
    return restore_publication_metadata(path.parent, read_small_json(path, max_bytes), max_bytes=max_bytes)


def publication_build_identity(root, identity, *, create=False):
    """Store large source inventories once, losslessly, beside publication data."""
    full_text = build_envelope_text(identity)
    saved_path = Path(root) / '.build-inputs.json'
    if saved_path.exists() or saved_path.is_symlink():
        saved = read_small_json(saved_path, BUILD_ENVELOPE_MAX_BYTES)
        restored = restore_publication_build_identity(root, saved)
        if restored == identity:
            # Preserve legacy staging and existing encoded bytes on resume.
            return saved
        if not create:
            raise ValueError('Published build identity differs from its producing details')
        if isinstance(saved, dict) and NATIVE_ROLE_DETAILS_KEY in saved:
            if restored.get('native_tool_roles') != identity.get('native_tool_roles'):
                raise ValueError('Refusing to replace retained native role producing details')
            return dict(identity, native_tool_roles=saved['native_tool_roles'],
                        **{NATIVE_ROLE_DETAILS_KEY: saved[NATIVE_ROLE_DETAILS_KEY]})
    roles = identity.get('native_tool_roles')
    if roles is None:
        return identity
    decoded = json.dumps(roles, sort_keys=True, separators=(',', ':')).encode('utf-8')
    if len(decoded) < NATIVE_ROLE_DETAILS_MIN_BYTES:
        return identity
    summary = _native_role_summary(roles)
    encoded = gzip.compress(decoded, compresslevel=6, mtime=0)
    if len(encoded) > BUILD_ENVELOPE_MAX_BYTES:
        raise ValueError('Native role detail encoding exceeds prepared seal metadata bound')
    reference = dict(version=1, member=NATIVE_ROLE_DETAILS_NAME, size=len(encoded),
        sha256=hashlib.sha256(encoded).hexdigest(), decoded_size=len(decoded),
        decoded_sha256=hashlib.sha256(decoded).hexdigest())
    record = dict(identity, native_tool_roles=summary, **{NATIVE_ROLE_DETAILS_KEY: reference})
    record_bytes = (json.dumps(record, sort_keys=True) + '\n').encode('utf-8')
    if len(record_bytes) + len(encoded) + 4096 >= len(full_text.encode('utf-8')):
        return identity
    path = Path(root) / NATIVE_ROLE_DETAILS_NAME
    if create and not os.path.lexists(path):
        temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.part')
        try:
            with temporary.open('xb') as output:
                output.write(encoded); output.flush(); os.fsync(output.fileno())
            try:
                os.link(temporary, path)
            except FileExistsError:
                pass
        finally:
            temporary.unlink(missing_ok=True)
        sync_shard_directory(Path(root))
    if restore_publication_build_identity(root, record) != identity:
        raise ValueError('Native role detail roundtrip differs')
    return record


def copy_publication_role_details(source, destination, identity):
    if not isinstance(identity, dict) or NATIVE_ROLE_DETAILS_KEY not in identity:
        return
    restore_publication_build_identity(source, identity)
    copy_verified_snapshot(Path(source) / NATIVE_ROLE_DETAILS_NAME,
                           Path(destination) / NATIVE_ROLE_DETAILS_NAME,
                           identity[NATIVE_ROLE_DETAILS_KEY]['sha256'])
    restore_publication_build_identity(destination, identity)


def read_build_envelope(path):
    value = read_small_json(path, BUILD_ENVELOPE_MAX_BYTES)
    if not isinstance(value, dict):
        raise ValueError(f'Invalid build envelope: {path}')
    return restore_publication_build_identity(path.parent, value) if path.name == '.build-inputs.json' else value


def build_envelope_text(value):
    if not isinstance(value, dict):
        raise ValueError('Invalid build envelope')
    text = json.dumps(value, sort_keys=True) + '\n'
    if len(text.encode('utf-8')) > BUILD_ENVELOPE_MAX_BYTES:
        raise ValueError('Build envelope exceeds prepared seal metadata bound')
    return text


def read_snapshot_sha(path):
    if path.is_symlink(): raise ValueError(f'Unsafe snapshot identity path: {path}')
    with path.open('rb') as source: raw=source.read(66)
    if not re.fullmatch(rb'[0-9a-f]{64}\n',raw):
        raise ValueError(f'Invalid snapshot identity: {path}')
    return raw[:64].decode('ascii')


def copy_verified_snapshot(source, destination, expected_sha):
    """Pin small external configuration bytes for the entire edition build."""
    if destination.is_symlink(): raise ValueError(f'Unsafe external snapshot path: {destination}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary=destination.with_name(destination.name+'.part')
    if temporary.exists() or temporary.is_symlink(): raise ValueError(f'Unsafe external snapshot path: {temporary}')
    if destination.exists():
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_nlink',
                  'st_size', 'st_mtime_ns', 'st_ctime_ns')
        before = destination.lstat()
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f'Unsafe external snapshot path: {destination}')
        identity = tuple(getattr(before, name) for name in fields)
        digest = sha256_file(destination)
        if (destination.is_symlink() or
                tuple(getattr(destination.lstat(), name) for name in fields) != identity):
            raise ValueError('Pinned snapshot changed while authenticating')
        if digest == expected_sha:
            # A frozen expander may consume this exact inode through a symlink.
            # Revalidate the source as well; destination equality is no release.
            source_before = source.stat()
            source_identity = tuple(getattr(source_before, name) for name in fields)
            source_link = os.readlink(source) if source.is_symlink() else None
            if not stat.S_ISREG(source_before.st_mode) or sha256_file(source) != expected_sha:
                raise ValueError('External snapshot changed while copying')
            if (tuple(getattr(source.stat(), name) for name in fields) != source_identity
                    or (os.readlink(source) if source.is_symlink() else None) != source_link
                    or destination.is_symlink()
                    or tuple(getattr(destination.lstat(), name) for name in fields) != identity):
                raise ValueError('Snapshot identity changed while authenticating')
            return destination
    try:
        shutil.copyfile(source,temporary)
        if sha256_file(temporary)!=expected_sha:
            raise ValueError('External snapshot changed while copying')
        os.replace(temporary,destination)
    finally:
        unlink_artifact(temporary, missing_ok=True)
    return destination


def validate_interwiki_provenance(snapshot, edition, expected_sha):
    provenance=snapshot.with_name('interwiki-map.provenance.json')
    if not provenance.is_file(): return
    record=read_small_json(provenance)
    if (not isinstance(record,dict) or record.get('wiki')!=edition or
            record.get('tsv_sha256')!=expected_sha or record.get('dump_date') is not None):
        raise ValueError('Interwiki map provenance differs from requested edition or bytes')
    raw=snapshot.with_name('interwiki-map.raw.json')
    if record.get('kind')=='current-siteinfo-interwikimap' and not raw.is_file():
        raise ValueError('Current interwiki map raw response is missing')
    if raw.is_file() and sha256_file(raw)!=record.get('raw_sha256'):
        raise ValueError('Interwiki map raw response differs from provenance')


def auxiliary_snapshot_filename(name):
    if name=='page-language':return 'page-language.json'
    if name in FIGURE_SNAPSHOT_FILES:return FIGURE_SNAPSHOT_FILES[name]
    if name=='stylesheet-imports':return 'stylesheet-imports.json'
    if name=='site-statistics-format':return 'site-statistics-format.json'
    if name=='category-statistics-format':return 'category-statistics-format.json'
    if name=='figure-page-observations':return 'figure-page-observations.json'
    if name=='parser-function-facts':return 'parser-function-facts.json'
    return 'namespace-siteinfo.raw.json' if name=='site-info' else name+'.tsv'


def auxiliary_manifest_filename(name, path=None):
    if name in FIGURE_SNAPSHOT_FILES:return 'figure-inputs.manifest.json'
    if name=='file-metadata' and path is not None:
        shared=Path(path).with_name('figure-inputs.manifest.json')
        if shared.exists() or shared.is_symlink():return shared.name
    if name=='site-info' and path is not None:
        modern=Path(path).with_name('site-info.manifest.json')
        if modern.exists() or modern.is_symlink():return modern.name
    return 'namespace-registry.manifest.json' if name=='site-info' else name+'.manifest.json'


def auxiliary_capture_helper(name, path):
    if name=='figure-page-observations':
        import prepare_figure_page_observations
        return prepare_figure_page_observations
    if name=='page-language':
        import page_language_snapshot
        return page_language_snapshot
    if name=='parser-function-facts':
        import prepare_parser_function_facts
        return prepare_parser_function_facts
    if name in FIGURE_SNAPSHOT_FILES:
        import prepare_figure_metadata
        return prepare_figure_metadata
    if name=='stylesheet-imports':
        import prepare_stylesheet_imports
        return prepare_stylesheet_imports
    if name=='file-metadata':
        manifest=path.with_name(auxiliary_manifest_filename(name))
        header=None
        if path.is_file():
            with path.open('rb') as stream:header=stream.readline(256).rstrip(b'\r\n')
        if not (manifest.exists() or manifest.is_symlink()):
            if header==b'# wikidict-file-metadata-v2':raise ValueError('File metadata v2 requires its capture manifest')
            return None
        record=read_small_json(manifest)
        if not isinstance(record,dict):raise ValueError('Invalid file metadata provenance')
        schema=record.get('schema')
        if schema=='wikidict.figure-inputs.v1':
            import prepare_figure_metadata
            return prepare_figure_metadata
        if schema=='wikidict.file-metadata-capture.v2':
            import prepare_file_metadata_v2
            return prepare_file_metadata_v2
        if schema in ('wikidict.file-metadata-union.v1','wikidict.file-metadata-union.v2'):
            import prepare_file_metadata_union
            return prepare_file_metadata_union
        if schema not in (None,'wikidict.file-metadata-capture.v1') or header==b'# wikidict-file-metadata-v2':
            raise ValueError('Unsupported file metadata capture schema/header')
        # Preserve the established generic contract for v1 and schema-less data.
        return None
    if name=='wikibase-page-links':
        import prepare_wikibase_page_links
        return prepare_wikibase_page_links
    if name=='category-statistics-format':
        import prepare_category_statistics_format
        return prepare_category_statistics_format
    if name=='site-statistics-format':
        import prepare_site_statistics_format
        return prepare_site_statistics_format
    if name=='site-info':
        if auxiliary_manifest_filename(name,path)=='site-info.manifest.json':
            import prepare_site_info
            return prepare_site_info
        # A v2 snapshot without its manifest cannot fall back to legacy capture.
        raw=read_small_json(path,2*1024*1024)
        if isinstance(raw,dict) and 'schema' in raw:
            raise ValueError('Versioned site-info requires its capture manifest')
        import site_info_snapshot
        return site_info_snapshot
    if name=='commons-data':
        with path.open('rb') as stream:header=stream.readline(256).rstrip(b'\r\n')
        explicit_states=header==b'# wikidict-commons-data-v2'
        manifest=path.with_name(auxiliary_manifest_filename(name))
        if not (manifest.exists() or manifest.is_symlink()):
            if explicit_states:raise ValueError('Explicit Commons states require a v2 capture manifest')
            return None
        record=read_small_json(manifest)
        if not isinstance(record,dict):raise ValueError('Invalid Commons-data provenance')
        if explicit_states and record.get('schema')!='wikidict.commons-data-capture.v2':
            raise ValueError('Explicit Commons states require a v2 capture manifest')
        # Explicit capture schemas must pass replay, including unknown schemas.
        # Only schema-less legacy snapshots use generic manifest validation.
        if 'schema' not in record:return None
        if record.get('schema')=='wikidict.commons-data-capture.v2':
            import prepare_commons_data_v2
            return prepare_commons_data_v2
        import prepare_commons_data
        return prepare_commons_data
    if name=='date-numbering':
        import prepare_date_numbering
        return prepare_date_numbering
    if name=='language-names':
        record=read_small_json(path.with_name(auxiliary_manifest_filename(name)))
        if isinstance(record,dict) and record.get('schema')=='wikidict.language-names-profile-union.v1':
            import prepare_language_names_union
            return prepare_language_names_union
        if isinstance(record,dict) and record.get('schema')=='wikidict.language-names-autonym-capture.v1':
            import prepare_language_names_autonyms
            return prepare_language_names_autonyms
        if isinstance(record,dict) and record.get('schema')=='wikidict.language-names-translate-capture.v1':
            import prepare_language_names_translate
            return prepare_language_names_translate
        if isinstance(record,dict) and record.get('schema')=='wikidict.language-names-capture.v2':
            import prepare_language_names_generic
            return prepare_language_names_generic
        import prepare_language_names
        return prepare_language_names
    if name=='image-options':
        import prepare_image_options
        return prepare_image_options
    if name=='behavior-switches':
        import prepare_behavior_switches
        return prepare_behavior_switches
    if name=='magic-words':
        record=read_small_json(path.with_name(auxiliary_manifest_filename(name)))
        if isinstance(record,dict) and type(record.get('version')) is int and record['version']==10:
            import prepare_magic_words_file_page
            return prepare_magic_words_file_page
        if isinstance(record,dict) and type(record.get('version')) is int and record['version'] in (7,9):
            import prepare_magic_words_category
            return prepare_magic_words_category
        if isinstance(record,dict) and type(record.get('version')) is int and record['version']==6:
            import prepare_magic_words_statistics
            return prepare_magic_words_statistics
        if isinstance(record,dict) and type(record.get('version')) is int and record['version']==5:
            import prepare_magic_words_lst
            return prepare_magic_words_lst
        import prepare_magic_words_language
        return prepare_magic_words_language
    if name in ('wikibase-entities','wikibase-entity-terms'):
        import prepare_wikibase_entities
        return prepare_wikibase_entities
    if name=='interface-messages':
        manifest=path.with_name(auxiliary_manifest_filename(name))
        if not (manifest.exists() or manifest.is_symlink()):return None
        record=read_small_json(manifest)
        if not isinstance(record,dict):raise ValueError('Invalid interface-message provenance')
        # Older explicit snapshots predate capture schemas. A present schema
        # must pass the current helper, including unknown/unsupported schemas.
        if 'schema' not in record:return None
    elif name=='language-fallbacks':
        record=read_small_json(path.with_name(auxiliary_manifest_filename(name)))
    else:
        return None
    if isinstance(record,dict) and record.get('schema') in ('wikidict.language-messages-union.v1','wikidict.language-messages-union.v2'):
        import prepare_language_messages_union
        return prepare_language_messages_union
    if isinstance(record,dict) and record.get('schema') in ('wikidict.language-messages-capture.v2','wikidict.language-messages-complete.v1'):
        import prepare_language_messages_v2
        return prepare_language_messages_v2
    import prepare_language_messages
    return prepare_language_messages


# Only exact successful file-v2 replays are reusable. Every call still checks
# the current producer and hashes the complete evidence inventory. Store JSON
# and tuples so callers cannot mutate the cached proof through returned dicts.
_FILE_METADATA_V2_REPLAYS={}


# Successful generic-name replays are process-local; every reuse still hashes
# the complete capture inventory. A producer/runtime change requires a restart.
_GENERIC_LANGUAGE_NAMES_REPLAYS={}
_GENERIC_LANGUAGE_NAMES_RUNTIME=None


def generic_language_names_runtime(helper):
    def config_value(value):
        if isinstance(value,frozenset):return sorted(value)
        raise ValueError('Unsupported language names runtime configuration')
    constants={name:value for name,value in vars(helper).items() if name.isupper()}
    config=json.dumps(constants,sort_keys=True,separators=(',',':'),default=config_value)
    functions=[]
    for name,value in sorted(vars(helper).items()):
        if callable(value) and getattr(value,'__module__',None)==helper.__name__:
            function=getattr(value,'__wrapped__',value)
            functions.append((name,value,getattr(function,'__code__',None),
                              repr(getattr(function,'__defaults__',None)),
                              repr(getattr(function,'__kwdefaults__',None))))
    return (helper,helper.evidence,config,tuple(functions))


def generic_language_names_capture(helper,path,edition,date):
    global _GENERIC_LANGUAGE_NAMES_RUNTIME
    path=Path(path)
    if (path.name!='language-names.tsv' or path.is_symlink() or
            path.parent.is_symlink() or not path.parent.is_dir()):
        raise ValueError('Invalid language names snapshot path')
    producer=json.dumps(helper.producer(),sort_keys=True,separators=(',',':'))
    runtime=(producer,generic_language_names_runtime(helper))
    if _GENERIC_LANGUAGE_NAMES_RUNTIME is not None and runtime!=_GENERIC_LANGUAGE_NAMES_RUNTIME:
        raise ValueError('Language names producer/runtime changed; restart the builder')
    manifest_path=path.with_name('language-names.manifest.json')
    manifest_sha=hashlib.sha256(helper.evidence.small(manifest_path,helper.MAX_MANIFEST)).hexdigest()
    key=(producer,manifest_sha)
    previous=_GENERIC_LANGUAGE_NAMES_REPLAYS.get(key)
    if previous is None:
        record=helper.validate_snapshot(path,edition,date)
        artifacts=helper.capture_artifacts(path,record)
    else:
        record=json.loads(previous[0])
        if ((edition is not None and record['wiki']!=edition) or
                (date is not None and record['date']!=date)):
            raise ValueError('Language names edition/date mismatch')
        payload=helper.payload(path.parent)
        if payload!=record['artifacts']:
            raise ValueError('Language names evidence inventory changed')
        artifacts={name:item['sha256'] for name,item in payload.items()}
        for name in (helper.COMPLETE,'language-names.manifest.json'):
            artifacts[name]=hashlib.sha256(helper.evidence.small(path.with_name(name),helper.MAX_MANIFEST)).hexdigest()
    inventory=tuple(sorted(artifacts.items()))
    if (artifacts.get('language-names.manifest.json')!=manifest_sha or
            runtime!=(json.dumps(helper.producer(),sort_keys=True,separators=(',',':')),
                      generic_language_names_runtime(helper)) or
            (previous is not None and inventory!=previous[1])):
        raise ValueError('Language names capture or producer changed during validation')
    if previous is None:
        if len(_GENERIC_LANGUAGE_NAMES_REPLAYS)>=32:_GENERIC_LANGUAGE_NAMES_REPLAYS.clear()
        _GENERIC_LANGUAGE_NAMES_REPLAYS[key]=(json.dumps(record,sort_keys=True,separators=(',',':')),inventory)
        _GENERIC_LANGUAGE_NAMES_RUNTIME=runtime
    # Never expose the mutable objects retained by the cache.
    return json.loads(_GENERIC_LANGUAGE_NAMES_REPLAYS[key][0]),dict(inventory)


def require_auxiliary_tooling(snapshots):
    """Resolve selected capture helpers before any expensive semantic replay."""
    figure_roots={Path(path).parent for name,path in snapshots.items() if name in FIGURE_SNAPSHOT_FILES}
    for name,path in snapshots.items():
        # A co-located Provider belongs to the already selected Figure reader.
        if name=='file-metadata' and Path(path).parent in figure_roots:continue
        auxiliary_capture_helper(name,Path(path))
    if _PYTHON_TOOLING is not None:_PYTHON_TOOLING.require_unchanged()


def validated_auxiliary_capture(name, path, edition=None, date=None):
    helper=auxiliary_capture_helper(name,path)
    if helper is None:return None
    if name=='page-language':return helper.validated_capture(path,edition,date)
    if name in FIGURE_SNAPSHOT_FILES:
        paths={role:Path(path).with_name(filename) for role,filename in FIGURE_SNAPSHOT_FILES.items()}
        return verified_figure_tuple(helper,paths,edition,date)[name]
    if name=='language-names' and helper.__name__=='prepare_language_names_generic':
        return generic_language_names_capture(helper,path,edition,date)
    replay_key=None;previous=None
    if name=='file-metadata' and helper.__name__ in ('prepare_file_metadata_v2','prepare_file_metadata_union'):
        path=Path(path)
        if (path.name!='file-metadata.tsv' or path.is_symlink() or
                path.parent.is_symlink() or not path.parent.is_dir()):
            raise ValueError('Invalid file metadata snapshot path')
        producer_key=json.dumps(helper.producer(),sort_keys=True,separators=(',',':'))
        manifest_digest=hashlib.sha256(helper.small(path.with_name(helper.MANIFEST),helper.MAX_MANIFEST)).hexdigest()
        replay_key=(producer_key,manifest_digest)
        previous=_FILE_METADATA_V2_REPLAYS.get(replay_key)
    if getattr(helper,'__name__',None) in (
            'prepare_wikibase_entities','prepare_language_messages',
            'prepare_language_messages_v2','prepare_language_messages_union','prepare_date_numbering',
            'prepare_site_info','prepare_language_names_translate','prepare_parser_function_facts',
            'prepare_category_statistics_format'):
        # These helpers replay the complete capture inside capture_artifacts.
        # Bind that one replay to exact preread bytes, rather than replaying the
        # inventory twice at this boundary. Other boundaries still replay.
        manifest_name=auxiliary_manifest_filename(name,path)
        manifest_path=Path(path).with_name(manifest_name)
        if helper.__name__=='prepare_wikibase_entities':
            manifest_raw=helper.regular(manifest_path,helper.MAX_PROOF_BYTES)
            record=helper.parse_json(manifest_raw)
        elif helper.__name__=='prepare_category_statistics_format':
            manifest_raw=helper.read(manifest_path)
            record=helper.e.decode(manifest_raw)
        else:
            manifest_raw=helper.evidence.small(manifest_path,helper.MAX_MANIFEST)
            record=helper.evidence.decode(manifest_raw)
        if (not isinstance(record,dict) or
                (edition is not None and record.get('wiki')!=edition) or
                (date is not None and record.get('date')!=date)):
            raise ValueError('Auxiliary capture edition/date mismatch: '+name)
        artifacts=helper.capture_artifacts(path,record)
        if artifacts.get(manifest_name)!=hashlib.sha256(manifest_raw).hexdigest():
            raise ValueError('Auxiliary manifest changed during validation: '+name)
    else:
        if previous is None:
            record=helper.validate_snapshot(path,edition,date)
        else:
            record=json.loads(previous[0])
            if ((edition is not None and record['wiki']!=edition) or
                    (date is not None and record['date']!=date)):
                raise ValueError('File metadata edition/date mismatch')
        if name=='magic-words':
            artifacts=dict(record['artifacts'])
            artifacts['magic-words.manifest.json']=sha256_file(path.with_name('magic-words.manifest.json'))
        else:
            artifacts=helper.capture_artifacts(path,record)
    if not isinstance(artifacts,dict) or auxiliary_manifest_filename(name,path) not in artifacts or auxiliary_snapshot_filename(name) not in artifacts:
        raise ValueError('Incomplete auxiliary capture inventory: '+name)
    for filename,digest in artifacts.items():
        if (not isinstance(filename,str) or Path(filename).name!=filename or filename in ('.','..') or
                not isinstance(digest,str) or not re.fullmatch('[0-9a-f]{64}',digest)):
            raise ValueError('Unsafe auxiliary capture inventory: '+name)
    if replay_key is not None:
        inventory=tuple(sorted(artifacts.items()))
        if (artifacts[helper.MANIFEST]!=replay_key[1] or
                json.dumps(helper.producer(),sort_keys=True,separators=(',',':'))!=replay_key[0] or
                (previous is not None and inventory!=previous[1])):
            raise ValueError('File metadata capture changed during validation')
        if previous is None:
            if len(_FILE_METADATA_V2_REPLAYS)>=32:_FILE_METADATA_V2_REPLAYS.clear()
            _FILE_METADATA_V2_REPLAYS[replay_key]=(json.dumps(record,sort_keys=True,separators=(',',':')),inventory)
    return record,artifacts

def auxiliary_artifact_digest(artifacts):
    return hashlib.sha256(json.dumps(artifacts,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def auxiliary_capture_identities(snapshots, edition=None, date=None):
    manifests={};artifacts={}
    figures=validated_figure_tuple(snapshots,edition,date)
    for name,source in sorted((snapshots or {}).items()):
        capture=figures[name] if name in figures else validated_auxiliary_capture(name,Path(source),edition,date)
        if capture is not None:
            _,inventory=capture
            manifests[name]=inventory[auxiliary_manifest_filename(name,Path(source))]
            artifacts[name]=auxiliary_artifact_digest(inventory)
    return manifests,artifacts


def require_auxiliary_capture_identity(snapshots, identity):
    if identity is None:return
    manifests,artifacts=auxiliary_capture_identities(snapshots)
    if (manifests!=identity.get('auxiliary_capture_sha256',{}) or
            artifacts!=identity.get('auxiliary_capture_artifact_sha256',{})):
        raise ValueError('Auxiliary capture changed during build')


def verified_auxiliary_hashes(snapshots, edition=None, date=None, *, captured_selection=None):
    return _validated_auxiliary_state(snapshots,edition,date,captured_selection=captured_selection)[0]


_FIGURE_TUPLE_REPLAYS = {}
_FIGURE_TUPLE_REPLAY_LOCK = threading.RLock()


def release_figure_parent_replays():
    # Results remain reusable, but retain at most one set of large parent
    # documents per thread, and none after its snapshot pinning boundary.
    owner = threading.current_thread()
    with _FIGURE_TUPLE_REPLAY_LOCK:
        for key, entry in tuple(_FIGURE_TUPLE_REPLAYS.items()):
            if len(entry) == 3 and (entry[2]['owner'] is owner or not entry[2]['owner'].is_alive()):
                entry[2]['retained'].clear()
                entry[2]['inventory'].clear()
                _FIGURE_TUPLE_REPLAYS[key] = entry[:2]



def _figure_replay_identity(path, *, directory=False):
    """Bind a lexical name and its resolved object without reading payload bytes."""
    def fields(value):
        return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_gid,
                value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    lexical = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(lexical.st_mode):
        raise ValueError('Unsafe Figure replay path: ' + str(path))
    target = path.stat()
    resolved = str(path.resolve(strict=True))
    if fields(lexical) != fields(target) or fields(path.lstat()) != fields(lexical):
        raise ValueError('Figure replay path changed while checking identity')
    return resolved, fields(lexical), fields(target)


def figure_tuple_guard(helper, root, *, authenticated=None, deferred_capture=None):
    """Hash the initial readset; reuse its digests only under exact local guards."""
    evidence = helper.evidence
    files, directories, initial = set(), {}, {}
    active, visited, closed_prefixes = set(), set(), set()

    def capture(directory):
        directory = Path(directory)
        if directory in active or directory.is_symlink() or not directory.is_dir():
            raise ValueError('Unsafe or recursive Figure capture authority')
        if directory in visited:
            return True
        active.add(directory)
        members = tuple(sorted(directory.iterdir()))
        directories[directory] = (directory.stat().st_dev, directory.stat().st_ino, members,
                                  _figure_replay_identity(directory, directory=True))
        if any(path.is_dir() and not path.is_symlink() for path in members):
            # The maintained enumerator admits only declared materialized origin
            # directories. Full semantic replay still precedes publishing proof.
            if not hasattr(helper, 'capture_member_paths'):
                return False
            contained, custody = helper.capture_member_paths(directory, include_markers=True)
            for parent in custody:
                if parent.resolve() != parent or any(path.is_symlink() for path in (parent, *parent.parents)):
                    raise ValueError('Unsafe contained Figure replay authority')
                st = parent.stat()
                directories[parent] = (st.st_dev, st.st_ino, tuple(sorted(parent.iterdir())),
                                       _figure_replay_identity(parent, directory=True))
            payload_members = tuple(contained.values())
        else:
            payload_members = members
        if deferred_capture is not None and directory == Path(root):
            deferred_capture.update(payload_members)
        files.update(payload_members)
        initial.update((path, _figure_replay_identity(path)) for path in payload_members)
        inventory_path = directory / helper.INVENTORY
        if inventory_path in members:
            inventory = helper.decode(helper.small(inventory_path))
            for source in inventory['sources']:
                path = Path(source['path'])
                if not path.is_absolute():
                    raise ValueError('Relative Figure SQL authority')
                files.add(path)
        requests = directory / helper.FILE_REQUESTS
        if requests in members:
            with requests.open('rb') as stream:
                first = stream.readline(getattr(helper, 'STREAM_HEADER_LIMIT', helper.MAX_METADATA) + 1)
            try:
                header = helper.decode(first)
            except (ValueError, UnicodeError):
                # Legacy request inventories are bounded JSON, and need not
                # use the stream writer's one-record-per-line encoding.
                header = helper.decode(helper.small(requests))
            if isinstance(header, dict) and header.get('schema') == getattr(helper, 'REQUEST_STREAM_SCHEMA', None):
                # Source records have one line per raw response, in exact order.
                with requests.open('rb') as stream:
                    next(stream)
                    sources = (helper.decode(line) for line in iter(lambda: stream.readline(helper.STREAM_HEADER_LIMIT + 1), b''))
                    if not add_sources(sources):
                        return False
            elif isinstance(header, list):
                if not add_sources(header):
                    return False
            else:
                return False
        active.remove(directory)
        visited.add(directory)
        return True

    def closed_prefix(path):
        path = Path(path)
        if not path.is_absolute() or path.resolve() != path or path.is_symlink():
            raise ValueError('Unsafe closed Figure cache authority')
        if path in closed_prefixes:
            return True
        files.add(path)
        initial[path] = _figure_replay_identity(path)
        record = helper.decode(helper.small(path))
        if (not isinstance(record, dict) or record.get('schema') != getattr(helper, 'CLOSED_PREFIX_SCHEMA', None) or
                set(record) != {'schema', 'wiki', 'date', 'source_root', 'original_root', 'closure', 'light_titles'}):
            return False
        roots = [record.get(name) for name in ('source_root', 'original_root')]
        closure = record['closure']
        if (any(not isinstance(value, str) for value in roots) or
                not isinstance(closure, dict) or set(closure) != {'path', 'bytes', 'sha256'} or
                not isinstance(closure['path'], str)):
            return False
        directory, original = map(Path, roots)
        closure_path = Path(closure['path'])
        if any(not value.is_absolute() or value.resolve() != value or value.is_symlink()
               for value in (directory, original, closure_path)):
            raise ValueError('Unsafe closed Figure evidence locator')
        files.add(closure_path)
        initial[closure_path] = _figure_replay_identity(closure_path)
        # The semantic reader maps every closure artifact into this failed
        # directory, then replays its request journal for external authorities.
        # Collect the entire directory, including rejected and pending evidence.
        if not capture(directory):
            return False
        closed_prefixes.add(path)
        return True

    def add_sources(sources):
        for source in sources:
            kind = source.get('kind')
            if kind == 'retained-request':
                path = Path(source['path'])
                if not path.is_absolute():
                    raise ValueError('Relative retained Figure authority')
                files.add(path)
                initial[path] = _figure_replay_identity(path)
                record = helper.decode(helper.small(path))
                if 'observed_svg_occurrences' in record:
                    observations, artifacts = record['observed_svg_occurrences'], record.get('artifacts')
                    if ('observed_svg_width_px' in record or not isinstance(observations, list) or
                            not 1 <= len(observations) <= 50 or not isinstance(artifacts, dict) or
                            not 7 <= len(artifacts) <= 4 + 3 * 50):
                        return False
                    # The strict reader opens only declared artifacts, each at
                    # most one directory below this record. Semantic replay is
                    # still required before this complete readset can be cached.
                    for name in artifacts:
                        if not isinstance(name, str) or not 1 <= len(name.split('/')) <= 2:
                            return False
                        parts = name.split('/')
                        for part in parts:
                            try:
                                helper.observed_artifact_name(part)
                            except ValueError:
                                return False
                        member = path.parent.joinpath(*parts)
                        for directory in {path.parent, member.parent}:
                            if directory.is_symlink() or not directory.is_dir():
                                raise ValueError('Unsafe contained Figure authority directory')
                            if directory.resolve() != directory:
                                return False
                            st = directory.stat()
                            identity = (st.st_dev, st.st_ino, tuple(sorted(directory.iterdir())),
                                        _figure_replay_identity(directory, directory=True))
                            if directories.setdefault(directory, identity) != identity:
                                raise ValueError('Contained Figure membership changed while collecting inputs')
                        files.add(member)
                        initial.setdefault(member, _figure_replay_identity(member))
                    continue
                for name in record['artifacts']:
                    (helper.observed_artifact_name if 'observed_svg_width_px' in record else helper.metadata.safe_name)(name)
                    files.add(path.parent / name)
            elif kind == 'retained-occurrences':
                if not capture(Path(source['path'])):
                    return False
            elif kind == 'complete-stream':
                path = Path(source['path'])
                if (not path.is_absolute() or path.resolve() != path or
                        path.name != helper.MANIFEST or path.is_symlink()):
                    raise ValueError('Unsafe complete Figure cache authority')
                # Complete parents share the same replay readset. Collect each
                # ancestor once; initial semantic replay still validates every
                # batch reference before any result enters this local cache.
                if not capture(path.parent):
                    return False
            elif kind == 'closed-prefix':
                if not closed_prefix(source['path']):
                    return False
            elif kind not in ('http-archived', 'http-archived-light', 'http-archived-lean'):
                # Unknown source families retain full maintained replay.
                return False
        return True

    runtime = (helper.producer(), helper.metadata.producer(), helper.site_info.producer())
    if not capture(root):
        return None
    directory_proof = {str(path): value for path, value in directories.items()}
    if authenticated is not None and (runtime != authenticated[0] or
            set(map(str, files)) != set(authenticated[1]) or directory_proof != authenticated[2]):
        return None
    identities = {}
    for path in sorted(files):
        before = _figure_replay_identity(path)
        if path in initial and before != initial[path]:
            raise ValueError('Figure replay authority changed while collecting inputs')
        if deferred_capture is not None and path in deferred_capture:
            identity = None
        elif authenticated is None:
            identity = evidence.fingerprint(path)
        else:
            previous, identity = authenticated[1][str(path)]
            if before != previous:
                return None
        if _figure_replay_identity(path) != before:
            raise ValueError('Figure replay input changed while hashing')
        identities[str(path)] = (before, identity)
    # A later file check must not hide a mutation of an earlier member.
    for path, (before, _) in identities.items():
        if _figure_replay_identity(Path(path)) != before:
            raise ValueError('Figure replay input changed at final boundary')
    for directory, identity in directories.items():
        current = directory.stat()
        if directory.is_symlink() or (current.st_dev, current.st_ino, tuple(sorted(directory.iterdir())),
                _figure_replay_identity(directory, directory=True)) != identity:
            raise ValueError('Figure replay membership changed while hashing')
    if (helper.producer(), helper.metadata.producer(), helper.site_info.producer()) != runtime:
        raise ValueError('Figure replay helper changed while hashing')
    return runtime, identities, {str(path): value for path, value in directories.items()}



def verified_figure_tuple(helper, paths, edition=None, date=None, *, parent_paths=None):
    """Reuse only this interpreter's completed replay under fresh identity guards."""
    key = tuple(sorted((role, str(Path(path).absolute())) for role, path in paths.items()))
    roots = {Path(path).parent for path in paths.values()}
    if len(roots) != 1:
        return helper.verify_tuple(paths, edition, date)
    with _FIGURE_TUPLE_REPLAY_LOCK:
        previous = _FIGURE_TUPLE_REPLAYS.get(key)
    root = roots.pop()
    deferred = set() if previous is None and callable(getattr(helper, 'capture_member_paths', None)) else None
    guard = figure_tuple_guard(helper, root, authenticated=None if previous is None else previous[0],
                               deferred_capture=deferred)
    if previous is not None:
        if guard is None or guard != previous[0]:
            with _FIGURE_TUPLE_REPLAY_LOCK:
                if _FIGURE_TUPLE_REPLAYS.get(key) is previous and len(previous) == 3:
                    previous[2]['retained'].clear()
                    previous[2]['inventory'].clear()
                    _FIGURE_TUPLE_REPLAYS[key] = previous[:2]
            raise ValueError('Figure replay inputs or helper changed after validation')
        result = json.loads(previous[1])
        record = next(iter(result.values()))[0]
        if ((edition is not None and record['wiki'] != edition) or
                (date is not None and record['date'] != date)):
            raise ValueError('Figure capture edition/date mismatch')
        return {role: (row[0], row[1]) for role, row in result.items()}
    # Older selected helpers keep their original full verification API. Do not
    # catch a TypeError from validation and silently execute it a second time.
    try:
        parameters = inspect.signature(helper.verify_tuple).parameters
    except (TypeError, ValueError):
        parameters = {}
    supports_parents = all(name in parameters and parameters[name].kind in
        (inspect.Parameter.KEYWORD_ONLY, inspect.Parameter.POSITIONAL_OR_KEYWORD)
        for name in ('retained_cache', 'inventory_cache'))
    proofs = None
    if guard is not None and supports_parents and parent_paths:
        parent_key = tuple(sorted((role, str(Path(path).absolute())) for role, path in parent_paths.items()))
        parent_roots = {Path(path).parent for path in parent_paths.values()}
        if len(parent_roots) == 1:
            with _FIGURE_TUPLE_REPLAY_LOCK:
                source = _FIGURE_TUPLE_REPLAYS.get(parent_key)
            parent_guard = figure_tuple_guard(helper, parent_roots.pop(),
                authenticated=None if source is None else source[0])
            with _FIGURE_TUPLE_REPLAY_LOCK:
                if source is not None and _FIGURE_TUPLE_REPLAYS.get(parent_key) is source:
                    if parent_guard is None or parent_guard != source[0]:
                        raise ValueError('Figure parent inputs changed before pinning replay')
                    if len(source) == 3:
                        # The resolver publishes completed proof on the main
                        # thread; one build worker exclusively claims it here.
                        proofs = source[2]
                        _FIGURE_TUPLE_REPLAYS[parent_key] = source[:2]
                        proofs['owner'] = threading.current_thread()
    release_figure_parent_replays()
    if guard is not None and supports_parents and proofs is None:
        proofs = {'owner': threading.current_thread(), 'retained': {}, 'inventory': {}}
    retained = False
    try:
        kwargs = {} if proofs is None else {'retained_cache': proofs['retained'], 'inventory_cache': proofs['inventory']}
        # This always replays the destination itself. Only exact absolute
        # external-parent and SQL keys can hit the helper's existing caches.
        result = helper.verify_tuple(paths, edition, date, **kwargs)
        if guard is not None and deferred:
            # The complete tuple validator authenticated the destination bytes.
            # Use its exact inventory only after the original stamps survive the
            # full sweep below. External authorities still have independent hashes.
            members = {str(path.relative_to(root)): str(path) for path in deferred}
            manifest, inventory = next(iter(result.values()))
            if set(inventory) != set(members):
                raise ValueError('Figure replay inventory differs from the capture readset')
            for name, path in members.items():
                stamp, _ = guard[1][path]
                size = stamp[1][6]
                digest = inventory[name]
                if (not isinstance(digest, str) or re.fullmatch('[0-9a-f]{64}', digest) is None or
                        (name not in (helper.MANIFEST, helper.COMPLETE) and
                         manifest['artifacts'].get(name) != {'bytes': size, 'sha256': digest})):
                    raise ValueError('Figure replay inventory differs from the captured bytes')
                guard[1][path] = (stamp, {'size': size, 'sha256': digest})
        after = figure_tuple_guard(helper, root, authenticated=guard)
        if guard != after:
            raise ValueError('Figure replay inputs changed during validation')
        if guard is not None:
            entry = (guard, json.dumps(result, sort_keys=True, separators=(',', ':')))
            if proofs is not None and parent_paths is None:
                entry += (proofs,)
            # A worker can claim the completed context immediately after its
            # publication; the original owner must not subsequently clear it.
            retained = len(entry) == 3
            with _FIGURE_TUPLE_REPLAY_LOCK:
                if len(_FIGURE_TUPLE_REPLAYS) >= 32:
                    _FIGURE_TUPLE_REPLAYS.clear()
                _FIGURE_TUPLE_REPLAYS[key] = entry
        return result
    finally:
        if proofs is not None and not retained:
            proofs['retained'].clear()
            proofs['inventory'].clear()



def _prepared_figure_selection(cfg):
    options=cfg.get('edition_options') or {}
    if len(options)!=1:return None
    edition,option=next(iter(options.items()))
    snapshots=option.get('auxiliary_snapshots') or {}
    paths={name:Path(value['path'] if isinstance(value,dict) else value)
           for name,value in snapshots.items() if name in FIGURE_SNAPSHOT_FILES}
    if set(paths)!=set(FIGURE_SNAPSHOT_FILES):return None
    roots={path.parent for path in paths.values()}
    if len(roots)!=1:return None
    provider=snapshots.get('file-metadata')
    if provider is not None:
        provider=Path(provider['path'] if isinstance(provider,dict) else provider)
        if provider.parent in roots:paths['file-metadata']=provider
    key=tuple(sorted((name,str(path.absolute())) for name,path in paths.items()))
    return edition,paths,key


def _prepared_figure_guard_digest(guard, version=2):
    # Commit to every field of the same complete guard, without copying its
    # large lexical/resolved path inventories into the generation a second time.
    digest=hashlib.sha256(f'wikidict.prepared-figure-guard.v{version}\0'.encode())
    encoder=json.JSONEncoder(default=os.fspath,sort_keys=True,separators=(',',':'),allow_nan=False)
    for part in encoder.iterencode(guard):digest.update(part.encode('utf-8'))
    return digest.hexdigest()


def prepared_figure_verdict(cfg):
    """Export only an actual successful replay from this child interpreter."""
    selected=_prepared_figure_selection(cfg)
    if selected is None:return None
    edition,paths,key=selected
    with _FIGURE_TUPLE_REPLAY_LOCK:
        prior=_FIGURE_TUPLE_REPLAYS.get(key)
    if prior is None or not isinstance(prior[1],str):return None
    import prepare_figure_metadata as helper
    guard=figure_tuple_guard(helper,next(iter(paths.values())).parent,authenticated=prior[0])
    if guard is None or guard!=prior[0]:return None
    result=json.loads(prior[1])
    if (set(result)!=set(paths) or any(row[0].get('wiki')!=edition or row[0].get('date')!=cfg['date']
                                     for row in result.values())):return None
    version=3 if any('sha1' not in identity for _,identity in guard[1].values()) else 2
    return dict(version=version,source=cfg['source'],python_tooling=cfg.get('python_tooling'),
                edition=edition,date=cfg['date'],paths=dict(key),
                guard_sha256=_prepared_figure_guard_digest(guard,version),result=result)


def reuse_prepared_figure_verdict(cfg, verdict):
    """Parent-only: caller has authenticated the exact-source tracked child.

    This is not a public capture validator or a ready-marker policy. A supplied
    generation/dispatch alone never calls it. Missing/stale verdicts leave the
    ordinary validator authoritative, including its failures.
    """
    selected=_prepared_figure_selection(cfg)
    if selected is None or not isinstance(verdict,dict):return False
    edition,paths,key=selected
    if (set(verdict)!={'version','source','python_tooling','edition','date','paths','guard_sha256','result'}
            or type(verdict['version']) is not int or verdict['version'] not in (2,3) or verdict['source']!=cfg['source']
            or verdict['python_tooling']!=cfg.get('python_tooling')
            or verdict['edition']!=edition or verdict['date']!=cfg['date']
            or verdict['paths']!=dict(key)):
        return False
    if (type(verdict['guard_sha256']) is not str or
            re.fullmatch('[0-9a-f]{64}',verdict['guard_sha256']) is None):return False
    result=verdict['result']
    if (not isinstance(result,dict) or set(result)!=set(paths)
            or any(not isinstance(row,list) or len(row)!=2 or not isinstance(row[0],dict)
                   or not isinstance(row[1],dict) or row[0].get('wiki')!=edition
                   or row[0].get('date')!=cfg['date'] for row in result.values())):
        return False
    # Authenticate every Python validator/import from the original source
    # inventory (or selected catalog), not a caller-supplied helper digest.
    inventory=prepared_metadata(cfg['source']['inventory'])
    if inventory.get('head')!=cfg['source']['head']:return False
    python={}
    for name,reference in inventory['files'].items():
        if name.startswith('tools/') and name.endswith('.py') and not Path(name).name.startswith('test_'):
            if reference['path']!=str(PROJECT/name):return False
            python[name]=dict(sha256=reference['sha256'],mode=inventory['modes'][name])
    source=object.__new__(PreparedSourceGeneration)
    source.record=dict(python=python)
    if cfg.get('python_tooling') is not None:source.record['python_tooling']=cfg['python_tooling']
    source.require_python(force=True)
    import prepare_figure_metadata as helper
    # Deliberately no authenticated=child_guard: the parent hashes the complete
    # helper/SQL/raw/parent readset itself before transporting semantic success.
    root=next(iter(paths.values())).parent
    guard=figure_tuple_guard(helper,root)
    if guard is None:return False
    if verdict['version']==3:
        for path,(_,identity) in guard[1].items():
            if Path(path).is_relative_to(root):identity.pop('sha1')
    if _prepared_figure_guard_digest(guard,verdict['version'])!=verdict['guard_sha256']:return False
    source.require_python()
    if figure_tuple_guard(helper,next(iter(paths.values())).parent,authenticated=guard)!=guard:return False
    encoded=json.dumps(result,sort_keys=True,separators=(',',':'))
    with _FIGURE_TUPLE_REPLAY_LOCK:
        if len(_FIGURE_TUPLE_REPLAYS)>=32:_FIGURE_TUPLE_REPLAYS.clear()
        _FIGURE_TUPLE_REPLAYS[key]=(guard,encoded)
    return True


def capture_figure_files(args, transport=None, sleep=time.sleep, *, target_contract=None):
    """Finish capture and normal tuple replay inside one guarded proof lifetime."""
    import prepare_figure_metadata as helper
    completed = None

    def validate(root, *, retained_cache, inventory_cache):
        nonlocal completed
        paths = {role: root / name for role, name in helper.output_roles(root).items()}
        guard = figure_tuple_guard(helper, root)
        # Unknown readsets keep the ordinary independent replay. No result is
        # published unless every source identity is covered by the normal guard.
        kwargs = {} if guard is None else {'retained_cache': retained_cache,
                                          'inventory_cache': inventory_cache}
        result = helper.verify_tuple(paths, args.wiki, args.date, **kwargs)
        if guard is not None:
            if figure_tuple_guard(helper, root, authenticated=guard) != guard:
                raise ValueError('Figure capture inputs changed during tuple validation')
            key = tuple(sorted((role, str(Path(path).absolute())) for role, path in paths.items()))
            completed = (key, guard, json.dumps(result, sort_keys=True, separators=(',', ':')))

    options = {} if target_contract is None else {'target_contract': target_contract}
    manifest = helper.capture_files(args, transport=transport, sleep=sleep,
                                    _after_capture=validate, **options)
    # Capture rechecks ancestors and SQL after the callback, clears its caches,
    # and releases its lock before returning. Publish no earlier than that.
    if completed is not None:
        key, guard, result = completed
        if figure_tuple_guard(helper, Path(args.output), authenticated=guard) != guard:
            raise ValueError('Figure capture inputs changed before tuple publication')
        with _FIGURE_TUPLE_REPLAY_LOCK:
            if len(_FIGURE_TUPLE_REPLAYS) >= 32:
                _FIGURE_TUPLE_REPLAYS.clear()
            _FIGURE_TUPLE_REPLAYS[key] = (guard, result)
    return manifest



def require_figure_capture_helper():
    """Require the selected maintained API without granting capture validity."""
    import prepare_figure_metadata as figure
    if not callable(getattr(figure,'capture_member_paths',None)):
        raise ValueError('Selected Figure helper lacks capture_member_paths')
    return figure


def validated_figure_tuple(snapshots, edition=None, date=None, *, parent_snapshots=None):
    paths={name:Path(path) for name,path in (snapshots or {}).items() if name in FIGURE_SNAPSHOT_FILES}
    if not paths:return {}
    missing=set(FIGURE_SNAPSHOT_FILES)-set(paths)
    if missing:
        raise ValueError('Incomplete Figure input tuple; missing: '+', '.join(sorted(missing)))
    provider=(snapshots or {}).get('file-metadata')
    if provider is not None and Path(provider).parent in {path.parent for path in paths.values()}:
        paths['file-metadata']=Path(provider)
    prepare_figure_metadata=require_figure_capture_helper()
    parent_paths = None if parent_snapshots is None else {
        name: Path(parent_snapshots[name]) for name in paths if name in parent_snapshots}
    return verified_figure_tuple(prepare_figure_metadata,paths,edition,date,parent_paths=parent_paths)


def preflight_selected_auxiliary_inputs(snapshots, *, captured_selection=None):
    """Reject absent selected inputs before replay; confer no validation proof."""
    figure_roots={Path(path).parent for name,path in (snapshots or {}).items()
                  if name in FIGURE_SNAPSHOT_FILES}
    if figure_roots:require_figure_capture_helper()
    for name,source in sorted((snapshots or {}).items()):
        if name not in AUXILIARY_SNAPSHOT_NAMES:
            raise ValueError(f'Unknown auxiliary snapshot: {name}')
        path=Path(source)
        if not path.resolve(strict=True).is_file():
            raise ValueError(f'Auxiliary snapshot is not a file: {path}')
        shared_figure=(name in FIGURE_SNAPSHOT_FILES or
                       (name=='file-metadata' and path.parent in figure_roots))
        captured_manifest=(captured_selection is not None and
                           name in ('namespace-registry','site-info','category-stats','category-tree'))
        # Reuse helper selection, including legacy manifest-optional contracts.
        # The shared Figure Provider needs no additional manifest parse here.
        if shared_figure or captured_manifest or auxiliary_capture_helper(name,path) is not None:
            manifest=path.with_name('figure-inputs.manifest.json' if shared_figure
                                    else auxiliary_manifest_filename(name,path))
            if not manifest.resolve(strict=True).is_file():
                raise ValueError(f'Auxiliary manifest is not a file: {manifest}')


def validated_language_message_pair(snapshots, edition=None, date=None):
    """Replay a complete co-located pair once within one validation boundary."""
    names=('interface-messages','language-fallbacks')
    if not all(name in (snapshots or {}) for name in names):return None
    paths={name:Path(snapshots[name]) for name in names}
    root=paths[names[0]].parent
    if any(path.parent!=root or path.name!=name+'.tsv' for name,path in paths.items()):return None
    helpers=[auxiliary_capture_helper(name,paths[name]) for name in names]
    helper=helpers[0]
    if (helper is None or helpers[1] is not helper or helper.__name__ not in
            ('prepare_language_messages','prepare_language_messages_v2','prepare_language_messages_union')):
        return None
    manifests={name:name+'.manifest.json' for name in names}
    raw={name:helper.evidence.small(root/filename,helper.MAX_MANIFEST)
         for name,filename in manifests.items()}
    records={name:helper.evidence.decode(body) for name,body in raw.items()}
    files=set(manifests.values())|{helper.COMPLETE}
    for name,record in records.items():
        if (not isinstance(record,dict) or
                (edition is not None and record.get('wiki')!=edition) or
                (date is not None and record.get('date')!=date)):
            raise ValueError('Auxiliary capture edition/date mismatch: '+name)
        inventory=record.get('artifacts')
        if not isinstance(inventory,dict):raise ValueError('Incomplete language/message capture inventory')
        files.update(inventory)
    if any(not isinstance(name,str) or Path(name).name!=name or name in ('.','..') for name in files):
        raise ValueError('Unsafe language/message capture inventory')
    def identity():
        return (_figure_replay_identity(root,directory=True),
                {name:_figure_replay_identity(root/name) for name in sorted(files)})
    initial=identity()
    verified=helper.verify(root)
    if verified!=records:raise ValueError('Language/message manifests changed during validation')
    marker_hashes={filename:hashlib.sha256(raw[name]).hexdigest()
                   for name,filename in manifests.items()}
    marker_hashes[helper.COMPLETE]=helper.evidence.digest(
        helper.evidence.small(root/helper.COMPLETE,helper.MAX_MANIFEST))
    captures={}
    for name,record in records.items():
        inventory={filename:row['sha256'] for filename,row in record['artifacts'].items()}
        inventory.update(marker_hashes)
        if name+'.tsv' not in inventory:raise ValueError('Incomplete language/message capture inventory')
        if any(not isinstance(value,str) or not re.fullmatch('[0-9a-f]{64}',value) for value in inventory.values()):
            raise ValueError('Unsafe language/message capture digest')
        captures[name]=(record,inventory)
    def unchanged():
        if identity()!=initial:raise ValueError('Language/message capture changed during auxiliary validation')
    unchanged()
    return captures,unchanged


def _validated_auxiliary_state(snapshots, edition=None, date=None, *, captured_selection=None):
    preflight_selected_auxiliary_inputs(snapshots,captured_selection=captured_selection)
    hashes={};namespace_inputs={};captures={};message_pair=None
    figure_paths={name:Path(path) for name,path in (snapshots or {}).items() if name in FIGURE_SNAPSHOT_FILES}
    provider=(snapshots or {}).get('file-metadata')
    if provider is not None and Path(provider).parent in {path.parent for path in figure_paths.values()}:
        figure_paths['file-metadata']=Path(provider)
    def figure_output_identity(path):
        resolved=path.resolve(strict=True)
        info=path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f'Unsafe Figure output path: {path}')
        return (str(resolved),info.st_dev,info.st_ino,info.st_mode,info.st_size,
                info.st_mtime_ns,info.st_ctime_ns)
    figure_identities={name:figure_output_identity(path) for name,path in figure_paths.items()}
    figures={};observation_guard=None;observation_paths={}
    def observation_identity():
        root=Path(snapshots['figure-page-observations']).parent
        directory=_figure_replay_identity(root,directory=True)
        return (directory[0],directory[1][:3],
                {name:_figure_replay_identity(path) for name,path in observation_paths.items()})
    def validation_order():
        nonlocal figures,observation_guard,observation_paths
        # Finish observation validation first: an incompatible capture must not
        # incur Figure replay. The ordinary role body below still runs once.
        if 'figure-page-observations' in (snapshots or {}):
            path=Path(snapshots['figure-page-observations'])
            helper=auxiliary_capture_helper('figure-page-observations',path)
            observation_paths={name:path.with_name(name) for name in
                (helper.SNAPSHOT,helper.NAMESPACE,helper.DEFAULTS,helper.MANIFEST,helper.COMPLETE)}
            # Preserve the validator's original error if an input is unavailable
            # or unsafe. Only a successful complete capture can use these stamps.
            try:observation_guard=observation_identity()
            except (OSError,ValueError):observation_guard=None
            yield 'figure-page-observations',path
            if (observation_guard is None or
                    set(captures['figure-page-observations'][1])!=set(observation_paths)):
                raise ValueError('Observation capture changed during auxiliary validation')
        with build_phase(edition,date,'auxiliary_provider_verification',provider='figure-tuple'):
            figures=validated_figure_tuple(snapshots,edition,date)
        for name,source in sorted((snapshots or {}).items()):
            if name!='figure-page-observations':yield name,source
    for name, source in validation_order():
        with build_phase(edition,date,'auxiliary_provider_verification',provider=name):
            if name not in AUXILIARY_SNAPSHOT_NAMES:
                raise ValueError(f'Unknown auxiliary snapshot: {name}')
            path=Path(source)
            if name in ('interface-messages','language-fallbacks'):
                if message_pair is None:
                    message_pair=validated_language_message_pair(snapshots,edition,date) or False
                if message_pair:message_pair[1]()
            capture=(message_pair[0][name] if message_pair and name in message_pair[0] else
                     figures[name] if name in figures else validated_auxiliary_capture(name,path,edition,date))
            if captured_selection is not None and name!='language-registry':
                selected_capture,selected_sources,capture_root=captured_selection
                # Share only this freshly validated result with the adjacent source
                # binding check. Nothing escapes this call or skips later rechecks.
                _validate_captured_snapshot_context(name,path,selected_capture,
                    selected_sources,capture_root,capture)
            if capture is not None and (name in FIGURE_SNAPSHOT_FILES or name in ('stylesheet-imports','language-fallbacks','interface-messages','commons-data','language-names','date-numbering','site-info','site-statistics-format','category-statistics-format','wikibase-page-links','file-metadata','figure-page-observations','page-language','behavior-switches','image-options','parser-function-facts')):
                namespace_inputs[name]=capture[0]['namespace_registry_sha256']
            path=path.resolve(strict=True)
            if not path.is_file(): raise ValueError(f'Auxiliary snapshot is not a file: {path}')
            if name in figures:
                # The full tuple verifier just hashed this exact role and artifact.
                # Reuse its digest only within this unchanged-file validation call.
                if (Path(source)!=figure_paths[name] or
                        figure_output_identity(Path(source))!=figure_identities[name]):
                    raise ValueError('Figure output changed during auxiliary validation')
                sha=capture[0]['output_sha256']
                if (capture[0]['outputs'][name]!=sha or capture[1].get(path.name)!=sha):
                    raise ValueError('Figure output proof differs from selected role')
            else:
                sha=sha256_file(path)
            manifest=path.with_name(auxiliary_manifest_filename(name,path))
            if capture is not None or manifest.is_file():
                record=capture[0] if capture is not None else read_small_json(manifest)
                if (not isinstance(record,dict) or
                        record.get('output_sha256',record.get('tsv_sha256'))!=sha or
                        ('tsv_sha256' in record and record['tsv_sha256']!=sha) or
                        (edition is not None and record.get('wiki')!=edition) or
                        (date is not None and record.get('date')!=date)):
                    raise ValueError(f'Auxiliary snapshot differs from provenance: {path}')
            if capture is not None:captures[name]=(capture[0],capture[1],manifest.name)
            if name=='namespace-registry':
                with path.open(encoding='utf-8') as stream:header=[stream.readline().rstrip('\n') for _ in range(3)]
                if header[0]!='# wikidict-namespace-registry-v1' or (edition is not None and header[1]!='# wiki\t'+edition) or (date is not None and header[2]!='# dump-date\t'+date):
                    raise ValueError('Namespace registry identifies a different edition or date')
            hashes[name]=sha
    if 'figure-page-observations' in captures:
        # Moving this role before Figure replay must not extend its proof across
        # a replaced or changed payload, manifest, marker, or capture directory.
        try:current_observation_guard=observation_identity()
        except (OSError,ValueError):current_observation_guard=None
        if current_observation_guard!=observation_guard:
            raise ValueError('Observation capture changed during auxiliary validation')
        observations=captures['figure-page-observations'][0]
        if ('namespace-registry' not in hashes or 'figure-siteinfo' not in hashes or
                observations['namespace_registry_sha256']!=hashes['namespace-registry'] or
                observations['artifacts']['figure-page-observations.figure-siteinfo.raw.json']['sha256']!=hashes['figure-siteinfo']):
            raise ValueError('Figure page observations use different selected namespace/defaults inputs')
    if 'parser-function-facts' in captures:
        facts=captures['parser-function-facts'][0]
        if ('site-info' not in hashes or 'namespace-registry' not in hashes or
                facts['site_info_sha256']!=hashes['site-info'] or
                facts['namespace_registry_sha256']!=hashes['namespace-registry']):
            raise ValueError('Parser-function facts use different selected namespace/site-info inputs')
    if 'site-statistics-format' in captures:
        formatting=captures['site-statistics-format'][0]
        if ('site-info' not in hashes or
                formatting['configuration']['site_info_sha256']!=hashes['site-info']):
            raise ValueError('Statistics formatting uses a different selected site-info snapshot')
    if 'category-statistics-format' in captures:
        formatting=captures['category-statistics-format'][0]['configuration']
        if ('site-info' not in hashes or 'category-stats' not in hashes or
                formatting['site_info_sha256']!=hashes['site-info'] or
                formatting['category_stats_sha256']!=hashes['category-stats']):
            raise ValueError('Category formatting uses different selected site-info/category statistics')
    if 'image-options' in captures:
        behavior=captures.get('behavior-switches')
        if behavior is None or captures['image-options'][0]['behavior_manifest_sha256']!=behavior[1]['behavior-switches.manifest.json']:
            raise ValueError('Image options use a different selected behavior capture')
    if 'namespace-registry' in hashes:
        for name,digest in namespace_inputs.items():
            if digest!=hashes['namespace-registry']:
                raise ValueError('Auxiliary capture uses a different namespace registry: '+name)
    if figures:
        manifests={captures[name][1]['figure-inputs.manifest.json'] for name in figures}
        if len(manifests)!=1:
            raise ValueError('Figure input roles belong to different source captures')
        if any(Path(snapshots[name])!=figure_paths[name] or
                figure_output_identity(figure_paths[name])!=figure_identities[name] for name in figures):
            raise ValueError('Figure output changed during auxiliary validation')
    if message_pair:message_pair[1]()
    return hashes,captures


def _project_auxiliary_capture_identities(captures):
    # Only project the inventories returned by the fresh validation immediately
    # above. No filesystem lookup, persistent cache, or caller-supplied authority.
    manifests={};artifacts={}
    for name,(_,inventory,manifest_name) in sorted(captures.items()):
        manifests[name]=inventory[manifest_name]
        artifacts[name]=auxiliary_artifact_digest(inventory)
    return manifests,artifacts



SOURCE_FIELDS=('wiki','date','name','url','size','sha1')

def selected_source(record, selected):
    if not isinstance(record,dict):raise ValueError('Invalid captured source identity')
    identity={key:record.get(key) for key in SOURCE_FIELDS}
    matches=[item for item in selected if item.get('name')==identity['name']]
    if len(matches)!=1 or {key:matches[0].get(key) for key in SOURCE_FIELDS}!=identity:
        raise ValueError('Captured source differs from selected dump inventory')
    return identity


def validate_capture_artifacts(root, record, required=()):
    artifacts=record.get('artifacts')
    if not isinstance(artifacts,dict) or any(name not in artifacts for name in required):raise ValueError('Missing capture artifact inventory')
    for name,digest in artifacts.items():
        if not isinstance(name,str) or Path(name).name!=name or name in ('.','..'):raise ValueError('Unsafe capture artifact name')
        path=root/name
        if not path.is_file() or not path.resolve().is_relative_to(root) or sha256_file(path)!=digest:raise ValueError('Missing or changed capture artifact: '+name)


def validate_captured_snapshot(name,path,capture,selected,capture_root=None):
    # Standalone validation always obtains fresh evidence; callers cannot supply
    # a cached proof. The resolver shares its result only inside its hash loop.
    needs_capture=(name in FIGURE_SNAPSHOT_FILES or name in ('stylesheet-imports','figure-page-observations','page-language','behavior-switches','image-options','wikibase-page-links','site-info','file-metadata','parser-function-facts') or
        (capture_root is not None and name in ('wikibase-entities','wikibase-entity-terms',
            'language-fallbacks','interface-messages','commons-data','language-names','date-numbering','file-metadata')))
    bound=validated_auxiliary_capture(name,path,capture.get('wiki'),capture.get('date')) if needs_capture else None
    return _validate_captured_snapshot_context(name,path,capture,selected,capture_root,bound)


def _validate_captured_snapshot_context(name,path,capture,selected,capture_root,bound):
    if name=='figure-page-observations':
        if bound is None:
            raise ValueError('Figure page observations require fresh capture verification')
        if capture_root is not None and bound[0]['namespace_registry_sha256']!=sha256_file(capture_root/'namespace-registry.tsv'):
            raise ValueError('Figure page observations use a different selected namespace registry')
        return
    if name=='page-language':
        if capture_root is not None and bound[0]['namespace_registry_sha256']!=sha256_file(capture_root/'namespace-registry.tsv'):
            raise ValueError('Page language namespace differs from selected capture')
        return
    if name=='parser-function-facts':
        if capture_root is not None and bound[0]['namespace_registry_sha256']!=sha256_file(capture_root/'namespace-registry.tsv'):
            raise ValueError('Parser-function facts use a different selected namespace registry')
        return
    if name in FIGURE_SNAPSHOT_FILES or (name=='file-metadata' and bound is not None and bound[0].get('schema')=='wikidict.figure-inputs.v1'):
        if capture_root is not None and bound[0]['namespace_registry_sha256']!=sha256_file(capture_root/'namespace-registry.tsv'):
            raise ValueError('Figure inputs use a different selected namespace registry')
        if bound[0].get('coverage',{}).get('kind')=='file-logical-axes':
            for source in bound[0]['source_dump_files']:selected_source(source,selected)
        return
    if name=='stylesheet-imports':
        if capture_root is not None and bound[0]['namespace_registry_sha256']!=sha256_file(capture_root/'namespace-registry.tsv'):
            raise ValueError('Stylesheet import namespace differs from selected capture')
        return
    if name in ('behavior-switches','image-options'):
        if capture_root is not None:
            if bound[0]['namespace_registry_sha256']!=sha256_file(capture_root/'namespace-registry.tsv'):
                raise ValueError(name+' uses a different selected namespace registry')
            for embedded,selected_name in (('behavior-source-namespace-siteinfo.raw.json','namespace-siteinfo.raw.json'),('behavior-source-namespace-capture.complete.json','capture.complete.json')):
                if bound[1][embedded]!=sha256_file(capture_root/selected_name):
                    raise ValueError(name+' uses a different namespace capture')
        return
    if name=='wikibase-page-links':
        record=bound[0]
        for source in record['source_dump_files']:selected_source(source,selected)
        if capture_root is not None and record['namespace_registry_sha256']!=sha256_file(capture_root/'namespace-registry.tsv'):
            raise ValueError('Page-link supplement namespace differs from selected capture')
        return
    if name=='site-info':
        if bound[0].get('schema')=='wikidict.site-info-capture.v2':
            if capture_root is not None and bound[0]['namespace_registry_sha256']!=sha256_file(capture_root/'namespace-registry.tsv'):
                raise ValueError('Site-info uses a different namespace capture')
            return
        if capture_root is not None and bound[1]['capture.complete.json']!=sha256_file(capture_root/'capture.complete.json'):
            raise ValueError('Siteinfo belongs to a different namespace capture')
    if capture_root is not None and name in ('wikibase-entities','wikibase-entity-terms','language-fallbacks','interface-messages','commons-data','language-names','date-numbering','file-metadata'):
        if bound is not None:
            _,inventory=bound
            inputs=(('wikibase-namespace-siteinfo.raw.json','namespace-siteinfo.raw.json'),
                    ('wikibase-namespace-capture.complete.json','capture.complete.json')) if name.startswith('wikibase-') else (
                    ('commons-namespace-registry.tsv','namespace-registry.tsv'),) if name=='commons-data' else (
                    ('base.language-autonyms.namespace-registry.tsv','namespace-registry.tsv'),) if name=='language-names' and bound[0].get('schema')=='wikidict.language-names-profile-union.v1' else (
                    ('language-autonyms.namespace-registry.tsv','namespace-registry.tsv'),) if name=='language-names' and bound[0].get('schema')=='wikidict.language-names-autonym-capture.v1' else (
                    ('language-names.namespace-registry.tsv','namespace-registry.tsv'),) if name=='language-names' else (
                    ('date-numbering.namespace-registry.tsv','namespace-registry.tsv'),) if name=='date-numbering' else (
                    ('file-metadata.namespace-registry.tsv','namespace-registry.tsv'),) if name=='file-metadata' else (
                    ('language-messages.namespace-registry.tsv','namespace-registry.tsv'),)
            for copied,original in inputs:
                if inventory.get(copied)!=sha256_file(capture_root/original):
                    raise ValueError('Auxiliary namespace source differs from selected capture: '+name)
        return
    if name not in ('namespace-registry','site-info','category-stats','category-tree'):
        return
    record=read_small_json(path.with_name(auxiliary_manifest_filename(name)))
    if name in ('namespace-registry','site-info'):
        if record.get('source_dump_files')!=[capture['source_xml']]:raise ValueError('Namespace source differs from capture')
        for key,artifact in [('raw_siteinfo_sha256','namespace-siteinfo.raw.json'),('dump_siteinfo_sha256','dump-siteinfo.xml')]:
            if record.get(key)!=capture['artifacts'][artifact]:raise ValueError('Namespace capture hash mismatch')
        if record.get('retrieved_utc')!=capture.get('retrieved_utc') or record.get('source_url')!=capture.get('siteinfo_source_url') or record.get('supplementary_api_scope')!=capture.get('siteinfo_temporal_scope'):raise ValueError('Namespace API observation mismatch')
    elif name=='category-stats':
        source=selected_source(dict(wiki=record.get('wiki'),date=record.get('date'),name=record.get('source'),url=record.get('source_url'),size=record.get('source_bytes'),sha1=record.get('source_sha1')),selected)
        if not source['name'].endswith('-category.sql.gz'):raise ValueError('Invalid category statistics source')
        if record.get('output')!=path.name or record.get('output_bytes')!=path.stat().st_size:raise ValueError('Category statistics output mismatch')
    elif name=='category-tree':
        sources=record.get('sources',{})
        if set(sources)!=set(('page','linktarget','categorylinks')):raise ValueError('Invalid category tree source inventory')
        for kind,source in sources.items():
            source=selected_source(source,selected)
            if not source['name'].endswith('-'+kind+'.sql.gz'):raise ValueError('Invalid category tree source table')
        if record.get('dump_siteinfo_sha256')!=capture['artifacts']['dump-siteinfo.xml'] or record.get('output_bytes')!=path.stat().st_size:raise ValueError('Category tree capture mismatch')


def discover_auxiliary_generation(root,directory,names,edition,date):
    generation=root/directory
    if not (generation.exists() or generation.is_symlink()):return {}
    if generation.is_symlink() or not generation.is_dir():
        raise ValueError('Unsafe auxiliary capture generation: '+str(generation))
    snapshots={name:generation/(auxiliary_snapshot_filename(name)) for name in names}
    # The first name always requires a strict capture helper. It validates the
    # whole pair before either output can replace a legacy flat snapshot.
    helper=auxiliary_capture_helper(names[0],snapshots[names[0]])
    if directory=='site-info' and helper.__name__!='prepare_site_info':
        raise ValueError('Preferred site-info requires its versioned capture profile')
    if directory=='language-names-autonyms-v1' and helper.__name__ not in ('prepare_language_names_autonyms','prepare_language_names_union'):
        raise ValueError('Preferred autonym names require their versioned capture profile')
    if directory=='language-messages-loop-v1':
        import prepare_language_messages_v2 as messages
        import prepare_language_messages_union as message_union
        if helper not in (messages,message_union):
            raise ValueError('Preferred loop messages require the current v2 capture profile')
    if directory=='figure-inputs':
        provider=generation/'file-metadata.tsv'
        if provider.exists() or provider.is_symlink():snapshots['file-metadata']=provider
        validated_figure_tuple(snapshots,edition,date)
        return snapshots
    for path in snapshots.values():
        record=helper.validate_snapshot(path,edition,date)
        if directory=='language-messages-loop-v1':
            if helper is message_union:
                message_union.require_preferred_loop(record)
                continue
            messages.require_preferred_loop(record)
    return snapshots


def resolve_figure_snapshot_options(root, manifest, selected, downloads, namespace, overrides, *, metadata_network='offline', figure_reuse_batches=()):
    """Reuse one shared capture; acquisition requires explicit network policy."""
    if metadata_network not in ('offline', 'allow'):
        raise ValueError('Invalid metadata network policy')
    figure_reuse_batches = tuple(figure_reuse_batches)
    if any(not isinstance(path, Path) for path in figure_reuse_batches) or len(set(figure_reuse_batches)) != len(figure_reuse_batches):
        raise ValueError('Invalid or duplicate Figure reuse batch paths')
    explicit = set(overrides or {}) & set(FIGURE_SNAPSHOT_FILES)
    if explicit:
        if figure_reuse_batches:
            raise ValueError('Explicit Figure inputs conflict with reuse batch records')
        if explicit != set(FIGURE_SNAPSHOT_FILES):
            raise ValueError('Incomplete explicit Figure input tuple')
        return {}
    edition, date = selected[0]['wiki'], selected[0]['date']
    generation = root/'figure-inputs'
    if generation.is_symlink() or (generation.exists() and not generation.is_dir()):
        raise ValueError('Unsafe Figure capture generation')
    if metadata_network == 'offline' and not figure_reuse_batches:
        return discover_auxiliary_generation(root, 'figure-inputs', tuple(FIGURE_SNAPSHOT_FILES), edition, date)
    if 'file-metadata' in (overrides or {}):
        raise ValueError('Explicit Provider input requires an explicit complete Figure tuple')
    import prepare_figure_metadata as figures
    # A published but invalid capture is an error, never a reason for HTTP.
    if not figure_reuse_batches and ((generation/figures.COMPLETE).exists() or (generation/figures.COMPLETE).is_symlink()):
        return discover_auxiliary_generation(root, 'figure-inputs', tuple(FIGURE_SNAPSHOT_FILES), edition, date)
    with acquire_build_resource_lock(root/'.figure-inputs.lock'):
        if not figure_reuse_batches and ((generation/figures.COMPLETE).exists() or (generation/figures.COMPLETE).is_symlink()):
            return discover_auxiliary_generation(root, 'figure-inputs', tuple(FIGURE_SNAPSHOT_FILES), edition, date)
        reuse = {'reuse_batches': figure_reuse_batches} if figure_reuse_batches else {}
        paths = figures.prepare_for_build(root, manifest, selected, downloads, namespace, network=metadata_network == 'allow', **reuse)
        expected = dict(FIGURE_SNAPSHOT_FILES, **{'file-metadata': 'file-metadata.tsv'})
        if set(paths) != set(expected) or any(Path(paths[name]) != generation/filename for name,filename in expected.items()):
            raise ValueError('Prepared Figure paths differ from the normal shared capture')
        # The normal resolver below validates this whole tuple before binding it.
        return {name:Path(path) for name,path in paths.items()}


def resolve_edition_snapshot_options(manifest, groups, downloads, overrides=None, *, workspace=None, metadata_network='offline', figure_reuse_batches=()):
    """Resolve each edition independently; never reuse another edition's captures."""
    workspace=PROJECT if workspace is None else workspace
    if metadata_network not in ('offline', 'allow'):
        raise ValueError('Invalid metadata network policy')
    captures=manifest.get('auxiliary_capture_roots',{})
    if not isinstance(captures,dict):raise ValueError('Invalid auxiliary capture roots')
    derived_paths=derived_registry_paths(manifest,downloads)
    records=manifest.get('language_registries',[])
    if not isinstance(records,list):raise ValueError('Invalid language registry inventory')
    languages={}
    for record in records:
        if not isinstance(record,dict):raise ValueError('Invalid language registry record')
        key=(record.get('wiki'),record.get('date'))
        if key in languages:raise ValueError('Duplicate language registry identity')
        languages[key]=record
    result={}
    def discover(root, directory, names, edition, date):
        # A complete explicit selection supersedes discovery, not validation.
        # Paired generations still validate together if either member is needed.
        if all(name in (overrides or {}) for name in names):
            return {}
        return discover_auxiliary_generation(root, directory, names, edition, date)
    for edition,date in groups:
        with build_phase(edition,date,'selected_snapshot_resolution',scope='pre_edition'):
            snapshots={}
            captured=captures.get(edition)
            if captured is not None:
                if not isinstance(captured,str) or Path(captured).is_absolute() or '..' in Path(captured).parts:raise ValueError('Unsafe auxiliary capture root')
                root=(workspace/captured).resolve(strict=True)
                record=read_small_json(root/'capture.complete.json',2*1024*1024)
                if record.get('wiki')!=edition or record.get('date')!=date:raise ValueError('Auxiliary capture edition/date mismatch')
                if not root.is_relative_to(workspace.resolve()):raise ValueError('Capture root escapes project')
                selected=groups[(edition,date)]
                if len({item['name'] for item in selected})!=len(selected):raise ValueError('Duplicate selected source')
                source=selected_source(record.get('source_xml'),selected)
                if '-pages-meta-current' not in source['name']:raise ValueError('Capture lacks full-namespace XML')
                if record.get('namespace_mismatches')!=[]:raise ValueError('Capture namespace mismatch')
                for source in record.get('page_table_files',[]):selected_source(source,selected)
                validate_capture_artifacts(root,record,('dump-siteinfo.xml','namespace-siteinfo.raw.json','pagetable-dumpstatus.raw.json'))
                capture=record
                for marker in ('auxiliary-basic.complete.json','auxiliary-all.complete.json'):
                    if (root/marker).exists():validate_capture_artifacts(root,read_small_json(root/marker))
                preferred=discover(root,'wikibase-entities',
                    ('wikibase-entities','wikibase-entity-terms'),edition,date)
                message_snapshots=discover(root,'language-messages-loop-v1',
                    ('language-fallbacks','interface-messages'),edition,date)
                if not message_snapshots:
                    message_snapshots=discover(root,'language-messages',
                        ('language-fallbacks','interface-messages'),edition,date)
                preferred.update(message_snapshots)
                preferred.update(discover(root,'commons-data',
                    ('commons-data',),edition,date))
                names_generation=discover(root,'language-names-autonyms-v1',
                    ('language-names',),edition,date)
                if not names_generation:
                    names_generation=discover(root,'language-names',
                        ('language-names',),edition,date)
                preferred.update(names_generation)
                preferred.update(discover(root,'date-numbering',
                    ('date-numbering',),edition,date))
                preferred.update(discover(root,'wikibase-page-links',
                    ('wikibase-page-links',),edition,date))
                preferred.update(discover(root,'site-info',
                    ('site-info',),edition,date))
                preferred.update(resolve_figure_snapshot_options(root,manifest,selected,downloads,
                    Path((overrides or {}).get('namespace-registry',root/'namespace-registry.tsv')),
                    overrides,metadata_network=metadata_network,figure_reuse_batches=figure_reuse_batches))
                preferred.update(discover(root,'site-statistics-format-v1',
                    ('site-statistics-format',),edition,date))
                preferred.update(discover(root,'category-statistics-format-v1',
                    ('category-statistics-format',),edition,date))
                preferred.update(discover(root,'page-language',
                    ('page-language',),edition,date))
                preferred.update(discover(root,'parser-function-facts',
                    ('parser-function-facts',),edition,date))
                for name in AUXILIARY_SNAPSHOT_NAMES:
                    if name in preferred or name in (overrides or {}):continue
                    path=root/(auxiliary_snapshot_filename(name))
                    sidecar=root/(auxiliary_manifest_filename(name))
                    present=[p.exists() or p.is_symlink() for p in (path,sidecar)]
                    if name=='page-language' and any((root/n).exists() or (root/n).is_symlink() for n in ('page-language.raw.json','page-language.html')) and not all(present):
                        raise ValueError(f'Uncommitted page language snapshot: {path}')
                    if any(present) and (not all(present) or not path.is_file() or not sidecar.is_file()):raise ValueError(f'Uncommitted auxiliary snapshot: {path}')
                    if all(present):snapshots[name]=path
                snapshots.update(preferred)
                if "magic-words" not in (overrides or {}):
                    from prepare_magic_words_file_page import selected_snapshot_root
                    magic_root=selected_snapshot_root(root)
                    if magic_root.exists() or magic_root.is_symlink():
                        if magic_root.is_symlink() or not magic_root.is_dir():raise ValueError('Unsafe magic-word capture root')
                        path=magic_root/'magic-words.tsv'
                        from prepare_magic_words_file_page import validate_snapshot
                        validate_snapshot(path,edition,date)
                        snapshots['magic-words']=path
            elif (downloads/edition/date/'namespace-registry.tsv').is_file():
                snapshots['namespace-registry']=downloads/edition/date/'namespace-registry.tsv'
            # Authenticated derivation supersedes captured discovery, never an explicit caller selection.
            if (edition,date) in derived_paths and 'language-registry' not in (overrides or {}):
                snapshots['language-registry']=derived_paths[(edition,date)]
            snapshots.update(overrides or {})
            if 'namespace-registry' not in snapshots:raise ValueError(f'Missing namespace registry for {edition}/{date}')
            if 'language-registry' not in snapshots:
                record=languages.get((edition,date))
                if record is None or record.get('name')!='language-registry.tsv':raise ValueError(f'Missing pinned language registry for {edition}/{date}')
                path=derived_paths.get((edition,date),downloads/edition/date/record['name'])
                if not path.is_file() or path.stat().st_size!=record.get('size') or sha256_file(path)!=record.get('sha256'):
                    raise ValueError(f'Unverified language registry: {path}')
                snapshots['language-registry']=path.resolve(strict=True)
            language_record=languages.get((edition,date))
            language=Path(snapshots['language-registry'])
            if not language_record or language_record.get('name')!='language-registry.tsv' or language.stat().st_size!=language_record.get('size') or sha256_file(language)!=language_record.get('sha256'):raise ValueError('Language registry differs from pinned inventory')
            verified_auxiliary_hashes(snapshots,edition,date,
                captured_selection=(capture,selected,root) if captured is not None else None)
            result[(edition,date)]={'auxiliary_snapshots':snapshots}
            if captured is not None:
                triple=[root/name for name in ('interwiki-map.tsv','interwiki-map.raw.json','interwiki-map.provenance.json')]
                present=[p.exists() or p.is_symlink() for p in triple]
                if any(present) and (not all(present) or not all(p.is_file() for p in triple)):raise ValueError('Uncommitted interwiki snapshot')
            if captured is not None and (root/'interwiki-map.tsv').is_file():
                path=root/'interwiki-map.tsv'
                if not (root/'interwiki-map.provenance.json').is_file():raise ValueError('Uncommitted interwiki snapshot')
                validate_interwiki_provenance(path,edition,sha256_file(path))
                interwiki=read_small_json(root/'interwiki-map.provenance.json')
                if interwiki.get('raw_sha256')!=capture['artifacts']['namespace-siteinfo.raw.json'] or interwiki.get('retrieved_utc')!=capture.get('retrieved_utc') or interwiki.get('source_url')!=capture.get('siteinfo_source_url') or interwiki.get('kind')!='current-siteinfo-interwikimap' or 'dump_date' not in interwiki:raise ValueError('Interwiki API observation mismatch')
                if interwiki.get('tsv_bytes')!=path.stat().st_size or interwiki.get('raw_bytes')!=(root/'interwiki-map.raw.json').stat().st_size:raise ValueError('Interwiki artifact size mismatch')
                result[(edition,date)]['interwiki_snapshot']=path
    return result


def require_exact_snapshot_selection(resolved, groups, snapshots, interwiki_snapshot=None):
    """Check the producer's fully validated result against the caller's selection."""
    if not isinstance(resolved, dict) or set(resolved) != set(groups):
        raise ValueError('Resolved snapshot editions differ from selected inputs')
    expected = {name: Path(path) for name, path in snapshots.items()}
    expected_interwiki = Path(interwiki_snapshot) if interwiki_snapshot is not None else None
    for options in resolved.values():
        if not isinstance(options, dict) or not isinstance(options.get('auxiliary_snapshots'), dict):
            raise ValueError('Resolved auxiliary snapshot selection is missing')
        actual = {name: Path(path) for name, path in options['auxiliary_snapshots'].items()}
        if actual != expected:
            raise ValueError('Resolved auxiliary snapshots differ from selected inputs')
        actual_interwiki = options.get('interwiki_snapshot')
        if actual_interwiki is not None:
            actual_interwiki = Path(actual_interwiki)
        if actual_interwiki != expected_interwiki:
            raise ValueError('Resolved interwiki snapshot differs from selected input')



def pipeline_snapshot_args(registry, snapshots, page_links_snapshot=None, page_redirects_snapshot=None):
    merged=dict(snapshots or {})
    merged.setdefault('language-registry',registry)
    if page_links_snapshot is not None:merged['wikibase-page-links']=page_links_snapshot
    if page_redirects_snapshot is not None:merged['page-redirects']=page_redirects_snapshot
    return auxiliary_snapshot_args(merged)


def pinned_auxiliary_snapshots(snapshots, hashes, destination, capture_hashes=None, capture_artifact_hashes=None, *, borrower=None, owned_roots=(), phase_outcome=None):
    timing_name=timing_started=None
    def timing_boundary(name):
        nonlocal timing_name,timing_started
        if phase_outcome is None:return
        try:
            now=time.monotonic()
            if timing_name is not None:
                phase_outcome[timing_name]=round(now-timing_started,3)
            timing_name,timing_started=name,now
        except Exception:
            # Match phase_event: observability must not replace a build result.
            timing_name=timing_started=None
    try:
        timing_boundary('source_validation_seconds')
        pinned={};copies={};captures={};role_copies={};borrowed=set();figure_members={}
        if borrower is not None and not isinstance(borrower,RetainedNativeToolRoles):
            raise ValueError('Auxiliary borrowing requires retained native input guards')
        if borrower is not None:borrower.staged_provider_inputs={}
        figures=validated_figure_tuple(snapshots)
        def add_copy(source,folder,filename,digest):
            key=(folder,filename)
            if key in copies and copies[key][1]!=digest:
                raise ValueError('Conflicting auxiliary capture artifact: '+filename)
            copies.setdefault(key,(source,digest))
        for name,source in sorted((snapshots or {}).items()):
            source=Path(source)
            capture=figures[name] if name in figures else validated_auxiliary_capture(name,source)
            autonym_capture=(name=='language-names' and capture is not None and
                             capture[0].get('schema') in ('wikidict.language-names-autonym-capture.v1',
                                                        'wikidict.language-names-profile-union.v1'))
            # Keep complete directory-provenance captures separate from other
            # snapshots so strict replay sees only their own recorded payloads.
            folder=destination/'figure-inputs' if name in figures or (capture is not None and capture[0].get('schema')=='wikidict.figure-inputs.v1') else destination/name if name in ('stylesheet-imports','commons-data','date-numbering','site-statistics-format','category-statistics-format','page-language','figure-page-observations','parser-function-facts') or autonym_capture else (
                destination/'site-info' if name=='site-info' and
                auxiliary_manifest_filename(name,source)=='site-info.manifest.json' else destination)
            if folder.is_symlink():raise ValueError('Unsafe auxiliary capture directory: '+str(folder))
            pinned[name]=folder/(auxiliary_snapshot_filename(name))
            role_copies[name]={(folder,auxiliary_snapshot_filename(name))}
            add_copy(source,folder,auxiliary_snapshot_filename(name),hashes[name])
            if capture is None:
                if name in (capture_hashes or {}) or name in (capture_artifact_hashes or {}):
                    raise ValueError('Auxiliary capture disappeared before pinning: '+name)
                continue
            _,inventory=capture
            if capture_hashes is not None and inventory[auxiliary_manifest_filename(name,source)]!=capture_hashes.get(name):
                raise ValueError('Auxiliary capture changed before pinning: '+name)
            if capture_artifact_hashes is not None and auxiliary_artifact_digest(inventory)!=capture_artifact_hashes.get(name):
                raise ValueError('Auxiliary capture artifacts changed before pinning: '+name)
            captures[name]=inventory
            for filename,digest in inventory.items():
                member=source.with_name(filename) if '/' not in filename else None
                if member is None:
                    if name not in figures:
                        raise ValueError('Contained artifacts require a verified Figure capture')
                    import prepare_figure_metadata as figure
                    root=source.parent
                    if root not in figure_members:
                        members,_=figure.capture_member_paths(root,include_markers=True)
                        if set(members)!=set(inventory):
                            raise ValueError('Contained Figure members differ from validated inventory')
                        figure_members[root]=members
                    member=figure_members[root][filename]
                add_copy(member,folder,filename,digest)
                role_copies[name].add((folder,filename))
        # Resolve all logical destination conflicts before borrowing anything.
        # Unknown, shared, overlapping and unguarded captures retain copying.
        timing_boundary('borrow_binding_seconds')
        if borrower is not None:
            owned=tuple(Path(path).resolve() for path in (destination,*owned_roots) if path is not None)
            def overlaps_owned(path):
                # Both callers have just required this exact path to resolve to
                # itself. Binding and dispatch retain their fresh route guards.
                return any(path==root or path in root.parents or root in path.parents for root in owned)
            bound_figures={}
            capture_bindings=0;reused_capture_bindings=0
            for name,source in (snapshots or {}).items():
                if name in captures or name not in ('category-tree','category-stats'):continue
                if borrower.bind_plain_category(name,Path(source),hashes[name],owned_roots=owned):
                    pinned[name]=Path(source);borrowed.add(name)
            for name,inventory in captures.items():
                source=Path(snapshots[name]);root=source.parent
                if source.name!=auxiliary_snapshot_filename(name):continue
                if (not root.is_absolute() or root.resolve()!=root or
                        any(path.is_symlink() for path in (root,*root.parents)) or
                        overlaps_owned(root)):continue
                guard=None;reused=False
                if name in figures:
                    # The immediately preceding full validation owns this exact
                    # complete transitive SQL/parent readset, never an inferred one.
                    key=tuple(sorted((role,str(Path(snapshots[role]).absolute())) for role in figures))
                    with _FIGURE_TUPLE_REPLAY_LOCK:
                        previous=_FIGURE_TUPLE_REPLAYS.get(key)
                        guard=None if previous is None else previous[0]
                    if guard is None:continue
                    bound=bound_figures.get(root)
                    reused=bound is not None and inventory==bound[0] and guard==bound[1]
                    if not reused:
                        import prepare_figure_metadata as figure
                        members,_=figure.capture_member_paths(root,include_markers=True)
                        if set(members)!=set(inventory):continue
                        if any(Path(path).resolve()!=Path(path) or overlaps_owned(Path(path))
                               for path in (*guard[1],*guard[2])):continue
                else:
                    members=tuple(sorted(root.iterdir()))
                    if ({path.name for path in members}!=set(inventory) or
                            any(path.is_symlink() or not path.is_file() for path in members)):continue
                    if name not in ('wikibase-entities','wikibase-entity-terms'):continue
                if reused:
                    reused_capture_bindings+=1
                else:
                    if name in figures:
                        # Validate the exact descriptor snapshot kept for this
                        # invocation; mutable caller data is never its own proof.
                        import copy
                        bound=(dict(inventory),copy.deepcopy(guard))
                        borrower.bind_capture(root,bound[0],figure_guard=bound[1])
                        bound_figures[root]=bound
                    else:
                        borrower.bind_capture(root,inventory)
                    capture_bindings+=1
                pinned[name]=source;borrowed.add(name)
                if name in WIKIBASE_PROVIDER_ROLES:
                    # Native Provider resealing keeps installed snapshot links
                    # at their original workspace path across data-only updates.
                    borrower.staged_provider_inputs[name]=folder/auxiliary_snapshot_filename(name)
            borrower.require_unchanged()
        needed=set().union(*(keys for name,keys in role_copies.items() if name not in borrowed))
        if borrower is not None:
            needed.update((path.parent,path.name) for path in borrower.staged_provider_inputs.values())
        timing_boundary('copy_revalidation_seconds')
        for (folder,filename),(source,digest) in sorted(copies.items()):
            if (folder,filename) in needed:
                target=folder/filename
                if '/' in filename and any(parent.is_symlink() for parent in (target.parent,*target.parent.parents)):
                    raise ValueError('Unsafe contained Figure staging directory')
                copy_verified_snapshot(source,target,digest)
        if borrower is not None:
            for name,path in borrower.staged_provider_inputs.items():
                if borrower.bind_input(path)['sha256']!=hashes[name]:
                    raise ValueError('Staged Provider payload differs from original capture')
        timing_boundary('destination_validation_seconds')
        if set(figures)<=borrowed:
            pinned_figures=figures
        else:
            pinned_figures=validated_figure_tuple(pinned,parent_snapshots=snapshots)
        for name,inventory in captures.items():
            if name in borrowed:continue
            capture=pinned_figures[name] if name in pinned_figures else validated_auxiliary_capture(name,pinned[name])
            if capture is None or capture[1]!=inventory:
                raise ValueError('Auxiliary capture changed while pinning: '+name)
        if borrower is not None:
            borrower.require_unchanged()
            avoided=set(copies)-needed
            plain=borrowed & {'category-tree','category-stats'}
            borrower.last_capture_borrow=dict(borrowed_roles=sorted(borrowed),borrowed_capture_files=len(avoided)-len(plain),
                avoided_copy_bytes=sum(copies[key][0].stat().st_size for key in avoided),
                borrowed_plain_category_files=len(plain),
                avoided_plain_category_copy_bytes=sum(Path(snapshots[name]).stat().st_size
                    for name in plain))
            if phase_outcome is not None:
                phase_outcome.update(capture_bindings=capture_bindings,
                                     reused_capture_bindings=reused_capture_bindings)
        return pinned
    finally:
        timing_boundary(None)
        release_figure_parent_replays()


def auxiliary_snapshot_args(snapshots):
    return [piece for name,path in sorted((snapshots or {}).items())
            for piece in ('--'+name+'-snapshot',str(path))]


def require_figure_inputs(snapshots, *, required=None):
    # The maintained pre-Figure renderer remains usable with its old contract.
    # A source tree containing the Figure provider must declare all four inputs
    # before expensive download verification, native preparation or expansion.
    if required is None:required=(PROJECT/'tools'/'figure_sizing.zig').is_file()
    missing=set(FIGURE_SNAPSHOT_FILES)-set(snapshots or {})
    if required and missing:
        raise ValueError('Missing verified Figure inputs before native preparation: '+
                         ', '.join(sorted(missing))+
                         '. Stage a matching Figure capture; general site-info and file metadata alone are insufficient.')


# These standalone orchestration/qualification tools are not imported or
# executed by the ordinary production dependency graph. Keep every other source
# file, including tests, in the conservative production cache identity.
SHARD_SOURCE_EXCLUSIONS = frozenset((
    'tools/corpus_controller.py', 'tools/test_corpus_controller.py',
    'tools/native_qualification.py', 'tools/test_native_qualification.py',
    'tools/verify_presentation.py', 'tools/test_verify_presentation.py',
    'tools/audit_checkpoint.py',
    'tools/source_definition_audit.py', 'tools/test_source_definition_audit.py',
))


def retained_runtime_scope(native_roles):
    """Use the selected Python closure only when native compilation is forbidden."""
    if (_PYTHON_TOOLING is None or native_roles is None
            or getattr(_PREPARED_SOURCE, 'value', None) is not None
            or getattr(_PREPARED_SOURCE, 'request', None) is not None):
        return None
    if not isinstance(native_roles, RetainedNativeToolRoles):
        raise ValueError('Invalid retained native role selection')
    initial = native_roles.initial_sealed_generation
    whole = getattr(native_roles, 'closed_whole_execution', None)
    if initial is None and whole is None:
        return None
    original_context = getattr(native_roles, '_closed_native_context', None)
    adopted_context = native_roles.initial_sealed_context
    if (original_context is None or getattr(native_roles, 'closed_native_origin', None) is None
            or (adopted_context is not None and adopted_context != original_context)
            or native_roles.sealed_expander_recovery is not None
            or native_roles.writer_figure_transition is not None):
        raise ValueError('Retained runtime source requires its validated sealed worker')
    import copy
    return dict(schema='wikidict.retained-runtime-source.v1',
                kind='closed_whole_execution' if whole is not None else 'initial_sealed_generation',
                reference=copy.deepcopy(whole if whole is not None else initial))


def retained_runtime_fingerprints(scope, native_provenance):
    if (_PYTHON_TOOLING is None or not isinstance(scope, dict)
            or set(scope) != {'schema', 'kind', 'reference'}
            or scope['schema'] != 'wikidict.retained-runtime-source.v1'
            or scope['kind'] not in ('initial_sealed_generation', 'closed_whole_execution')
            or not isinstance(scope['reference'], dict) or not scope['reference']
            or not isinstance(native_provenance, dict) or not native_provenance):
        raise ValueError('Invalid retained runtime source identity')
    selected = _PYTHON_TOOLING.require_unchanged()
    payload = json.dumps(dict(scope=scope, python_tooling=selected,
                              native_tool_roles=native_provenance),
                         sort_keys=True, separators=(',', ':')).encode()
    # Native provenance describes the original immutable producer, never live src/.
    source = hashlib.sha256(b'wikidict.retained-runtime-source.v1\0' + payload).hexdigest()
    production = hashlib.sha256(b'wikidict.retained-runtime-production.v1\0' + payload).hexdigest()
    return source, production, selected


def _source_fingerprints(include_production=False):
    generation=getattr(_PREPARED_SOURCE,'value',None)
    if generation is not None:
        require_build_source(generation.identity)
        return generation.identity['source'],generation.record['workspace_state']['production_source'] if include_production else None
    checksum=hashlib.sha256()
    production=hashlib.sha256(b'wikidict.shard-production-source.v1\0') if include_production else None
    if _PYTHON_TOOLING is not None:
        selected=json.dumps(_PYTHON_TOOLING.require_unchanged(),sort_keys=True,separators=(',',':')).encode()
        checksum.update(b'wikidict.selected-python-tooling.v1\0'+selected+b'\0')
        if production is not None:production.update(b'wikidict.selected-python-tooling.v1\0'+selected+b'\0')
    files=[]
    for name in PRODUCER_SOURCE_FILES:
        path=PROJECT/name
        if path.is_file(): files.append(path)
    for folder in PRODUCER_SOURCE_DIRECTORIES:
        root=PROJECT/folder
        if not root.is_dir(): continue
        for directory, _, names in os.walk(root):
            for name in names:
                if os.path.splitext(name)[1] in ('.zig', '.py', '.c', '.h', '.zon'):
                    path = Path(directory, name)
                    if path.is_file():
                        files.append(path)
    for path in sorted(files,key=lambda x:x.relative_to(PROJECT).as_posix()):
        name=path.relative_to(PROJECT).as_posix()
        prefix=name.encode()+b'\0'
        checksum.update(prefix)
        included=production is not None and name not in SHARD_SOURCE_EXCLUSIONS
        if included:production.update(prefix)
        with path.open('rb') as source:
            while chunk:=source.read(1024*1024):
                checksum.update(chunk)
                if included:production.update(chunk)
        checksum.update(b'\0')
        if included:production.update(b'\0')
    return checksum.hexdigest(),production.hexdigest() if production is not None else None


def source_fingerprint():
    """Full audit identity: unchanged path/content framing and source inventory."""
    return _source_fingerprints()[0]


def build_input_identity(items, zig, auxiliary_hashes, interwiki_sha, expansion_timeout_ms, auxiliary_snapshots=None, downloads=None, reviewed_nonlexical=None, *, validate_auxiliary=False, native_roles=None, shard_pages=None):
    selected_shard_pages(shard_pages)
    if validate_auxiliary and auxiliary_hashes is not None:
        raise ValueError('Fresh auxiliary validation does not accept supplied hashes')
    executable=shutil.which(zig)
    if executable is None:raise ValueError('Zig compiler executable is unavailable')
    if native_roles is not None and not isinstance(native_roles, RetainedNativeToolRoles):
        raise ValueError('Invalid retained native role selection')
    runtime_scope = retained_runtime_scope(native_roles)
    provenance = native_roles.provenance() if native_roles is not None else None
    runtime_source = (retained_runtime_fingerprints(runtime_scope, provenance)
                      if runtime_scope is not None else None)
    source = runtime_source[0] if runtime_source is not None else source_fingerprint()
    compiler = Path(executable)
    if native_roles is None:
        compiler_digest = sha256_file(compiler)
    else:
        compiler_digest = native_roles.bind_input(compiler.resolve(strict=True))['sha256']
        if compiler_digest != native_roles.zig_sha256:
            raise ValueError('Selected compiler differs from retained native roles')
    identity=dict(version=1, source=source,
                files=sorted([[i['wiki'],i['date'],i['name'],i['size'],i['sha1']] for i in items]),
                zig_sha256=compiler_digest,
                auxiliary_snapshot_sha256=auxiliary_hashes or {},
                interwiki_map_sha256=interwiki_sha, expansion_timeout_ms=expansion_timeout_ms)
    if selected_shard_pages(shard_pages) != SHARD_PAGES:
        identity['shard_pages']=selected_shard_pages(shard_pages)
    if _PYTHON_TOOLING is not None:
        identity['python_tooling']=(runtime_source[2] if runtime_source is not None
                                    else _PYTHON_TOOLING.require_unchanged())
    if native_roles is not None:
        identity['native_tool_roles']=provenance
    if runtime_scope is not None:
        identity['retained_runtime_source']=runtime_scope
    if validate_auxiliary:
        # Source/toolchain hashing above may take time. Validate current auxiliary
        # bytes afterwards, then derive both identities within this same boundary.
        hashes,captures=_validated_auxiliary_state(auxiliary_snapshots,
            items[0]['wiki'] if items else None,items[0]['date'] if items else None)
        identity['auxiliary_snapshot_sha256']=hashes
        manifests,artifacts=_project_auxiliary_capture_identities(captures)
    else:
        manifests,artifacts=auxiliary_capture_identities(auxiliary_snapshots,
            items[0]['wiki'] if items else None,items[0]['date'] if items else None)
    if manifests:
        identity['auxiliary_capture_sha256']=manifests
        identity['auxiliary_capture_artifact_sha256']=artifacts
    from prepare_page_redirects import source_identity
    redirects=source_identity(items, downloads if downloads is not None else PROJECT/'data/dumps') if items else None
    if redirects is not None:identity['derived_page_redirects']=redirects
    if reviewed_nonlexical is not None:identity['reviewed_nonlexical_source_review_sha256']=reviewed_nonlexical['sha256']
    return identity


def require_build_identity(recorded, expected):
    if recorded!=expected:
        raise ValueError('Build inputs or compiler changed; rebuild in a new output directory (existing output preserved)')


def persist_build_identity(staging, identity):
    if identity is None:return
    require_build_source(identity)
    path=staging/BUILD_IDENTITY_NAME
    temporary=path.with_suffix('.part')
    record = publication_build_identity(staging, identity, create=True)
    temporary.write_text(build_envelope_text(record))
    os.replace(temporary,path)


@contextmanager
def _remove_partial_stage_on_error(*paths):
    try:
        yield
    except BaseException:
        for path in paths:
            try: unlink_artifact(path, missing_ok=True)
            except OSError: pass
        raise


STAGE_TARGET_BYTES=256*1024
STAGE_MAX_MEMBER_BYTES=64*1024*1024
STAGE_PARALLEL_MAX_BYTES=8*1024*1024
STAGE_PARALLEL_PART_WORKERS=4
STAGE_PART_QUEUE_BYTES=512*1024*1024


def _stage_seekable_dump_serial(items, downloads, scratch, metadata=None):
    """Repack full-namespace dumps into bounded, page-aligned Zstandard frames.

    The downloaded meta-current parts are not indexed by page. A whole part can
    expand past the native reader's 128 MiB member limit, so a part boundary is
    not a safe stream boundary. Keep XML only in bounded memory while writing
    compressed members and their real offsets to scratch.
    """
    if zstd is None:
        raise RuntimeError('Python 3.14 compression.zstd is required for staged Zstandard dumps')
    parts=[]
    for item in sorted(items,key=lambda x:x['name']):
        source=downloads/item['wiki']/item['date']/item['name']
        with source.open('rb',buffering=0) as f:
            if f.read(3)!=b'BZh': raise ValueError(f'Expected bzip2 dump part: {source}')
        parts.append(source)
    if not parts: raise ValueError('No dump parts')
    dump=scratch/'pages.xml.zst'
    index=scratch/'pages-index.txt.bz2'
    target_bytes=STAGE_TARGET_BYTES
    max_member_bytes=STAGE_MAX_MEMBER_BYTES  # Strictly below the native reader's 128 MiB cap.
    open_tag=b'<page>'
    close_tag=b'</page>'
    started=time.monotonic()
    pages=members=xml_bytes=0
    dump_hash=hashlib.sha256()
    pending=bytearray()
    batch=bytearray()
    # Four ordinary members may compress concurrently. Large pages take the
    # original synchronous path after draining the queue, preserving order.
    max_parallel_bytes=STAGE_PARALLEL_MAX_BYTES
    max_queued_batches=4
    with _remove_partial_stage_on_error(dump,index), \
         dump.open('wb',buffering=0) as out, bz2.open(index,'wb',compresslevel=1) as offsets, \
         concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        queued=deque()

        def write_member(member, raw_len):
            nonlocal members
            info=zstd.get_frame_info(member)
            if info.decompressed_size!=raw_len or zstd.get_frame_size(member)!=len(member):
                raise ValueError('Staged Zstandard member is not one known-size frame')
            offsets.write(f'{out.tell()}:{members+1}:member{members}\n'.encode())
            if out.write(member)!=len(member): raise OSError('Short staged dump write')
            dump_hash.update(member)
            members+=1

        def finish_oldest():
            future,raw_len=queued.popleft()
            write_member(future.result(),raw_len)

        def flush():
            nonlocal batch
            if not batch: return
            if len(batch)>max_parallel_bytes:
                while queued: finish_oldest()
                write_member(zstd.compress(batch,level=1),len(batch))
                batch.clear()
                return
            if len(queued)==max_queued_batches: finish_oldest()
            # The compressor owns this buffer until its future completes.
            raw,batch=batch,bytearray()
            queued.append((pool.submit(zstd.compress,raw,level=1),len(raw)))

        for source in parts:
            with bz2.open(source,'rb') as inp:
                while chunk:=inp.read(1024*1024):
                    xml_bytes+=len(chunk)
                    # Only the final partial closing tag can match across reads.
                    search_from = max(0, len(pending) - len(close_tag) + 1)
                    pending.extend(chunk)
                    consumed=0
                    while (end:=pending.find(close_tag,search_from))>=0:
                        start=pending.find(open_tag,consumed)
                        if start<0 or start>end:
                            raise ValueError(f'Unexpected XML page close: {source}')
                        cut=end+len(close_tag)
                        page_bytes=cut-consumed
                        if page_bytes>max_member_bytes:
                            raise ValueError(f'XML page exceeds bounded Zstandard member: {source}')
                        if len(batch)+page_bytes>max_member_bytes: flush()
                        batch.extend(memoryview(pending)[consumed:cut])
                        consumed=cut
                        search_from=cut
                        pages+=1
                        if len(batch)>=target_bytes: flush()
                    # Move the unfinished suffix once per read, rather than once per page.
                    del pending[:consumed]
                    if len(pending)>max_member_bytes:
                        raise ValueError(f'Unterminated or oversized XML page: {source}')
            # A split archive part may continue an XML page in the next part.
        if b'<page>' in pending:
            raise ValueError('Truncated XML page at end of dump')
        if len(batch)+len(pending)>max_member_bytes: flush()
        batch.extend(pending)
        flush()
        while queued: finish_oldest()
        if members==0:
            write_member(zstd.compress(b'',level=1),0)
    if metadata is not None:
        metadata.update({'source_pages':pages,'dump_codec':'zstd','dump_stream_kind':'multistream-zstd','dump_size':dump.stat().st_size,'dump_sha256':dump_hash.hexdigest(),
                         'index_size':index.stat().st_size,'index_sha256':sha256_file(index)})
    print(f'Staged Zstandard dump: pages={pages} members={members} xml_bytes={xml_bytes} compressed_bytes={dump.stat().st_size} seconds={time.monotonic()-started:.1f}',flush=True)
    return dump


class _SplitPageAcrossParts(Exception):
    pass


class _CancelledParallelStage(Exception):
    pass


class _PartFrameQueue:
    def __init__(self, cancelled, capacity):
        self.items=deque()
        self.bytes=0
        self.capacity=capacity
        self.cancelled=cancelled
        self.condition=threading.Condition()

    def put_frame(self, frame):
        with self.condition:
            while self.bytes+len(frame)>self.capacity and not self.cancelled.is_set():
                self.condition.wait()
            if self.cancelled.is_set(): raise _CancelledParallelStage()
            self.items.append(frame)
            self.bytes+=len(frame)
            self.condition.notify_all()

    def put_control(self, value):
        with self.condition:
            self.items.append(value)
            self.condition.notify_all()

    def get(self):
        with self.condition:
            while not self.items and not self.cancelled.is_set():
                self.condition.wait()
            if not self.items: raise _CancelledParallelStage()
            item=self.items.popleft()
            if isinstance(item,bytes): self.bytes-=len(item)
            self.condition.notify_all()
            return item

    def wake(self):
        with self.condition: self.condition.notify_all()


def _stage_seekable_dump_parallel(items, downloads, scratch, metadata=None):
    """Decode independent bzip2 parts concurrently into bounded frame queues.

    At most four part queues can hold frames, each capped at 512 MiB. The
    writer drains the current queue while its producer runs and preserves the
    original part order. No uncompressed or compressed intermediate reaches
    disk. Split XML pages use the existing serial framer instead.
    """
    if zstd is None:
        raise RuntimeError('Python 3.14 compression.zstd is required for staged Zstandard dumps')
    parts=[]
    for item in sorted(items,key=lambda x:x['name']):
        source=downloads/item['wiki']/item['date']/item['name']
        with source.open('rb',buffering=0) as stream:
            if stream.read(3)!=b'BZh': raise ValueError(f'Expected bzip2 dump part: {source}')
        parts.append(source)
    if len(parts)<2: return _stage_seekable_dump_serial(items,downloads,scratch,metadata)
    started=time.monotonic()
    dump=scratch/'pages.xml.zst'
    index=scratch/'pages-index.txt.bz2'
    open_tag=b'<page>'
    close_tag=b'</page>'
    cancelled=threading.Event()
    queues=[_PartFrameQueue(cancelled,STAGE_PART_QUEUE_BYTES) for _ in parts]

    def stage_part(source,output):
        try:
            if cancelled.is_set(): return
            pending=bytearray()
            batch=bytearray()
            pages=xml_bytes=0
            def flush():
                if not batch: return
                frame=zstd.compress(batch,level=1)
                info=zstd.get_frame_info(frame)
                if info.decompressed_size!=len(batch) or zstd.get_frame_size(frame)!=len(frame):
                    raise ValueError('Staged Zstandard member is not one known-size frame')
                batch.clear()
                output.put_frame(frame)

            with bz2.open(source,'rb') as inp:
                while chunk:=inp.read(1024*1024):
                    xml_bytes+=len(chunk)
                    # Only the final partial closing tag can match across reads.
                    search_from = max(0, len(pending) - len(close_tag) + 1)
                    pending.extend(chunk)
                    consumed=0
                    while (end:=pending.find(close_tag,search_from))>=0:
                        start=pending.find(open_tag,consumed)
                        if start<0 or start>end: raise _SplitPageAcrossParts(source)
                        cut=end+len(close_tag)
                        page_bytes=cut-consumed
                        if page_bytes>STAGE_MAX_MEMBER_BYTES:
                            raise ValueError(f'XML page exceeds bounded Zstandard member: {source}')
                        if len(batch)+page_bytes>STAGE_MAX_MEMBER_BYTES: flush()
                        batch.extend(memoryview(pending)[consumed:cut])
                        consumed=cut
                        search_from=cut
                        pages+=1
                        if len(batch)>=STAGE_TARGET_BYTES: flush()
                    del pending[:consumed]
                    if len(pending)>STAGE_MAX_MEMBER_BYTES:
                        raise ValueError(f'Unterminated or oversized XML page: {source}')
            if b'<page>' in pending or any(pending.endswith(open_tag[:n]) for n in range(1,len(open_tag))):
                raise _SplitPageAcrossParts(source)
            if len(batch)+len(pending)>STAGE_MAX_MEMBER_BYTES: flush()
            batch.extend(pending)
            flush()
            output.put_control((pages,xml_bytes))
        except BaseException as exc:
            output.put_control(exc)

    try:
        with (concurrent.futures.ThreadPoolExecutor(max_workers=STAGE_PARALLEL_PART_WORKERS) as pool,
              _remove_partial_stage_on_error(dump,index),
              dump.open('wb',buffering=0) as out,
              bz2.open(index,'wb',compresslevel=1) as offsets_out):
            members=pages=xml_bytes=0
            dump_hash=hashlib.sha256()
            futures=[]
            try:
                for i in range(min(STAGE_PARALLEL_PART_WORKERS,len(parts))):
                    futures.append(pool.submit(stage_part,parts[i],queues[i]))
                for part_index,output in enumerate(queues):
                    while True:
                        item=output.get()
                        if isinstance(item,bytes):
                            offsets_out.write(f'{out.tell()}:{members+1}:member{members}\n'.encode())
                            if out.write(item)!=len(item): raise OSError('Short staged dump write')
                            dump_hash.update(item)
                            members+=1
                        elif isinstance(item,BaseException):
                            raise item
                        else:
                            part_pages,part_xml_bytes=item
                            pages+=part_pages
                            xml_bytes+=part_xml_bytes
                            break
                    next_index=part_index+STAGE_PARALLEL_PART_WORKERS
                    if next_index<len(parts):
                        futures.append(pool.submit(stage_part,parts[next_index],queues[next_index]))
                for future in futures: future.result()
                if members==0:
                    frame=zstd.compress(b'',level=1)
                    if zstd.get_frame_info(frame).decompressed_size!=0 or zstd.get_frame_size(frame)!=len(frame):
                        raise ValueError('Empty Zstandard frame lacks known size')
                    offsets_out.write(b'0:1:member0\n')
                    if out.write(frame)!=len(frame): raise OSError('Short staged dump write')
                    dump_hash.update(frame)
                    members=1
            except BaseException:
                cancelled.set()
                for output in queues: output.wake()
                for future in futures: future.cancel()
                raise
        if metadata is not None:
            metadata.update({'source_pages':pages,'dump_codec':'zstd','dump_stream_kind':'multistream-zstd',
                             'dump_size':dump.stat().st_size,'dump_sha256':dump_hash.hexdigest(),
                             'index_size':index.stat().st_size,'index_sha256':sha256_file(index)})
        print(f'Staged parallel Zstandard dump: pages={pages} members={members} xml_bytes={xml_bytes} compressed_bytes={dump.stat().st_size} seconds={time.monotonic()-started:.1f}',flush=True)
        return dump
    except _SplitPageAcrossParts:
        unlink_artifact(dump, missing_ok=True)
        unlink_artifact(index, missing_ok=True)
        print('XML page crosses archive part boundary; using serial stage',flush=True)
        return _stage_seekable_dump_serial(items,downloads,scratch,metadata)


def _stage_seekable_dump(items, downloads, scratch, metadata=None):
    return _stage_seekable_dump_parallel(items,downloads,scratch,metadata)


def phase_identity(items):
    first=items[0] if items else None
    if isinstance(first,dict):
        return first.get('wiki','unknown'),first.get('date','unknown')
    return 'unknown','unknown'


def stage_seekable_dump(items, downloads, scratch, metadata=None):
    edition,date=phase_identity(items)
    with build_phase(edition,date,'repack',parts=len(items)):
        return _stage_seekable_dump(items,downloads,scratch,metadata)


def count_page_index_rows(path):
    return inspect_page_index(path)['rows']


def index_identity(stat):
    return dict(device_major=os.major(stat.st_dev),device_minor=os.minor(stat.st_dev),inode=stat.st_ino,size=stat.st_size,mtime_ns=stat.st_mtime_ns)


def inspect_page_index(path, shard_pages=None):
    interval=selected_shard_pages(shard_pages)
    count=offset=0
    offsets={}
    digest=hashlib.sha256()
    with path.open('rb') as source:
        identity=index_identity(os.fstat(source.fileno()))
        while True:
            line=source.readline(MAX_PAGE_INDEX_LINE_BYTES+1)
            if not line: break
            if len(line)>MAX_PAGE_INDEX_LINE_BYTES:
                raise ValueError('Page index line exceeds size limit')
            digest.update(line)
            if line.rstrip(b'\n') and not line.startswith(b'#'):
                if count % interval == 0: offsets[count]=0 if count==0 else offset
                count+=1
            offset+=len(line)
        if index_identity(os.fstat(source.fileno()))!=identity:
            raise ValueError('Page index changed during inspection')
    if index_identity(path.stat())!=identity:
        raise ValueError('Page index replaced during inspection')
    return dict(rows=count,sha256=digest.hexdigest(),identity=identity,offsets=offsets)


def validate_page_coverage(root, start=0, limit=None, expected=None, offset=0, source_pages=None, require_total=False):
    try:
        with (root/'page-coverage.json').open('rb') as source:
            data=source.read(MAX_PAGE_COVERAGE_BYTES+1)
        if len(data)>MAX_PAGE_COVERAGE_BYTES:
            raise ValueError('Page coverage exceeds size limit')
        record=json.loads(data)
    except (OSError,ValueError) as error:
        raise ValueError(f'Missing or invalid page coverage: {root}') from error
    if not isinstance(record,dict) or type(record.get('version')) is not int or record['version']!=1:
        raise ValueError(f'Invalid page coverage version: {root}')
    required={'version','start_page','requested_limit','pages_seen','index_byte_offset','page_index_identity'}
    if not required.issubset(record):
        raise ValueError(f'Missing required page coverage fields: {root}')
    for key in ('start_page','pages_seen','index_byte_offset'):
        if type(record.get(key)) is not int or record[key]<0:
            raise ValueError(f'Invalid page coverage {key}: {root}')
    identity=record.get('page_index_identity')
    if not isinstance(identity,dict) or any(type(identity.get(k)) is not int for k in ('device_major','device_minor','inode','size','mtime_ns')):
        raise ValueError(f'Invalid page index identity: {root}')
    requested=record.get('requested_limit')
    if requested is not None and (type(requested) is not int or requested<0):
        raise ValueError(f'Invalid requested page limit: {root}')
    if record['start_page']!=start or requested!=limit or record['index_byte_offset']!=offset:
        raise ValueError(f'Page selection mismatch: {root}')
    count=limit if limit is not None else (expected['rows'] if expected is not None else source_pages)
    if count is not None and record['pages_seen']!=count:
        raise ValueError(f'Incomplete page coverage: {root}')
    if expected is not None and identity!=expected['identity']:
        raise ValueError(f'Page index identity mismatch: {root}')
    if require_total:
        total=record.get('expected_input_pages')
        if type(total) is not int or total<0 or record['pages_seen']!=total:
            raise ValueError(f'Unverified total page coverage: {root}')
        if 'page_index_rows' in record and (type(record['page_index_rows']) is not int or record['page_index_rows']!=total):
            raise ValueError(f'Inconsistent index page total: {root}')
    return record


def require_index_identity(path, expected):
    if index_identity(path.stat())!=expected['identity']:
        raise ValueError('Page index changed between shards')


def cleanup_dead_private_shards(shards_root):
    """Remove only a private shard whose exact native writer PID is gone.

    The edition lock excludes another controller, but subprocesses do not hold
    it. A detached native builder can survive its controller, so lock ownership
    alone is never evidence that its private output is inactive.
    """
    for partial in shards_root.iterdir():
        matched=re.fullmatch(r'\.[0-9]{8}\.part-([0-9]+)',partial.name)
        if not matched: continue
        if partial.is_symlink() or not partial.is_dir():
            raise ValueError(f'Unsafe partial shard: {partial}')
        pid=int(matched.group(1))
        try:
            with open(f'/proc/{pid}/stat','rb') as process:
                process.read(1)
        except FileNotFoundError:
            pass
        except OSError as error:
            raise ValueError(f'Cannot establish private shard owner death: {partial}') from error
        else:
            raise ValueError(f'Native builder PID still exists; preserve partial shard: {partial}')
        remove_artifact_tree(partial)


def shard_state(items, registry, now_unix=None, interwiki_snapshot=None, auxiliary_snapshots=None, reviewed_nonlexical=None, *, build_identity=None, shard_pages=None):
    interval=selected_shard_pages(shard_pages)
    if build_identity is not None and 'retained_runtime_source' in build_identity:
        source, production_source = require_build_source(build_identity)
    else:
        source,production_source=_source_fingerprints(include_production=True)
    state={
        'version':SHARD_STATE_VERSION,
        'edition':items[0]['wiki'],
        'date':items[0]['date'],
        'files':[[item['name'],item['size'],item['sha1']] for item in sorted(items,key=lambda x:x['name'])],
        'registry_sha256':sha256_file(registry),
        'source':source,
        'production_source':production_source,
        'shard_pages':interval,
    }
    if now_unix is not None: state['now_unix']=now_unix
    if reviewed_nonlexical is not None:state['reviewed_nonlexical_source_review_sha256']=reviewed_nonlexical['sha256']
    if interwiki_snapshot is not None:
        state['interwiki_map_sha256']=sha256_file(interwiki_snapshot)
    if auxiliary_snapshots:
        hashes,captures=_validated_auxiliary_state(auxiliary_snapshots,items[0]['wiki'],items[0]['date'])
        state['auxiliary_snapshot_sha256']=hashes
        manifests,artifacts=_project_auxiliary_capture_identities(captures)
        if manifests:
            state['auxiliary_capture_sha256']=manifests
            state['auxiliary_capture_artifact_sha256']=artifacts
    return state


def dump_input_fingerprint(items):
    """The repack depends on XML input bytes and its staging format only."""
    if not items: raise ValueError('No dump parts')
    files=[]
    for item in sorted(items,key=lambda x:x['name']):
        files.append([item['wiki'],item['date'],item['name'],item['size'],item['sha1']])
    state={'version':DUMP_STAGING_VERSION,'files':files}
    return hashlib.sha256(json.dumps(state,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def validate_now_unix(value):
    if value is not None and (type(value) is not int or not 0 < value <= (1 << 63) - 1):
        raise ValueError('Build time must be a positive signed 64-bit Unix timestamp')
    return value


RAW_SHARD_OWNER = '.wikidict-raw-shards.json'


def external_raw_shards(workspace, path, create=False):
    """Authenticate a private raw-shard directory before using or deleting it."""
    raw=artifact_path(path)
    if not raw.is_absolute() or raw.resolve()!=raw or raw.is_symlink():
        raise ValueError(f'Unsafe external raw shard path: {raw}')
    work=workspace.resolve()
    protected=[work]
    if work.name.endswith('.shards'):
        date=work.name[:-len('.shards')]
        protected.extend((work.with_name(date),work.with_name(date+'.building')))
    if any(raw.is_relative_to(p) or p.is_relative_to(raw) for p in protected):
        raise ValueError(f'External raw shards overlap build paths: {raw}')
    if any((parent/RAW_SHARD_OWNER).exists() or (parent/RAW_SHARD_OWNER).is_symlink()
           for parent in raw.parents):
        raise ValueError(f'External raw shards nested inside another owner: {raw}')
    owner={'version':1,'workspace':str(work),'raw_shards':str(raw)}
    if not raw.exists():
        if not create: return raw
        raw.mkdir(parents=True)
    if not raw.is_dir(): raise ValueError(f'Unsafe external raw shard path: {raw}')
    marker=raw/RAW_SHARD_OWNER
    if marker.is_symlink(): raise ValueError(f'Unsafe raw shard owner marker: {marker}')
    if not marker.exists():
        if not create or any(raw.iterdir()):
            raise ValueError(f'Unowned external raw shard directory: {raw}')
        with marker.open('x') as out: out.write(json.dumps(owner,sort_keys=True)+'\n')
    if not marker.is_file() or read_small_json(marker)!=owner:
        raise ValueError(f'External raw shard owner differs: {raw}')
    return raw


def cleanup_shard_workspace(workspace):
    """Remove only the external shards recorded by this workspace."""
    artifact_path(workspace)
    if workspace.is_symlink() or (workspace.exists() and not workspace.is_dir()):
        raise ValueError(f'Unsafe shard workspace: {workspace}')
    if not workspace.exists(): return
    state_path=workspace/'state.json'
    if state_path.is_symlink(): raise ValueError(f'Unsafe shard state: {state_path}')
    state=read_build_envelope(state_path) if state_path.is_file() else {}
    if isinstance(state,dict) and state.get('raw_shards_path') is not None:
        raw=external_raw_shards(workspace,state['raw_shards_path'])
        if raw.exists():
            cleanup_dead_private_shards(raw)
            remove_artifact_tree(raw)
    remove_artifact_tree(workspace)


WIKIBASE_PROVIDER_ROLES = frozenset(('wikibase-entities', 'wikibase-entity-terms'))


def wikibase_provider_only_change(before, after):
    """Only paired captured Provider identities may differ; code/input keys stay exact."""
    if not isinstance(before, dict) or not isinstance(after, dict):
        return False
    values = []
    for source in (before, after):
        value = json.loads(json.dumps(source))
        value.pop('native_generation', None)
        for field in ('auxiliary_snapshot_sha256', 'auxiliary_capture_sha256',
                      'auxiliary_capture_artifact_sha256'):
            table = value.get(field)
            if (not isinstance(table, dict) or not WIKIBASE_PROVIDER_ROLES <= set(table) or
                    any(not isinstance(table[name], str) or not re.fullmatch('[0-9a-f]{64}', table[name])
                        for name in WIKIBASE_PROVIDER_ROLES)):
                return False
            for name in WIKIBASE_PROVIDER_ROLES:
                del table[name]
        values.append(value)
    return before != after and values[0] == values[1]


def bind_native_generation(workspace, dump, build_identity, *, updating=False):
    """Bind an actually sealed ordinary generation, never infer an old native origin."""
    import extraction_cache as cache
    root = workspace / 'expander' / '.bundle-expander'
    marker = root / cache.COMPLETED_EXPANDER
    digest = sha256_file(marker)
    validation = {'provider_update': True} if updating else {}
    if cache.frozen_runtime_context(root, dump, digest, **validation) is None:
        raise ValueError('Ordinary native generation did not produce its requested seal')
    state_path = workspace / 'state.json'
    state = read_build_envelope(state_path)
    state['native_generation'] = dict(seal_sha256=digest, dump=str(dump),
                                    build_inputs=json.loads(json.dumps(build_identity)))
    # The existing state publication is the last authority before readiness.
    temporary = state_path.with_suffix('.part')
    if os.path.lexists(temporary):
        raise ValueError('Unexpected native generation state transaction')
    try:
        with temporary.open('x') as output:
            output.write(build_envelope_text(state))
        os.replace(temporary, state_path)
    finally:
        temporary.unlink(missing_ok=True)
    if updating:
        if cache.frozen_runtime_context(root, dump, digest, provider_update=True) is None:
            raise ValueError('Updated ordinary Provider generation is incomplete')
        if (root / '.incomplete').read_bytes() != cache.PROVIDER_UPDATE_MARKER:
            raise ValueError('Provider update readiness marker changed')
        (root / '.incomplete').unlink()
    return digest


def shard_cache_identity(state):
    """Compare v3 production inputs while retaining its original audit source."""
    comparable={k:v for k,v in state.items() if k not in ('now_unix','native_generation')}
    if state.get('version')==SHARD_STATE_VERSION:
        for name in ('source','production_source'):
            value=state.get(name)
            if not isinstance(value,str) or re.fullmatch(r'[0-9a-f]{64}',value) is None:
                raise ValueError('Invalid shard source identity: '+name)
        comparable.pop('source')
    return comparable


def sealed_recovery_adopted(workspace, proof, build_identity):
    state_path = workspace / 'state.json'
    original = prepared_metadata(proof['original_state'])
    expected = dict(proof['current_state'], now_unix=original['now_unix'])
    expected['native_generation'] = dict(seal_sha256=proof['seal']['sha256'], dump=proof['dump'],
                                         build_inputs=proof['current_build_identity'])
    return (proof['current_build_identity'] == build_identity and state_path.is_file()
            and not state_path.is_symlink() and read_build_envelope(state_path) == expected)


def recover_sealed_workspace(workspace, expected, now_unix, build_identity, dump, reference, native_roles):
    """Adopt an explicitly selected pre-blob generation before ordinary reset."""
    import extraction_cache as cache
    proof = prepared_metadata(reference)
    state_path = workspace / 'state.json'
    original = prepared_metadata(proof['original_state'])
    closed = prepared_metadata(proof['original_closure'])
    if not all(closed.get(name) is True for name in ('physical_closure', 'cleanup_complete', 'source_guard_after')):
        raise ValueError('Sealed recovery original attempt is not closed')
    validate_now_unix(original.get('now_unix'))
    if (Path(proof['original_state']['path']) == state_path or
            read_build_envelope(state_path) != original or proof['workspace'] != str(workspace) or
            proof['current_state'] != expected or proof['current_build_identity'] != build_identity or
            proof['dump'] != str(dump) or now_unix not in (None, original.get('now_unix'))):
        raise ValueError('Sealed recovery differs from selected state, inputs or source transition')
    def inputs(value):
        return {k:v for k,v in value.items() if k not in ('source', 'production_source', 'now_unix', 'native_generation')}
    if inputs(original) != inputs(expected):
        raise ValueError('Sealed recovery changed ordinary workspace inputs')
    old_identity = proof['original_build_identity']
    if old_identity.get('source') != original.get('source'):
        raise ValueError('Sealed recovery original source differs')
    def build_inputs(value):
        return {k:v for k,v in value.items() if k not in ('source', 'python_tooling', 'native_tool_roles')}
    if build_inputs(old_identity) != build_inputs(build_identity):
        raise ValueError('Sealed recovery changed selected input identities')
    # Source/tooling changes are explicit in the selected proof. Native artifacts
    # and compiler dependencies must still be the actual original qualified roles.
    def compiled_roles(value):
        roles = json.loads(json.dumps(value.get('native_tool_roles')))
        if not isinstance(roles, dict):raise ValueError('Sealed recovery lacks qualified native roles')
        for row in roles.values():
            row.get('dependencies', {}).pop('runtime_source:tools/extraction_cache.py', None)
            row.get('dependencies', {}).pop('extraction_helper', None)
        return roles
    if compiled_roles(old_identity) != compiled_roles(build_identity):
        raise ValueError('Sealed recovery changed qualified native tools')
    native_roles.require_unchanged()
    if native_roles.provenance() != build_identity['native_tool_roles']:
        raise ValueError('Sealed recovery native selection differs')
    # No accepted, partial or published blob output can cross this source boundary.
    for path in (workspace / 'shards', workspace.parent / expected['date'],
                 workspace.parent / (expected['date'] + '.building')):
        if os.path.lexists(path):
            raise ValueError('Sealed recovery requires pre-blob output state')
    raw = expected.get('raw_shards_path')
    if raw is not None:
        raw = external_raw_shards(workspace, raw)
        if any(path.name != RAW_SHARD_OWNER for path in raw.iterdir()):raise ValueError('Sealed recovery has partial raw output')
    root = workspace / 'expander' / '.bundle-expander'
    seal = prepared_metadata(proof['seal'])
    if (Path(proof['seal']['path']) != root / cache.COMPLETED_EXPANDER or
            seal['origin_graph'] != proof['origin_graph']):
        raise ValueError('Sealed recovery selected another compiled origin')
    temporary = state_path.with_suffix('.part')
    if os.path.lexists(temporary):raise ValueError('Unexpected sealed recovery state transaction')
    # The retained bundle role, already compared with its original qualified
    # provenance above, owns the source root used by an ordinary "." graph.
    project_root = old_identity['native_tool_roles'].get('dict-bundle-build', {}).get('source_root')
    cache.finalize_sealed_expander(root, Path(dump), proof['seal']['sha256'], proof['origin_graph'],
                                   helper_transition=proof.get('helper_transition'), project_root=project_root)
    native_roles.require_unchanged()
    prepared_metadata(reference); prepared_metadata(proof['original_state'])
    state = dict(expected, now_unix=original['now_unix'])
    state['native_generation'] = dict(seal_sha256=proof['seal']['sha256'], dump=str(dump),
                                      build_inputs=json.loads(json.dumps(build_identity)))
    temporary = state_path.with_suffix('.part')
    if os.path.lexists(temporary):raise ValueError('Unexpected sealed recovery state transaction')
    created=False
    try:
        with temporary.open('x') as stream:
            created=True
            stream.write(build_envelope_text(state))
        os.replace(temporary, state_path)
    finally:
        if created:temporary.unlink(missing_ok=True)
    return state['now_unix']


WRITER_FIGURE_ROLES = frozenset((*FIGURE_SNAPSHOT_FILES, 'file-metadata'))
WRITER_OBSERVATION_ROLES = frozenset(('figure-sizing', 'figure-sizing-raw'))


def writer_figure_worker_inputs(value, *, state=False):
    """Project only the inputs actually consumed by the sealed worker."""
    result = json.loads(json.dumps(value))
    ignored = ('source', 'production_source', 'now_unix', 'native_generation') if state else ('source', 'python_tooling', 'native_tool_roles', 'retained_runtime_source')
    for name in ignored:
        result.pop(name, None)
    for field, excluded in (('auxiliary_snapshot_sha256', WRITER_OBSERVATION_ROLES),
                            ('auxiliary_capture_sha256', WRITER_FIGURE_ROLES),
                            ('auxiliary_capture_artifact_sha256', WRITER_FIGURE_ROLES)):
        values = result.get(field)
        if not isinstance(values, dict) or not WRITER_FIGURE_ROLES <= set(values):
            raise ValueError('Writer Figure transition lacks the complete selected capture')
        if any(not isinstance(values[name], str) or re.fullmatch(r'[0-9a-f]{64}', values[name]) is None
               for name in WRITER_FIGURE_ROLES):
            raise ValueError('Writer Figure transition has an invalid capture identity')
        if field != 'auxiliary_snapshot_sha256' and len({values[name] for name in WRITER_FIGURE_ROLES}) != 1:
            raise ValueError('Writer Figure transition mixes capture generations')
        for name in excluded:
            values.pop(name)
    return result


def writer_figure_binding(workspace, expected, build_identity, dump, reference, native_roles):
    """Authenticate a selected observation change without changing worker origin."""
    import extraction_cache as cache
    proof = prepared_metadata(reference)
    original = prepared_metadata(proof['original_state'])
    closed = prepared_metadata(proof['original_closure'])
    if not all(closed.get(name) is True for name in ('physical_closure', 'cleanup_complete', 'source_guard_after')):
        raise ValueError('Writer Figure original attempt is not closed')
    configuration = prepared_metadata(proof['original_configuration'])
    result = prepared_metadata(proof['original_result'])
    evidence = closed.get('attempt_evidence', {}).get(proof['original_result']['path'], {})
    if (closed.get('configuration') != proof['original_configuration']
            or proof['original_result'] not in closed.get('attempts', [])
            or evidence.get('result') != proof['original_result']
            or evidence.get('physical_closure') is not True or evidence.get('source_guard_after') is not True
            or result.get('production_started') is not True or result.get('outcome') != 'failed'
            or type(result.get('exit_code')) is not int or result['exit_code'] == 0
            or result.get('edition') != original.get('edition')
            or configuration.get('date') != original.get('date')
            or configuration.get('source', {}).get('fingerprint') != original.get('source')
            or configuration.get('execution_root') != closed.get('execution_root')
            or configuration.get('output') != str(workspace.parent.parent)
            or workspace != Path(configuration['output']) / original.get('edition', '') / (original.get('date', '') + '.shards')):
        raise ValueError('Writer Figure closure does not bind the selected failed workspace')
    from corpus_controller import bound_directory
    if bound_directory(closed['execution_root']['output'], 'Closed Writer Figure output') != workspace.parent.parent:
        raise ValueError('Writer Figure closed output root changed')
    raw = original.get('raw_shards_path')
    if raw is not None:
        raw_root = bound_directory(closed['execution_root']['raw'], 'Closed Writer Figure raw')
        if (configuration.get('raw_shard_root') != str(raw_root)
                or Path(raw) != raw_root / original['edition'] / (original['date'] + '.raw-shards')):
            raise ValueError('Writer Figure closed raw output root changed')
    state_path = workspace / 'state.json'
    if (Path(proof['original_state']['path']) == state_path or proof['workspace'] != str(workspace)
            or proof['dump'] != str(dump) or proof['current_state'] != expected
            or proof['current_build_identity'] != build_identity):
        raise ValueError('Writer Figure transition differs from selected state or inputs')
    validate_now_unix(original.get('now_unix'))
    binding = original.get('native_generation')
    if (not isinstance(binding, dict) or set(binding) != {'seal_sha256', 'dump', 'build_inputs'}
            or binding['dump'] != str(dump)):
        raise ValueError('Writer Figure transition requires an actual completed native generation')
    if writer_figure_worker_inputs(original, state=True) != writer_figure_worker_inputs(expected, state=True):
        raise ValueError('Writer Figure transition changed worker workspace inputs')
    previous = binding['build_inputs']
    original_roles = json.loads(json.dumps(configuration.get('retained_native_roles')))
    if isinstance(original_roles, dict) and 'dict-bundle-build' in original_roles:
        original_roles['dict-bundle-build'].pop('sealed_expander_recovery', None)
    if previous.get('source') != original.get('source') or original_roles != previous.get('native_tool_roles'):
        raise ValueError('Writer Figure original native origin differs from its failed configuration')
    selected = configuration.get('edition_options', {}).get(original['edition'], {})
    staged = selected.get('staged_input_root')
    if staged is None:
        staged_path = workspace / 'input'
    elif isinstance(staged, dict) and set(staged) == {'path', 'device', 'inode', 'uid', 'mode', 'completion'}:
        staged_path = bound_directory({key: value for key, value in staged.items() if key != 'completion'},
                                      'Closed Writer Figure staged input')
        if staged['completion'].get('path') != str(staged_path / '.complete.json'):
            raise ValueError('Writer Figure staged completion identifies another path')
        prepared_metadata(staged['completion'])
    else:
        raise ValueError('Writer Figure failed configuration has invalid staged input custody')
    if staged_path / 'pages.xml.zst' != Path(dump):
        raise ValueError('Writer Figure failed configuration selects another dump')
    if {name: row.get('sha256') for name, row in selected.get('auxiliary_snapshots', {}).items()} != original.get('auxiliary_snapshot_sha256'):
        raise ValueError('Writer Figure failed configuration selects another input tuple')
    if writer_figure_worker_inputs(previous) != writer_figure_worker_inputs(build_identity):
        raise ValueError('Writer Figure transition changed worker build inputs')
    old_roles = previous.get('native_tool_roles')
    new_roles = build_identity.get('native_tool_roles')
    if (not isinstance(old_roles, dict) or not isinstance(new_roles, dict)
            or set(old_roles) != set(new_roles) or 'dict-blob-build' not in old_roles
            or any(old_roles[name] != new_roles[name] for name in old_roles if name != 'dict-blob-build')):
        raise ValueError('Writer Figure transition changed another native role')
    native_roles.require_unchanged()
    if native_roles.provenance() != new_roles:
        raise ValueError('Writer Figure transition changed qualified roles')
    root = workspace / 'expander' / '.bundle-expander'
    if (Path(proof['seal']['path']) != root / cache.COMPLETED_EXPANDER
            or proof['seal']['sha256'] != binding['seal_sha256']):
        raise ValueError('Writer Figure transition selected another worker seal')
    prepared_metadata(proof['seal'])
    if cache.frozen_runtime_context(root, Path(dump), binding['seal_sha256']) is None:
        raise ValueError('Writer Figure transition worker is not frozen and ready')
    return proof, original, binding


def writer_figure_adopt_workspace(workspace, expected, now_unix, build_identity, dump, reference, native_roles):
    state_path = workspace / 'state.json'
    if state_path.is_symlink() or not state_path.is_file():
        raise ValueError('Unsafe Writer Figure workspace state')
    proof, original, binding = writer_figure_binding(workspace, expected, build_identity, dump, reference, native_roles)
    desired = dict(expected, now_unix=original['now_unix'])
    desired['native_generation'] = dict(binding, writer_figure_transition=reference)
    if now_unix not in (None, original['now_unix']):
        raise ValueError('Writer Figure transition changed build time')
    current = read_build_envelope(state_path)
    if current == desired:
        return current['now_unix']
    if current != original:
        raise ValueError('Writer Figure transition changed original workspace state')
    temporary = state_path.with_suffix('.part')
    if os.path.lexists(temporary):
        raise ValueError('Unexpected Writer Figure state transaction')
    published = workspace.with_name(expected['date'])
    staging = workspace.with_name(expected['date'] + '.building')
    if os.path.lexists(published) or (staging / VERIFIED_MARKER).exists():
        raise ValueError('Writer Figure transition refuses accepted or published output')
    shards = workspace / 'shards'
    if shards.exists():
        if shards.is_symlink() or not shards.is_dir():
            raise ValueError('Unsafe Writer Figure shard output')
        if any(child.name == VERIFIED_MARKER or child.name.endswith('.verified')
               or (child.is_dir() and (child / VERIFIED_MARKER).exists()) for child in shards.iterdir()):
            raise ValueError('Writer Figure transition refuses accepted shard output')
    candidates = [shards, staging, workspace / 'native-blob-tools' / 'bin' / 'dict-blob-build']
    raw = expected.get('raw_shards_path')
    if raw is not None:
        raw = external_raw_shards(workspace, raw)
        candidates.extend(child for child in raw.iterdir() if child.name != RAW_SHARD_OWNER)
    for path in candidates:
        if path.is_dir() and (shard_completion_present(path) or (path / VERIFIED_MARKER).exists()):
            raise ValueError('Writer Figure transition refuses completed output')
        if path == shards and path.is_dir():
            if any(child.is_dir() and shard_completion_present(child) for child in path.iterdir()):
                raise ValueError('Writer Figure transition refuses completed shard output')
    planned = [Path(value) for value in proof['retired_paths']]
    if (len(planned) != len(set(planned)) or any(not path.is_absolute() for path in planned)
            or any(path not in candidates and (raw is None or path.parent != raw or path.name == RAW_SHARD_OWNER)
                   for path in planned)):
        raise ValueError('Writer Figure transition has an invalid retirement inventory')
    archive = workspace.with_name(workspace.name + '.writer-figure-' + proof['original_state']['sha256'][:16])
    journal_path = archive / 'transition.json'
    def stamp(path):
        artifact_path(path)
        info = path.lstat()
        if info.st_uid != os.getuid() or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise ValueError('Unsafe Writer Figure retirement member')
        return [info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_size, info.st_mtime_ns]
    if os.path.lexists(archive):
        if archive.is_symlink() or not archive.is_dir() or archive.stat().st_uid != os.getuid():
            raise ValueError('Unsafe Writer Figure retirement directory')
        journal = read_small_json(journal_path)
        if journal.get('proof') != reference or journal.get('paths') != [str(path) for path in planned]:
            raise ValueError('Writer Figure retirement belongs to another transition')
    else:
        if {path for path in candidates if os.path.lexists(path)} != set(planned):
            raise ValueError('Writer Figure partial output inventory changed')
        rows = [stamp(path) for path in planned]
        if any(row[0] != workspace.stat().st_dev for row in rows):
            raise ValueError('Writer Figure retirement must remain on the workspace filesystem')
        archive.mkdir(mode=0o700)
        journal = dict(proof=reference, paths=[str(path) for path in planned], identities=rows)
        with journal_path.open('x') as stream:
            json.dump(journal, stream, sort_keys=True); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    if set(archive.iterdir()) - {journal_path, *(archive / str(index) for index in range(len(planned)))}:
        raise ValueError('Unexpected Writer Figure retirement member')
    # Each rename preserves the failed bytes. A stopped transition resumes only
    # from its exact original inode inventory, before publishing the new state.
    for index, path in enumerate(planned):
        destination = archive / str(index)
        if os.path.lexists(destination):
            if os.path.lexists(path) or stamp(destination) != journal['identities'][index]:
                raise ValueError('Writer Figure retired output changed')
        else:
            if stamp(path) != journal['identities'][index]:
                raise ValueError('Writer Figure output changed before retirement')
            os.rename(path, destination)
            for directory in (path.parent, archive):
                descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
                try: os.fsync(descriptor)
                finally: os.close(descriptor)
    if any(os.path.lexists(path) for path in candidates):
        raise ValueError('Writer Figure output appeared during transition')
    writer_figure_binding(workspace, expected, build_identity, dump, reference, native_roles)
    created = False
    try:
        with temporary.open('x') as stream:
            created = True
            stream.write(build_envelope_text(desired)); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, state_path)
        descriptor = os.open(workspace, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(descriptor)
        finally: os.close(descriptor)
    finally:
        if created: temporary.unlink(missing_ok=True)
    return desired['now_unix']


def retained_compilation_source(row, native_roles):
    """Join a closed guard to exact native bytes and recorded helper changes."""
    source = prepared_metadata(row['source'])
    if source.get('fingerprint', row['source']['sha256']) == row['producer_source']:
        return source
    keys = ('compiled_source_authority', 'compilation_recipe', 'actual_emission_result', 'qualification_closure')
    if any(not isinstance(row.get(key), dict) for key in keys):
        raise ValueError('Retained native compilation authority is missing')
    refs = [row[key] for key in keys]
    compiled, recipe, emitted, closed = [prepared_metadata(ref) for ref in refs]
    if (recipe.get('source_manifest') != row['source']
            or closed.get('source_manifest') != row['source']
            or recipe.get('native_compilation_source_manifest') != refs[0]
            or closed.get('native_compilation_source_manifest') != refs[0]
            or source.get('native_compilation_origin', refs[0]) != refs[0]
            or compiled.get('fingerprint', refs[0]['sha256']) != row['producer_source']
            or emitted.get('source_authority') != row['compilation_recipe']
            or closed.get('result') != row['actual_emission_result']
            or emitted.get('passed') is not True
            or closed.get('outcome') != 'PASSED-PHYSICALLY-SOURCE-CLOSED'
            or recipe.get('source_head') != source.get('head')):
        raise ValueError('Retained native compilation envelope differs')
    commands = recipe.get('commands', [])
    if (len(commands) != 1 or len(emitted.get('commands', [])) != 1
            or closed.get('commands') != emitted['commands']
            or commands[0].get('argv') != emitted['commands'][0].get('argv')
            or commands[0].get('cwd') != row['source_root']
            or emitted['commands'][0].get('cwd') != row['source_root']
            or emitted['commands'][0].get('returncode') != 0):
        raise ValueError('Retained native compilation command differs')
    argv = commands[0]['argv']
    if argv[:2] != [row['dependencies']['zig']['path'], 'build']:
        raise ValueError('Retained native compilation target differs')
    stop = next((i for i,value in enumerate(argv[2:], 2) if value.startswith('-')), len(argv))
    targets = argv[2:stop]
    if targets not in (['prepare-blob-tools'], ['prepare-captured-writer'], ['prepare-blob-tools', 'cli']):
        raise ValueError('Retained native compilation target differs')
    # These exact native-only targets do not execute the changed orchestration
    # helpers. No cache-report/Python invocation or unknown build option is admitted.
    required = {'-Doptimize=safe', '-Dtarget=x86_64-native', '-Dcpu=baseline',
                '-Dcaptured-source-fingerprint=' + row['producer_source']}
    arguments = argv[stop:]
    seen = set()
    index = 0
    while index < len(arguments):
        value = arguments[index]
        if value in ('--summary', '--search-prefix', '--cache-dir', '--global-cache-dir', '--prefix'):
            if value in seen or index + 1 >= len(arguments):
                raise ValueError('Retained native compilation option differs')
            seen.add(value)
            if value == '--summary' and arguments[index + 1] != 'all':
                raise ValueError('Retained native compilation summary differs')
            index += 2
        elif value in required or value == '-Dtest-optimize=safe' or re.fullmatch(r'-j[1-9][0-9]*', value):
            if value in seen:
                raise ValueError('Duplicate retained native compilation option')
            seen.add(value)
            index += 1
        else:
            raise ValueError('Unreviewed retained native compilation option')
    if not required <= seen:
        raise ValueError('Retained native compilation flags differ')
    def manifest(value):
        files, modes = value['files'], value['modes']
        if (set(files) != set(modes)
                or any(type(mode) is not int or not 0 <= mode <= 0o777 for mode in modes.values())):
            raise ValueError('Retained compilation source membership or modes differ')
        normalized = {}
        for name,descriptor in files.items():
            if (not isinstance(descriptor,dict)
                    or set(descriptor) not in ({'path', 'bytes', 'sha256'}, {'path', 'bytes', 'sha256', 'mode'})
                    or ('mode' in descriptor and descriptor['mode'] != modes[name])):
                raise ValueError('Retained compilation source mode differs')
            normalized[name] = {key: descriptor[key] for key in ('path', 'bytes', 'sha256')}
        return normalized, modes
    files, modes = manifest(compiled)
    final, final_modes = manifest(source)
    if set(files) != set(final) or modes != final_modes:
        raise ValueError('Retained compilation source membership or modes differ')
    bridge = source.get('helper_head_bridge', {}).get('application')
    if bridge is not None:
        applications = [bridge]
    else:
        applications = recipe.get('python_production_bridge')
        if applications != closed.get('python_production_bridge'):
            raise ValueError('Retained helper application authority differs')
        applications = applications if isinstance(applications, list) else [applications]
    if any(files[name] != final[name] for name in files):
        if not applications or any(not isinstance(ref, dict) for ref in applications):
            raise ValueError('Retained helper application authority is missing')
    elif applications == [None]:
        applications = []
    allowed = {
        'tools/build_wiktionaries.py', 'tools/test_build_wiktionaries.py',
        'tools/prepare_figure_metadata.py', 'tools/test_prepare_figure_files.py',
    }

    def authority(reference, *, relative=False):
        if not isinstance(reference, dict) or set(reference) not in (
                {'path', 'bytes', 'sha256'}, {'path', 'bytes', 'sha256', 'mode'}):
            raise ValueError('Invalid retained qualification descriptor')
        path = Path(reference['path'])
        if '..' in path.parts or path.as_posix() != reference['path']:
            raise ValueError('Unsafe retained qualification path')
        if not path.is_absolute():
            if not relative:
                raise ValueError('Relative retained qualification is not supported')
            path = Path(row['source_root']) / path
        selected = dict(reference, path=str(path))
        if 'mode' in selected and (type(selected['mode']) is not int or
                not 0 <= selected['mode'] <= 0o777 or stat.S_IMODE(path.stat().st_mode) != selected['mode']):
            raise ValueError('Retained qualification mode differs')
        return selected, prepared_metadata({key: selected[key] for key in ('path', 'bytes', 'sha256')})
    for reference in applications:
        application = prepared_metadata(reference)
        refs.append(reference)
        entries = application.get('rows', [])
        names = []
        if not entries:
            raise ValueError('Retained helper application has no source changes')
        # Preserve the qualifications supplied by older active receipts. Native
        # byte equality below never comes from a declared qualification boolean.
        qualified = None
        if 'qualification' in application:
            qualification_ref, qualification = authority(application['qualification'])
            owner_ref, owner = authority(qualification['owner_configuration'], relative=True)
            if (qualification.get('outcome') != 'PASSED-PHYSICALLY-SOURCE-CLOSED'
                    or any(qualification.get(key) is not True for key in ('source_after', 'source_lease_released', 'reaped'))
                    or qualification.get('errors') != 0 or qualification.get('failures') != 0
                    or not isinstance(qualification.get('tests_executed'), int) or qualification['tests_executed'] <= 0
                    or qualification.get('tests_passed') != qualification['tests_executed']):
                raise ValueError('Retained helper application lacks its actual qualification')
            refs.extend([qualification_ref, owner_ref])
            qualified = owner.get('source_refs', [])
        for entry in entries:
            name = entry.get('relative', entry.get('path'))
            before = entry['before']
            after = entry.get('actual_post', entry.get('after'))
            if name not in allowed or name in names or name not in files or not isinstance(after, dict):
                raise ValueError('Retained helper application changed an unreviewed source')
            names.append(name)
            path = str(Path(row['source_root']) / name)
            if (files[name]['path'] != path or final[name]['path'] != path or after.get('path') != path
                    or before.get('path', path) != path
                    or any(before.get(key) != files[name][key] for key in ('bytes', 'sha256'))
                    or before.get('mode') != modes[name] or after.get('mode') != modes[name]):
                raise ValueError('Retained helper application continuity differs')
            if qualified is not None:
                matches = [item for item in qualified
                           if all(item.get(key) == after.get(key) for key in ('bytes', 'sha256', 'mode'))]
                if len(matches) != 1:
                    raise ValueError('Retained helper application endpoints were not qualified')
                refs.append(matches[0])
            files[name] = {key: after[key] for key in ('path', 'bytes', 'sha256')}
    if files != final:
        raise ValueError('Retained native inputs or helper changes differ')
    for reference in [row['source'], *refs]:
        observed = native_roles.bind_input(Path(reference['path']))
        if any(observed[key] != reference[key] for key in ('path', 'bytes', 'sha256')):
            raise ValueError('Retained compilation authority custody differs')
        if 'mode' in reference and observed['mode'] != reference['mode']:
            raise ValueError('Retained compilation authority mode differs')
    return compiled


def validate_composite_source_inventory(plan, base, selected, auth_payload):
    """Join a logical compile inventory to the guarded base and exact payloads."""
    if 'source_guard_manifest' not in plan:
        if 'source_payload_files' in plan:
            raise ValueError('Composite source payloads lack their base guard')
        return
    payloads = plan.get('source_payload_files')
    if (plan['source_guard_manifest'] == plan['source_manifest']
            or not isinstance(base, dict) or not isinstance(selected, dict)
            or not isinstance(payloads, dict) or not payloads
            or set(selected) != set(base) | set(payloads)):
        raise ValueError('Composite source inventory or payload membership differs')
    if ('source_member_count' in plan and plan['source_member_count'] != len(selected)) or ('source_guard_member_count' in plan and plan['source_guard_member_count'] != len(base)):
        raise ValueError('Composite source member counts differ')
    required = ('build.zig','tools/blob_build.zig','src/encoder/root.zig','src/encoder/blob_root.zig')
    if not set(required) <= set(payloads):
        raise ValueError('Composite source lacks its actual selected module roots')
    commands = plan.get('commands')
    root = plan.get('source_root')
    if (not isinstance(commands,list) or len(commands) != 1 or not isinstance(commands[0],dict)
            or not isinstance(root,dict) or not isinstance(root.get('path'),str)):
        raise ValueError('Composite source lacks its actual normal build command')
    argv = commands[0].get('argv'); base_path = root['path']
    if (not isinstance(argv,list) or not all(isinstance(x,str) for x in argv) or len(argv) < 3
            or argv[1] != 'build' or commands[0].get('cwd') != base_path
            or not Path(base_path).is_absolute() or Path(base_path).as_posix() != base_path):
        raise ValueError('Composite source base differs from actual build cwd')
    stop = next((i for i,x in enumerate(argv[2:],2) if x.startswith('-')),len(argv))
    if argv[2:stop] not in (['prepare-blob-tools'],['prepare-captured-writer'],['prepare-blob-tools','cli'],['cli','ffi'],['prepare-captured-writer','cli','ffi'],['prepare-blob-verify'],['prepare-blob-tools','cli','ffi']):
        raise ValueError('Composite build selected another production target')
    if argv.count('--build-file') != 1 or argv.index('--build-file')+1 >= len(argv) or argv[argv.index('--build-file')+1] != payloads['build.zig']['path']:
        raise ValueError('Composite actual build file differs from its payload')
    expected = ['-Dqualified-source-base='+base_path,
        '-Dqualified-writer-root='+payloads['tools/blob_build.zig']['path'],
        '-Dqualified-encoder-root='+payloads['src/encoder/root.zig']['path'],
        '-Dqualified-blob-encoder-root='+payloads['src/encoder/blob_root.zig']['path']]
    if sorted(x for x in argv if x.startswith('-Dqualified-')) != sorted(expected):
        raise ValueError('Composite actual module roots differ from their payloads')
    required_flags = {'-Doptimize=safe','-Dtarget=x86_64-native','-Dcpu=baseline',
        '-Dcaptured-source-fingerprint='+plan['source_manifest']['sha256']}
    seen_flags = set(); index = stop
    while index < len(argv):
        value = argv[index]
        if value in ('--build-file','--summary','--search-prefix','--cache-dir','--global-cache-dir','--prefix'):
            if value in seen_flags or index+1 >= len(argv):
                raise ValueError('Duplicate or incomplete composite build option')
            if value == '--summary' and argv[index+1] != 'all':
                raise ValueError('Composite build summary differs')
            seen_flags.add(value); index += 2
        elif value in required_flags or value in expected or value == '-Dtest-optimize=safe' or (value.startswith('-j') and value[2:].isdigit() and int(value[2:]) > 0):
            if value in seen_flags:
                raise ValueError('Duplicate composite native build option')
            seen_flags.add(value); index += 1
        else:
            raise ValueError('Unreviewed composite native build option')
    if not required_flags | {'--summary','--prefix'} <= seen_flags:
        raise ValueError('Composite native build flags differ')
    paths = set()
    for name in selected:
        if not isinstance(name, str):
            raise ValueError('Unsafe composite source member')
        relative = Path(name)
        if (relative.is_absolute() or '..' in relative.parts
                or relative.as_posix() != name):
            raise ValueError('Unsafe composite source member')
        original, compiled = base.get(name), selected[name]
        if (not isinstance(compiled, dict) or set(compiled) != {'bytes', 'sha256', 'mode'}
                or (original is not None and (not isinstance(original, dict) or set(original) != set(compiled)))):
            raise ValueError('Composite source requires flat private inventories')
        if name not in payloads:
            if original != compiled:
                raise ValueError('Composite source changed outside its payload map')
            continue
        descriptor = payloads[name]
        if (not isinstance(descriptor, dict) or set(descriptor) != {'path', 'bytes', 'sha256', 'mode'}
                or any(descriptor[key] != compiled[key] for key in ('bytes', 'sha256', 'mode'))):
            raise ValueError('Composite source payload does not match compiled bytes')
        path = Path(descriptor['path'])
        if (not path.is_absolute() or '..' in path.parts or path.as_posix() != descriptor['path']
                or descriptor['path'] in paths):
            raise ValueError('Unsafe or duplicate composite source payload path')
        paths.add(descriptor['path'])
        if auth_payload is None:
            continue
        if any(p.is_symlink() for p in (path, *path.parents)):
            raise ValueError('Unsafe composite source payload path')
        before = path.lstat()
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.geteuid()
                or stat.S_IMODE(before.st_mode) != descriptor['mode']):
            raise ValueError('Composite source payload mode or ownership differs')
        auth_payload(descriptor)
        after = path.lstat()
        fields = ('st_dev','st_ino','st_mode','st_nlink','st_uid','st_gid','st_size','st_mtime_ns','st_ctime_ns')
        if any(getattr(before,key) != getattr(after,key) for key in fields):
            raise ValueError('Composite source payload changed during authorization')


def initial_sealed_matched_triple(row, native_roles, recipe, closed, source, compiled, *, target):
    """Authenticate the one normal Writer/CLI/Verify install family as a unit."""
    roles = {'writer': ('prepare-captured-writer', 'dict-blob-build', 'tools/blob_build.zig'),
             'cli': ('cli', 'wikidict', 'src/frontend/main.zig'),
             'verify': ('prepare-blob-verify', 'dict-blob-verify', 'tools/blob_verify.zig')}
    selected = [key for key, (step, name, _) in roles.items()
                if step == target and Path(row['artifact']['path']).name == name]
    if len(selected) != 1 or selected[0] not in ('writer', 'verify'):
        raise ValueError('Matched triple requested an unrelated sealed role')
    join_ref = source['matched_role_source_join']
    if (recipe.get('role_source_join') != join_ref or closed.get('role_source_join') != join_ref
            or recipe.get('source_manifest') != row['compiled_source_authority']
            or closed.get('source_manifest') != row['compiled_source_authority']
            or closed.get('source_projection') != recipe.get('canonical_projection')
            or closed.get('source_qualification') != recipe.get('source_qualification')
            or any(closed.get(key) is not True for key in
                   ('normal_roles_emission_passed', 'writer_emission_passed', 'normal_writer_build_completed'))
            or closed.get('errors') != []):
        raise ValueError('Matched triple source or successful emission authority differs')
    join = prepared_metadata(join_ref)
    references = [join_ref, recipe['canonical_projection'], recipe['source_qualification']]
    for reference in references[1:]: prepared_metadata(reference)
    if (join.get('source_manifest') != row['compiled_source_authority']
            or join.get('same_graph_roles') is not True or join.get('wire_source_equal') is not True
            or join.get('new_roles_required') != ['writer', 'cli', 'verify']
            or join.get('artifacts_emitted') is not False
            or join.get('role_roots') != {key:value[2] for key,value in roles.items()}
            or set(join.get('role_members', {})) != set(roles)):
        raise ValueError('Matched triple reached-source membership differs')
    for key, members in join['role_members'].items():
        if (not isinstance(members, dict) or roles[key][2] not in members
                or any(compiled.get(name) != descriptor for name,descriptor in members.items())):
            raise ValueError('Matched triple role does not reach its declared production source')
    # Retained role policies also bind interface-only leaves. Their bytes are
    # checked against the emitted graph without claiming unused imports.
    interface = source.get('interface_only_sources', {})
    if (roles[selected[0]][2] not in row['source_paths']
            or not set(row['source_paths']) <= set(compiled) | set(interface)):
        raise ValueError('Sealed role source or interface authority differs')
    if interface:
        prior_ref = source.get('interface_only_role_binding')
        if not isinstance(prior_ref, dict):
            raise ValueError('Matched triple interface lacks original role authority')
        prior_roles = prepared_metadata(prior_ref)
        prior = prior_roles[roles[selected[0]][1]]
        prior_source_ref = prior['source']
        prior_source = prepared_metadata(prior_source_ref)
        prior_files = prior_source.get('files', prior_source)
        if (prior.get('previous_role_binding') != row.get('previous_role_binding')
                or prior['source_paths'] != row['source_paths']
                or not set(interface) <= set(RETAINED_NATIVE_ABI_PATHS)):
            raise ValueError('Matched triple interface changed original role policy')
        for name, descriptor in interface.items():
            if (name in compiled or name not in prior_files
                    or any(descriptor.get(key) != prior_files[name].get(key)
                           for key in ('bytes', 'sha256'))
                    or descriptor.get('mode') != prior_source.get('modes', {}).get(name, prior_files[name].get('mode', 0o644))
                    or native_roles.bind_input(Path(descriptor['path'])) != descriptor):
                raise ValueError('Matched triple interface payload differs from original authority')
            references.append(descriptor)
        references.extend((prior_ref, prior_source_ref))
    wire = join.get('wire_members', {})
    reached = join.get('wire_reached_roles', {})
    required_wire = ('src/encoder/presentation_types.zig', 'src/encoder/presentation_codec.zig')
    if not set(required_wire) <= set(wire) or set(wire) != set(reached):
        raise ValueError('Matched triple has incomplete wire authority')
    for name, descriptor in wire.items():
        actual_roles = [key for key in roles if name in join['role_members'][key]]
        if (compiled.get(name) != descriptor or reached[name] != actual_roles
                or (name in required_wire and set(actual_roles) != set(roles))):
            raise ValueError('Matched triple wire differs across reached roles')
    argv = recipe['argv']
    if (argv[:5] != [row['dependencies']['zig']['path'], 'build',
                    'prepare-captured-writer', 'cli', 'prepare-blob-verify']
            or [value for value in argv if value.startswith('-j')] != ['-j1']
            or argv.count('--prefix') != 1 or argv.index('--prefix') + 1 >= len(argv)):
        raise ValueError('Matched triple command has another target graph')
    prefix = Path(argv[argv.index('--prefix') + 1])
    artifacts = closed.get('installed_artifacts', {})
    expected = recipe.get('expected_install', {})
    if set(artifacts) != set(roles) or set(expected) != set(roles):
        raise ValueError('Matched triple lacks all three installed artifacts')
    for key, (_, name, _) in roles.items():
        descriptor = artifacts[key]
        path = prefix / 'bin' / name
        if (not isinstance(descriptor, dict) or set(descriptor) != {'path','bytes','sha256'}
                or descriptor['path'] != str(path) or expected[key] != str(path)):
            raise ValueError('Matched triple installed artifact location differs')
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o555
                or info.st_nlink != 1 or native_roles.bind_input(path) != dict(descriptor, mode=0o555)):
            raise ValueError('Matched triple installed artifact custody differs')
        references.append(descriptor)
    if row['artifact'] != dict(artifacts[selected[0]], mode=0o555):
        raise ValueError('Sealed role is not the selected actual triple artifact')
    return references


def initial_sealed_direct_writer(row, native_roles, *, target='prepare-captured-writer'):
    """Join one direct normal Writer install to its original guardian receipts."""
    keys = ('compilation_recipe', 'actual_emission_result', 'qualification_closure',
            'source', 'compiled_source_authority')
    references = [row[key] for key in keys]
    recipe, emitted, closed, source, compiled = [prepared_metadata(ref) for ref in references]
    matched_triple = 'matched_role_source_join' in source
    if (source.get('actual_normal_command') != row['compilation_recipe']
            or source.get('actual_result') != row['actual_emission_result']
            or source.get('actual_closure') != row['qualification_closure']
            or source.get('compiled_source_manifest') != row['compiled_source_authority']
            or source.get('fingerprint') != row['producer_source']
            or row['compiled_source_authority']['sha256'] != row['producer_source']
            or closed.get('result') != row['actual_emission_result']
            or closed.get('outcome') != 'PASSED-PHYSICALLY-SOURCE-CLOSED'
            or not all(closed.get(key) is True for key in (
                'source_after', 'source_lease_released', 'allocation_released',
                'local_proc_absent', 'ps_absent', 'host_namespace_identity_absent'))
            or type(emitted.get('returncode')) is not int or emitted['returncode'] != 0):
        raise ValueError('Direct Writer is not a source-closed successful emission')
    rt = Path(recipe.get('qualification_root', ''))
    if not rt.is_absolute() or rt.as_posix() != str(rt) or '..' in rt.parts:
        raise ValueError('Unsafe direct Writer output root')
    expected_paths = {
        'start': rt / 'direct-runtime01' / 'start.json',
        'owner_result': rt / 'direct-runtime01' / 'owner-result.json',
        'watchdog': rt / 'direct-runtime01' / 'watchdog.json',
        'result': rt / 'result01.json',
    }
    if any(closed.get(key, {}).get('path') != str(path) for key, path in expected_paths.items()):
        raise ValueError('Direct Writer receipts have different execution origins')
    start, owner, watchdog = [prepared_metadata(closed[key]) for key in ('start', 'owner_result', 'watchdog')]
    references.extend(closed[key] for key in ('start', 'owner_result', 'watchdog'))
    resolved_refs = start.get('source_refs')
    if matched_triple:
        config_ref = closed.get('owner_config')
        if not isinstance(config_ref, dict):
            raise ValueError('Matched triple lacks its normal owner configuration')
        config = prepared_metadata(config_ref); references.append(config_ref)
        resolved_refs = recipe.get('source_refs')
        if (config.get('input_ref') != row['compilation_recipe']
                or config.get('source_refs_ref') != row['compilation_recipe']
                or start.get('source_refs_ref') != row['compilation_recipe']
                or not isinstance(resolved_refs, list) or len(resolved_refs) < 2
                or config.get('source_refs') != resolved_refs[:2]
                or start.get('source_refs') != resolved_refs[:2]
                or not isinstance(config.get('required_owner'), dict)
                or config['required_owner'] != recipe.get('required_owner', config['required_owner'])
                or closed.get('selected_owner') != config['required_owner']):
            raise ValueError('Matched triple compact source authority differs')
        encoded_refs = json.dumps(resolved_refs, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode('utf-8')
        summary = dict(source_ref_count=len(resolved_refs), source_refs_sha256=hashlib.sha256(encoded_refs).hexdigest())
        if any(start.get(key) != value or closed.get(key) != value for key,value in summary.items()):
            raise ValueError('Matched triple source count or digest differs')
        references.append(config['required_owner'])
    if (start.get('input_authority') != row['compilation_recipe']
            or resolved_refs != recipe.get('source_refs')
            or owner.get('source_after') is not True
            or type(owner.get('returncode')) is not int or owner['returncode'] != 0
            or watchdog.get('child_exit_status') != 0
            or watchdog.get('guardian_exit_status') != 0
            or watchdog.get('runtime_started') is not True
            or watchdog.get('cleanup_complete') is not True
            or watchdog.get('admission_refused') is not False
            or watchdog.get('termination_reason') != 'child_exit'
            or emitted.get('argv') != recipe.get('argv')
            or emitted.get('cwd') != recipe.get('cwd')
            or emitted.get('environment') != recipe.get('env')):
        raise ValueError('Direct Writer command or guarded outcome differs')
    # A transport gap can coexist with known child success and OS absence.
    # It must not become an invented RD reaping receipt.
    if ((closed.get('reaped') is True and (type(closed.get('terminal')) is not int or closed['terminal'] != 0))
            or (closed.get('reaped') is False and closed.get('terminal') is not None)
            or type(closed.get('reaped')) is not bool):
        raise ValueError('Direct Writer transport outcome is inconsistent')
    receipt = closed.get('rd_terminal_receipt')
    if ((closed['reaped'] and (not isinstance(receipt, dict)
                              or type(receipt.get('exit_code')) is not int or receipt['exit_code'] != 0
                              or type(receipt.get('chunk')) is not int or receipt['chunk'] <= 0
                              or receipt.get('chunk') != closed.get('reaped_chunk')))
            or (not closed['reaped'] and receipt is not None)):
        raise ValueError('Direct Writer RD receipt differs from its terminal outcome')
    identities = closed.get('identities', [])
    owner_identity = start.get('owner')
    process_identities = [owner_identity,
        dict(pid=watchdog.get('child_pid'), birth=watchdog.get('child_start_time_ticks')),
        dict(pid=watchdog.get('guardian_pid'), birth=watchdog.get('guardian_start_time_ticks'))]
    if any(not isinstance(identity, dict) or set(identity) != {'pid', 'birth'}
           or any(type(identity[key]) is not int or identity[key] <= 0 for key in ('pid', 'birth'))
           or identity not in identities for identity in process_identities):
        raise ValueError('Direct Writer process closure does not cover its actual owner and children')
    argv = recipe['argv']
    if matched_triple:
        references.extend(initial_sealed_matched_triple(row, native_roles, recipe, closed, source, compiled, target=target))
    elif target != 'prepare-captured-writer' or argv[:3] != [row['dependencies']['zig']['path'], 'build', 'prepare-captured-writer']:
        raise ValueError('Direct sealed successor requires one Writer target')
    cwd = Path(recipe['cwd'])
    if not cwd.is_absolute() or '..' in cwd.parts:
        raise ValueError('Unsafe direct Writer source root')
    environment = recipe['env']
    if set(environment) - {'ZIG_GLOBAL_CACHE_DIR'}:
        raise ValueError('Unreviewed direct Writer environment')
    if 'ZIG_GLOBAL_CACHE_DIR' in environment and not Path(environment['ZIG_GLOBAL_CACHE_DIR']).is_absolute():
        raise ValueError('Unsafe direct Writer cache')
    required = {'-Doptimize=safe', '-Dtarget=x86_64-native', '-Dcpu=baseline',
                '-Dcaptured-source-fingerprint=' + row['producer_source']}
    seen = set(); prefix = None; index = 5 if matched_triple else 3
    while index < len(argv):
        value = argv[index]
        if value in ('--summary', '--search-prefix', '--cache-dir', '--global-cache-dir', '--prefix'):
            if value in seen or index + 1 >= len(argv):
                raise ValueError('Duplicate or incomplete direct Writer option')
            argument = argv[index + 1]
            if value == '--summary':
                if argument != 'all': raise ValueError('Direct Writer summary differs')
            elif not Path(argument).is_absolute() or '..' in Path(argument).parts:
                raise ValueError('Unsafe direct Writer option path')
            if value == '--prefix': prefix = Path(argument)
            seen.add(value); index += 2
        elif value in required or value == '-Dtest-optimize=safe' or re.fullmatch(r'-j[1-9][0-9]*', value):
            if value in seen: raise ValueError('Duplicate direct Writer option')
            seen.add(value); index += 1
        else:
            raise ValueError('Unreviewed direct Writer option or target')
    if not required | {'--prefix', '--summary'} <= seen:
        raise ValueError('Direct Writer required options differ')
    artifact = {key: row['artifact'][key] for key in ('path', 'bytes', 'sha256')}
    if not matched_triple and (closed.get('artifact') != artifact or artifact['path'] != str(prefix / 'bin' / 'dict-blob-build')):
        raise ValueError('Direct Writer installed artifact differs')
    declared = {item['path']: item for item in resolved_refs}
    if len(declared) != len(resolved_refs):
        raise ValueError('Duplicate direct Writer source authority')
    manifest_ref = row['compiled_source_authority']
    if declared.get(manifest_ref['path']) != manifest_ref:
        raise ValueError('Direct Writer did not guard its source manifest')
    entry_point = 'tools/blob_verify.zig' if matched_triple and target == 'prepare-blob-verify' else 'tools/blob_build.zig'
    if entry_point not in compiled or entry_point not in row['source_paths']:
        raise ValueError('Direct role source does not contain its production entry point')
    resolved_files = source.get('resolved_compiled_source_files', compiled)
    if (set(resolved_files) != set(compiled)
            or (resolved_files != compiled and source.get('compiled_aliases_documentary_only') is not True)):
        raise ValueError('Direct target resolved source membership differs')
    for name, descriptor in compiled.items():
        relative = Path(name)
        guarded = declared.get(descriptor.get('path'))
        if (relative.is_absolute() or '..' in relative.parts or relative.as_posix() != name
                or set(descriptor) != {'path', 'bytes', 'sha256', 'mode'}
                or type(descriptor['mode']) is not int
                or not 0 <= descriptor['mode'] <= 0o777
                or not isinstance(guarded, dict)
                or set(guarded) not in ({'path', 'bytes', 'sha256'}, {'path', 'bytes', 'sha256', 'mode'})
                or any(guarded[key] != descriptor[key] for key in ('path', 'bytes', 'sha256'))
                or guarded.get('mode', descriptor['mode']) != descriptor['mode']):
            raise ValueError('Direct Writer compiled source is not guarded')
        # This receipt family keeps the canonical role root while compiling a
        # sparse view. Bind the actual command root to every declared member,
        # including aliases, rather than treating the fingerprint flag as proof.
        try:
            same_source = (cwd / relative).resolve(strict=True) == Path(descriptor['path']).resolve(strict=True)
        except OSError as error:
            raise ValueError('Direct Writer source view is unavailable') from error
        resolved = resolved_files[name]
        if (not isinstance(resolved, dict) or set(resolved) != set(descriptor)
                or any(resolved[key] != descriptor[key] for key in ('bytes', 'sha256', 'mode'))
                or Path(resolved['path']) != Path(descriptor['path']).resolve(strict=True)
                or not same_source or native_roles.bind_input(Path(resolved['path'])) != resolved):
            raise ValueError('Direct target command source view differs from its guarded regular payload')
    interface = source.get('interface_only_sources', {})
    if (set(interface) & set(compiled)
            or source.get('interface_only_not_claimed_as_compiler_reads') is not True
            or source.get('files') != dict(resolved_files, **interface)
            or not set(row['source_paths']) <= set(source['files'])):
        raise ValueError('Direct Writer source/interface membership differs')
    references.extend(emitted[key] for key in ('stdout', 'stderr'))
    for reference in references:
        observed = native_roles.bind_input(Path(reference['path']))
        if any(observed[key] != reference[key] for key in ('path', 'bytes', 'sha256')):
            raise ValueError('Direct Writer authority changed')
    if native_roles.bind_input(Path(row['artifact']['path'])) != row['artifact']:
        raise ValueError('Direct Writer binary changed')
    native_roles.require_unchanged()
    return argv, references


def initial_sealed_target_emission(row, native_roles, *, target, full_graph=False):
    """Authenticate one actual successful install target; never promote the graph verdict."""
    references = [row[key] for key in ('compilation_recipe', 'actual_emission_result', 'qualification_closure', 'source')]
    recipe, emitted, closed, source = [prepared_metadata(reference) for reference in references]
    if 'argv' in recipe and 'actual_normal_command' in source:
        allowed_targets = ('prepare-captured-writer', 'prepare-blob-verify') if 'matched_role_source_join' in source else ('prepare-captured-writer',)
        if target not in allowed_targets or full_graph:
            raise ValueError('Direct guardian successor has an unrelated target')
        return initial_sealed_direct_writer(row, native_roles, target=target)
    retained_compilation_source(row, native_roles)
    guard_reference = recipe.get('source_guard_manifest', row['source'])
    composite = 'source_guard_manifest' in recipe
    if composite:
        base_source = prepared_metadata(guard_reference)
        if (source.get('head') is not None or closed.get('source_guard_manifest') != guard_reference
                or closed.get('source_payload_files') != recipe.get('source_payload_files')):
            raise ValueError('Composite source closure differs from its guarded payloads')
        # A proven closed emission retains immutable source facts. Source paths
        # are not execution inputs after its complete physical guard closes.
        validate_composite_source_inventory(recipe, base_source, source, None)
        projected = {name:value for name,value in recipe['source_payload_files'].items() if name in row['source_paths']}
        if row.get('source_payload_files', {}) != projected:
            raise ValueError('Composite role payload projection differs from its actual compilation')
        if 'source_path_view' in recipe:
            if closed.get('source_path_view') != recipe['source_path_view']:
                raise ValueError('Composite closed path-view authority differs')
            prepared_metadata(recipe['source_path_view'])
            references.append(recipe['source_path_view'])
        references.append(guard_reference)
    elif 'source_payload_files' in recipe or 'source_guard_manifest' in closed:
        raise ValueError('Incomplete composite source authority')
    source_head = source.get('head')
    if source_head is None:
        binding_reference = recipe.get('private_source_binding')
        baseline_reference = recipe.get('baseline_source_manifest')
        if ('files' in source or 'head' in source
                or not isinstance(binding_reference, dict)
                or not isinstance(baseline_reference, dict)):
            raise ValueError('Initial sealed private source authority is missing')
        binding = prepared_metadata(binding_reference)
        baseline = prepared_metadata(baseline_reference)
        identity = binding.get('source_identity')
        source_head = baseline.get('head')
        if (closed.get('private_source_binding') != binding_reference
                or binding.get('private_manifest') != guard_reference
                or binding.get('canonical_source') != baseline_reference
                or binding.get('source_path') != row['source_root']
                or binding.get('canonical_source_changed') is not False
                or not isinstance(identity, dict)
                or recipe.get('source_root') != dict(identity, path=row['source_root'])
                or not isinstance(source_head, str)
                or re.fullmatch('[0-9a-f]{40}', source_head) is None):
            raise ValueError('Initial sealed private source authority differs')
        references.extend((binding_reference, baseline_reference))
    commands = emitted.get('commands', [])
    if (len(commands) != 1 or len(recipe.get('commands', [])) != 1
            or closed.get('commands') != commands or closed.get('result') != row['actual_emission_result']
            or emitted.get('source_authority') != row['compilation_recipe']
            or recipe.get('source_manifest') != row['source'] or closed.get('source_manifest') != row['source']
            or recipe.get('source_head') != source_head
            or any(closed.get(key) is not True for key in ('source_after', 'whole_source_guard_after',
                'source_lease_released', 'allocation_released', 'reaped', 'local_proc_absent'))):
        raise ValueError('Initial sealed target lacks its actual closed source/command authority')
    command, declared = commands[0], recipe['commands'][0]
    argv = command['argv']
    if (argv != declared['argv'] or command['cwd'] != declared['cwd'] or command['status'] != 'exited'
            or argv[:2] != [row['dependencies']['zig']['path'], 'build']
            or command['cwd'] != row['source_root'] or argv.count('--summary') != 1
            or argv[argv.index('--summary') + 1] != 'all' or argv.count('--prefix') != 1):
        raise ValueError('Initial sealed target command differs')
    targets = []
    for value in argv[2:]:
        if value.startswith('-'): break
        targets.append(value)
    writer_consumer_graph = (target == 'prepare-captured-writer'
                             and targets == ['prepare-captured-writer', 'cli', 'ffi'])
    if (not targets or len(targets) != len(set(targets)) or target not in targets
            or (not full_graph and targets != [target] and not writer_consumer_graph)):
        raise ValueError('Initial sealed target was not requested exactly once')
    failed = command.get('returncode') != 0
    if (type(command.get('returncode')) is not int
            or emitted.get('passed') is not (not failed)
            or closed.get('outcome') != ('FAILED' if failed else 'PASSED')+'-PHYSICALLY-SOURCE-CLOSED'
            or (failed and (closed.get('full_native_pass') is not False or closed.get('full_graph_passed') is not False))):
        raise ValueError('Initial sealed target graph verdict differs')
    fingerprint = '-Dcaptured-source-fingerprint=' + row['producer_source']
    if ([arg for arg in argv if arg.startswith('-Dcaptured-source-fingerprint=')] != [fingerprint]
            or '-Doptimize=safe' not in argv or '-Dtarget=x86_64-native' not in argv or '-Dcpu=baseline' not in argv):
        raise ValueError('Initial sealed target source/optimization flags differ')
    prefix = Path(argv[argv.index('--prefix') + 1])
    role = Path(row['artifact']['path']).name
    allowed_roles = {'prepare-blob-tools': BLOB_TOOL_NAMES, 'prepare-captured-writer': ('dict-blob-build',),
                     'prepare-blob-verify': ('dict-blob-verify',),
                     'prepare-bundle-driver': ('dict-bundle-build',)}
    if role not in allowed_roles.get(target, ()):
        raise ValueError('Initial sealed target has another role')
    if Path(row['artifact']['path']) != prefix / 'bin' / role:
        raise ValueError('Initial sealed target installed another artifact')
    stderr = command.get('stderr')
    if not isinstance(stderr, dict) or set(stderr) != {'path', 'bytes', 'sha256'}:
        raise ValueError('Initial sealed target lacks its complete saved summary')
    observed = native_roles.bind_input(Path(stderr['path']))
    if any(observed[key] != stderr[key] for key in ('path', 'bytes', 'sha256')):
        raise ValueError('Initial sealed target summary changed')
    text = Path(stderr['path']).read_text()
    summaries = list(re.finditer(r'^Build Summary: (\d+)/(\d+) steps succeeded(?: \((\d+) failed\))?\s*$', text, re.MULTILINE))
    if (len(summaries) != 1
            or (int(summaries[0].group(3) or 0) > 0) is not failed):
        raise ValueError('Initial sealed target summary is ambiguous')
    summary = text[summaries[0].end():]
    top = re.findall(r'^([a-z][a-z-]*) (success|failure|transitive failure)(?:[^\n]*)$', summary, re.MULTILINE)
    if (len(top) != len(targets) or {name for name,_ in top} != set(targets)
            or len(dict(top)) != len(top) or dict(top).get(target) != 'success'
            or (not failed and any(status != 'success' for _,status in top))):
        raise ValueError('Initial sealed target has a failed or missing requested target')
    start = re.search(r'^' + re.escape(target) + r' success[^\n]*\n', summary, re.MULTILINE)
    if start is None:
        raise ValueError('Initial sealed target is absent')
    end = re.search(r'^[a-z][a-z-]* (?:success|failure|transitive failure)', summary[start.end():], re.MULTILINE)
    block = summary[start.end():start.end()+end.start()] if end is not None else summary[start.end():]
    if re.search(r'^\s*\+- install ' + role + r' success\s*$', block, re.MULTILINE) is None:
        raise ValueError('Initial sealed install did not succeed')
    production = closed.get('production_roles')
    prepared = closed.get('prepared_artifacts')
    if production is not None or prepared is not None:
        # Both existing closure schemas authenticate actual production outputs;
        # successful requested targets never promote unrelated test verdicts.
        key = {'dict-blob-build':'writer', 'dict-blob-merge':'merge',
               'dict-blob-verify':'verify', 'dict-bundle-build':'driver'}[role]
        if production is not None and prepared is not None:
            raise ValueError('Ambiguous closed production artifact schema')
        artifacts=production if production is not None else prepared
        captured=artifacts.get(key) if isinstance(artifacts,dict) else None
        if (not isinstance(captured,dict)
                or dict(captured.get('reference',{}),mode=captured.get('mode')) != row['artifact']):
            raise ValueError('Initial sealed target lacks its closed production artifact')
        if production is not None:
            if (closed.get('emission_pass') is not True or captured.get('successful_graph_target') is not True
                    or captured.get('source_manifest') != row['source']):
                raise ValueError('Initial sealed target lacks its successful production observation')
            origin_reference=captured['origin_configuration']
        else:
            if failed or closed.get('production_roles_passed') is not True or prepared!=emitted.get('artifacts'):
                raise ValueError('Prepared production artifacts lack a successful complete emission')
            origin_reference=closed.get('owner_configuration')
        origin = prepared_metadata(origin_reference)
        if (closed.get('owner_configuration') != origin_reference
                or origin.get('bindings',{}).get('INPUT_REF') != row['compilation_recipe']):
            raise ValueError('Initial sealed production artifact configuration differs')
        path = Path(row['artifact']['path']); info = path.stat()
        observed_stamp = dict(device=info.st_dev,inode=info.st_ino,mode=stat.S_IMODE(info.st_mode),
            mtime_ns=info.st_mtime_ns,ctime_ns=info.st_ctime_ns,nlink=info.st_nlink)
        if any(captured.get(name) != value for name,value in observed_stamp.items()):
            raise ValueError('Initial sealed production artifact custody differs')
        references.append(origin_reference)
    elif full_graph:
        # Historical post-closure observations retain their original authority.

        # Consume its existing post-closure actual-native/source handoff instead.
        handoff_reference = row.get('qualified_source_handoff')
        if not isinstance(handoff_reference,dict):
            raise ValueError('Initial sealed Writer target lacks its actual artifact observation')
        handoff = prepared_metadata(handoff_reference)
        origin = handoff.get('origin',{})
        if (handoff.get('full_native_pass') is not False
                or origin.get('source_head') != source.get('head')
                or origin.get('source_fingerprint') != row['producer_source']
                or handoff.get('artifacts',{}).get(role) != row['artifact']):
            raise ValueError('Initial sealed Writer target artifact observation differs')
        for origin_key,row_key in (('result','actual_emission_result'),('closure','qualification_closure')):
            descriptor = origin.get(origin_key)
            if (not isinstance(descriptor,dict) or set(descriptor) != {'path','bytes','sha256','mode'}
                    or {key:descriptor[key] for key in ('path','bytes','sha256')} != row[row_key]
                    or native_roles.bind_input(Path(descriptor['path'])) != descriptor):
                raise ValueError('Initial sealed Writer artifact origin descriptor differs')
        references.append(handoff_reference)
    else:
        artifact = emitted.get('artifacts',{}).get(role)
        if (not isinstance(artifact,dict) or not isinstance(artifact.get('reference'),dict)
                or dict(artifact['reference'],mode=artifact.get('mode')) != row['artifact']):
            raise ValueError('Initial sealed driver target artifact observation differs')
    observed = native_roles.bind_input(Path(row['artifact']['path']))
    if observed != row['artifact']:
        raise ValueError('Initial sealed target artifact bytes or mode changed')
    native_roles.require_unchanged()
    return argv, [*references, stderr]


def initial_sealed_blob_successor(original, native_roles):
    """Resume a closed worker with current blob tools; never execute its old driver."""
    import copy
    import extraction_cache as cache
    current = native_roles.records
    old_driver, driver = [copy.deepcopy(value['dict-bundle-build']) for value in (original,current)]
    old_driver['dependencies'].pop('extraction_helper',None)
    live = driver['dependencies'].pop('extraction_helper',None)
    if (old_driver != driver or not isinstance(live,dict)
            or Path(live['path']) != Path(cache.__file__).absolute()
            or native_roles.bind_input(Path(live['path'])) != live):
        raise ValueError('Initial sealed execution changed its original unused driver or live helper')
    allowed = {'artifact','source','producer_source','compiled_source_authority','source_payload_files',
        'source_payload_git','source_root','compilation_recipe','actual_emission_result','qualification_closure',
        'qualification_scope','previous_role_binding'}
    references = []
    for name in BLOB_TOOL_NAMES:
        before, after = original[name], current[name]
        if name in ('dict-blob-merge','dict-blob-verify') and after == before:
            # These already-authenticated roles retain their original emission,
            # source projection and artifact. They still join the ABI check below.
            continue
        if not {'previous_role_binding','compilation_recipe','actual_emission_result','qualification_closure'} <= set(after):
            raise ValueError('Initial sealed successor selected different native roles without closed emission authority')
        if ({k:v for k,v in before.items() if k not in allowed} !=
                {k:v for k,v in after.items() if k not in allowed}
                or prepared_metadata(after['previous_role_binding']) != original):
            raise ValueError('Initial sealed blob successor changed native dependencies or role policy')
        # Each role retains its own closed emission; compatibility is checked
        # through the exact interface identities below.
        recipe = prepared_metadata(after['compilation_recipe'])
        commands = recipe.get('commands', [])
        writer_only = (name == 'dict-blob-build' and (
            (len(commands) == 1 and 'prepare-captured-writer' in commands[0].get('argv', []))
            or recipe.get('argv', [])[:3] == [after['dependencies']['zig']['path'], 'build', 'prepare-captured-writer']))
        verify_only = (name == 'dict-blob-verify' and (
            (len(commands) == 1 and 'prepare-blob-verify' in commands[0].get('argv', []))
            or recipe.get('argv', [])[2:5] == ['prepare-captured-writer', 'cli', 'prepare-blob-verify']))
        target = 'prepare-captured-writer' if writer_only else 'prepare-blob-verify' if verify_only else 'prepare-blob-tools'
        _, target_references = initial_sealed_target_emission(after,native_roles,target=target,full_graph=not(writer_only or verify_only))
        references.extend([after['previous_role_binding'],*target_references])
        source = prepared_metadata(after['source']); inventory = source.get('files',source)
        for relative in after['source_paths']:
            identity = (dict(inventory[relative], mode=source.get('modes',{}).get(relative,inventory[relative].get('mode',0o644)))
                        if 'source_guard_manifest' in recipe else native_roles.compilation_identity(after,relative))
            if (any(identity[key] != inventory[relative][key] for key in ('bytes','sha256'))
                    or identity['mode'] != source.get('modes',{}).get(relative,inventory[relative].get('mode',0o644))):
                raise ValueError('Initial sealed blob successor compiled payload changed')
    for interface,members,paths in RETAINED_NATIVE_ROLE_ABI_INTERFACES:
        identities = []
        for name in members:
            source = prepared_metadata(current[name]['source']); inventory = source.get('files',source)
            identities.append({path:(inventory[path]['bytes'],inventory[path]['sha256']) for path in paths})
        if any(value != identities[0] for value in identities[1:]):
            raise ValueError('Initial sealed blob successor changed '+interface+' ABI')
    for reference in references:
        actual = native_roles.bind_input(Path(reference['path']))
        if any(actual[key] != reference[key] for key in ('path','bytes','sha256')):
            raise ValueError('Initial sealed blob successor authority changed')
    native_roles.require_unchanged()


def initial_sealed_role_successor(original, native_roles):
    """Keep the closed worker's origin while authenticating a later blob-stage emission."""
    current = native_roles.records
    import copy
    drivers = [copy.deepcopy(value.get('dict-bundle-build')) for value in (original,current)]
    if all(isinstance(value,dict) and isinstance(value.get('dependencies'),dict) for value in drivers):
        for value in drivers:value['dependencies'].pop('extraction_helper',None)
        if drivers[0] == drivers[1] and any(original.get(name) != current.get(name) for name in BLOB_TOOL_NAMES):
            if set(original) != set(RETAINED_NATIVE_ROLE_NAMES) or set(current) != set(original):
                raise ValueError('Initial sealed execution role membership differs')
            return initial_sealed_blob_successor(original,native_roles)
    if (set(original) != set(RETAINED_NATIVE_ROLE_NAMES) or set(current) != set(original)
            or any(current[name] != original[name] for name in ('dict-blob-merge','dict-blob-verify'))):
        raise ValueError('Initial sealed successor changed a retained role')
    allowed = {'artifact','source','producer_source','compiled_source_authority','source_payload_files',
               'compilation_recipe','actual_emission_result','qualification_closure','qualified_source_handoff',
               'qualification_scope','previous_role_binding','dependencies','embedded_writer'}
    writer, driver = current['dict-blob-build'], current['dict-bundle-build']
    if any(not {'previous_role_binding','compilation_recipe','actual_emission_result','qualification_closure'} <= set(row) for row in (writer,driver)):
        raise ValueError('Initial sealed successor selected different native roles without closed emission authority')
    authority_keys = ('compilation_recipe','actual_emission_result','qualification_closure','source')
    split_targets = any(writer[key] != driver[key] for key in authority_keys)
    if split_targets: allowed.add('source_payload_git')
    for name in ('dict-blob-build','dict-bundle-build'):
        before, after = original[name], current[name]
        if {k:v for k,v in before.items() if k not in allowed} != {k:v for k,v in after.items() if k not in allowed}:
            raise ValueError('Initial sealed successor changed role policy')
        if 'previous_role_binding' not in after:
            raise ValueError('Initial sealed successor lacks its original role binding')
        if prepared_metadata(after['previous_role_binding']) != original:
            raise ValueError('Initial sealed successor names another original role map')
        old_source, new_source = prepared_metadata(before['source']), prepared_metadata(after['source'])
        old_inventory, new_inventory = old_source.get('files',old_source), new_source.get('files',new_source)
        required = set(after['source_paths']) if name == 'dict-bundle-build' else {
            path for _,members,paths in RETAINED_NATIVE_ROLE_ABI_INTERFACES if name in members for path in paths}
        for path in required:
            if (old_inventory[path] == new_inventory[path]
                    and old_source.get('modes',{}).get(path) == new_source.get('modes',{}).get(path)):
                continue
            if not split_targets or name != 'dict-bundle-build' or path != 'tools/extraction_cache.py':
                raise ValueError('Initial sealed successor changed source ABI or driver policy')
            # The closed worker's producer policy is immutable. Only the separately
            # authenticated imported helper may have moved to a qualified successor.
            import extraction_cache as selected_helper
            old_policy = before['dependencies'].get('runtime_source:' + path)
            live = after['dependencies'].get('extraction_helper')
            compiled_helper = native_roles.compilation_identity(before,path)
            if (old_policy != after['dependencies'].get('runtime_source:' + path)
                    or not isinstance(old_policy,dict) or not isinstance(live,dict)
                    or any(old_inventory[path][key] != compiled_helper[key] for key in ('bytes','sha256'))
                    or compiled_helper['mode'] != old_source.get('modes',{}).get(path,old_inventory[path].get('mode',0o644))
                    or any(new_inventory[path][key] != live[key] for key in ('bytes','sha256'))
                    or Path(live['path']).resolve() != Path(selected_helper.__file__).resolve()
                    or native_roles.bind_input(Path(live['path'])) != live):
                raise ValueError('Initial sealed successor changed original helper policy or live helper')
    if writer['dependencies'] != original['dict-blob-build']['dependencies']:
        raise ValueError('Initial sealed successor changed Writer native dependencies')
    omitted = {'blobs','pipeline_paths','extraction_helper'}
    if ({k:v for k,v in driver['dependencies'].items() if k not in omitted} !=
            {k:v for k,v in original['dict-bundle-build']['dependencies'].items() if k not in omitted}
            or driver.get('embedded_writer') != writer['artifact']
            or driver['dependencies'].get('blobs') != writer['artifact']):
        raise ValueError('Initial sealed successor changed retained native dependencies')
    if split_targets:
        _, writer_references = initial_sealed_target_emission(writer, native_roles,
            target='prepare-blob-tools', full_graph=True)
        argv, driver_references = initial_sealed_target_emission(driver, native_roles,
            target='prepare-bundle-driver')
        references = [*writer_references, *driver_references]
        for row in (writer,driver):
            source = prepared_metadata(row['source']); inventory = source.get('files',source)
            for path in row['source_paths']:
                identity = native_roles.compilation_identity(row,path)
                if (any(identity[key] != inventory[path][key] for key in ('bytes','sha256'))
                        or identity['mode'] != source.get('modes',{}).get(path,inventory[path].get('mode',0o644))):
                    raise ValueError('Initial sealed target compiled payload custody differs')
    else:
        references = [writer[key] for key in ('compilation_recipe','actual_emission_result','qualification_closure','source')]
        if any(driver[key] != writer[key] for key in ('compilation_recipe','actual_emission_result','qualification_closure','source')):
            raise ValueError('Initial sealed successor has split emission authority')
        recipe, emitted, closed, source = [prepared_metadata(row) for row in references]
        if (closed.get('outcome') != 'PASSED-PHYSICALLY-SOURCE-CLOSED'
                or not all(closed.get(k) is True for k in ('passed','source_after','whole_source_guard_after','source_lease_released','allocation_released','writer_retained_driver_emission_passed'))
                or closed.get('result') != writer['actual_emission_result'] or not emitted.get('passed')
                or emitted.get('source_authority') != writer['compilation_recipe']
                or recipe.get('source_manifest') != writer['source'] or closed.get('source_manifest') != writer['source']
                or recipe.get('source_head') != source.get('head')
                or closed.get('commands') != emitted.get('commands')
                or len(emitted.get('commands',[])) != 2):
            raise ValueError('Initial sealed successor emission is not independently closed')
        for index,(name,target) in enumerate((('dict-blob-build','prepare-captured-writer'),('dict-bundle-build','prepare-bundle-driver'))):
            row=emitted['commands'][index]; command=recipe['commands'][index]; artifact=emitted['artifacts'][name]
            if (row.get('returncode') != 0 or row['argv'] != command['argv'] or row['cwd'] != command['cwd']
                    or row['argv'][1:3] != ['build',target] or row['argv'][0] != writer['dependencies']['zig']['path']
                    or dict(artifact['reference'],mode=artifact['mode']) != current[name]['artifact']):
                raise ValueError('Initial sealed successor emitted another artifact or graph')
        argv=emitted['commands'][1]['argv']
    for option,key in (('worker-object','worker_object'),('value-leaf-bc','value_leaf_bc'),('worker-main-c','worker_main_c'),('modules','modules'),('llvm','llvm'),('blobs','blobs')):
        prefix='-Dbundle-driver-'+option+'='
        if [arg for arg in argv if arg.startswith(prefix)] != [prefix+driver['dependencies'][key]['path']]:
            raise ValueError('Initial sealed successor lacks exact retained driver arguments')
    pipeline=driver['dependencies']['pipeline_paths']
    observed=native_roles.bind_input(Path(pipeline['path']))
    if observed != pipeline:
        raise ValueError('Initial sealed successor pipeline metadata changed')
    pattern=r'^pub const ([a-z_]+): \[\]const u8 = ("[^"\n]*");$'
    text=Path(pipeline['path']).read_text()
    options=re.findall(pattern,text,re.MULTILINE)
    expected={key:driver['dependencies'][key]['path'] for key in ('worker_object','value_leaf_bc','worker_main_c','modules','llvm','blobs','zig')}
    expected.update(clang='clang',project_root='.')
    if (re.sub(pattern,'',text,flags=re.MULTILINE).strip() or len(options)!=len(expected)
            or {key:json.loads(value) for key,value in options}!=expected):
        raise ValueError('Initial sealed successor pipeline paths differ')
    for reference in references:
        observed=native_roles.bind_input(Path(reference['path']))
        if any(observed[k] != reference[k] for k in ('path','bytes','sha256')):
            raise ValueError('Initial sealed successor authority changed')


def initial_sealed_context_options(selected, native_roles, *, root=None, seal_reference=None, original_dump=None):
    """Retain the exact existing custody authorities selected for this worker."""
    options = {}
    references = []
    for name in ('snapshot_metadata_refresh', 'metadata_custody_refresh', 'extraction_metadata_refresh'):
        if name in selected:
            reference = selected[name]
            options[name] = prepared_metadata(reference)
            references.append(reference)
    if 'extraction_metadata_refresh' in options:
        if any(name in selected for name in ('file_metadata_provider_update', 'sitelinks_provider_update')):
            raise ValueError('Initial extraction custody cannot mix Provider updates')
        references.append(options['extraction_metadata_refresh']['cache_manifest'])
    if 'metadata_custody_refresh' in options:
        if any(name in selected for name in ('file_metadata_provider_update', 'sitelinks_provider_update')):
            raise ValueError('Initial metadata custody cannot mix Provider updates')
        receipt = options['metadata_custody_refresh']
        operation = prepared_metadata(receipt['operation'])
        native = prepared_metadata(receipt['native_validation'])
        references.extend([receipt['operation'], receipt['native_validation'],
                           operation['observations'], operation['source_manifest'], native['compatibility']])
        if operation.get('output_manifest') is not None:
            references.append(operation['output_manifest'])
    for reference in references:
        observed = native_roles.bind_input(Path(reference['path']))
        if any(observed[key] != reference[key] for key in ('path', 'bytes', 'sha256')):
            raise ValueError('Initial metadata custody authority changed')
    if 'restored_indexes' in selected:
        import extraction_cache as cache
        if root is None or seal_reference is None:
            raise ValueError('Restored indexes require their original prepared context')
        if any(name in selected for name in ('file_metadata_provider_update', 'sitelinks_provider_update', 'extraction_metadata_refresh')):
            raise ValueError('Restored indexes cannot mix Provider or extraction refresh')
        reference = selected['restored_indexes']
        selection = prepared_metadata(reference)
        binding = cache.restored_index_binding(root, selection, seal_reference['sha256'],
            previous=getattr(native_roles, '_restored_index_binding', None))
        for item in (reference, selection['cache_manifest']):
            observed = native_roles.bind_input(Path(item['path']))
            if any(observed[key] != item[key] for key in ('path', 'bytes', 'sha256')):
                raise ValueError('Restored index authority changed')
        seal = prepared_metadata(seal_reference)
        assets = {name: (size, digest) for name, size, digest in seal['identity']['assets']}
        # The binding has already hashed each unique inode. Carry both names in
        # the ordinary dispatch readset without a second corpus-sized read.
        for filename, custody in binding[4]:
            path = Path(filename)
            if path.name not in cache.RESTORED_INDEX_NAMES:
                native_roles.bind_input(path)
                continue
            stamp = custody[0][0]
            identity = dict(path=str(path), bytes=assets[path.name][0], sha256=assets[path.name][1], mode=stat.S_IMODE(stamp[2]))
            if path in native_roles.inputs and (native_roles.inputs[path] != stamp
                    or native_roles.input_identities[path] != identity):
                raise ValueError('Restored index differs from an existing input binding')
            native_roles.inputs[path] = stamp
            native_roles.input_identities[path] = identity
        cache._require_restored_indexes(binding, Path(root), seal_reference['sha256'])
        native_roles._restored_index_binding = binding
        options['restored_indexes'] = binding
    if 'restored_dump' in selected:
        import extraction_cache as cache
        if root is None or seal_reference is None or original_dump is None:
            raise ValueError('Restored dump requires its original prepared context')
        binding = cache.restored_dump_binding(root, selected['restored_dump'], seal_reference['sha256'],
            previous=getattr(native_roles, '_restored_dump_binding', None), restored_indexes=options.get('restored_indexes'))
        source = json.loads(binding[3]); restored = json.loads(binding[6])
        if (original_dump['path'] != source['path']
                or original_dump['bytes'] != restored['bytes']
                or original_dump['sha256'] != restored['sha256']):
            raise ValueError('Restored dump differs from its original preparation')
        # Carry the freshly authenticated physical input through the existing
        # parent/child dispatch readset; do not hash the same dump a second time.
        path = Path(binding[1]); stamp = binding[4]
        identity = dict(path=str(path), bytes=stamp[3], sha256=restored['sha256'], mode=stat.S_IMODE(stamp[2]))
        if path in native_roles.inputs and (native_roles.inputs[path] != stamp
                or native_roles.input_identities[path] != identity):
            raise ValueError('Restored dump differs from an existing input binding')
        native_roles.inputs[path] = stamp
        native_roles.input_identities[path] = identity
        native_roles._restored_dump_binding = binding
        options['restored_dump'] = binding
    return options


def require_initial_custody_inputs(options, auxiliary_snapshots, build_identity):
    """A failed known event can restore only its original selected complete tuple."""
    receipt = options.get('metadata_custody_refresh')
    if receipt is None:
        return
    operation = prepared_metadata(receipt['operation'])
    observations = prepared_metadata(operation['observations'])
    if observations.get('operation') != 'materialize-complete':
        return
    failed = operation.get('outcome') == 'FAILED-PHYSICALLY-SOURCE-CLOSED'
    source = operation['source_manifest']
    allowed = {Path(source['path']).parent:source}
    if not failed:
        output = operation['output_manifest']
        allowed[Path(output['path']).parent] = output
    paths = {}
    for name in (*FIGURE_SNAPSHOT_FILES, 'file-metadata'):
        path = Path((auxiliary_snapshots or {}).get(name, ''))
        if not path.is_absolute():
            raise ValueError('Initial known custody requires its complete selected Figure tuple')
        paths[name] = path.resolve(strict=True)
    roots = {path.parent for path in paths.values()}
    if len(roots) != 1 or next(iter(roots)) not in allowed:
        raise ValueError('Failed metadata custody cannot adopt another Figure output')
    selected = allowed[next(iter(roots))]
    manifests = build_identity.get('auxiliary_capture_sha256', {})
    if any(manifests.get(name) != selected['sha256'] for name in paths):
        raise ValueError('Initial known custody selected another Figure manifest')


def initial_sealed_generation(reference, native_roles):
    """Read a selected closed direct preparation, without inventing old shard state."""
    selected = prepared_metadata(reference)
    if (not {'preparation_result','preparation_closure'} <= set(selected)
            or not set(selected) <= {'preparation_result','preparation_closure','snapshot_metadata_refresh','metadata_custody_refresh','extraction_metadata_refresh','file_metadata_provider_update','sitelinks_provider_update','restored_dump','restored_indexes'}):
        raise ValueError('Invalid initial sealed generation selection')
    if 'file_metadata_provider_update' in selected and 'sitelinks_provider_update' in selected:
        raise ValueError('Mixed initial Provider update families')
    result = prepared_metadata(selected['preparation_result'])
    closed = prepared_metadata(selected['preparation_closure'])
    plan = prepared_metadata(result['input_authority'])
    if (not all(result.get(k) is True for k in ('passed', 'source_after', 'inputs_after'))
            or result.get('pages_executed') != 0 or result.get('whole_dictionary') is not False
            or result.get('native_generation_state_created') is not False
            or closed.get('outcome') != 'PASSED-PHYSICALLY-SOURCE-CLOSED'
            or not all(closed.get(k) is True for k in ('source_after', 'source_lease_released', 'allocation_released'))
            or closed.get('pages_executed') != 0
            or closed.get('native_generation_state_created') is not False
            or closed.get('preparation_result') != selected['preparation_result']
            or plan['roles'] != result['role_map']
            or result.get('installed_tools') != closed.get('installed_tools')):
        raise ValueError('Initial sealed preparation is not independently closed')
    original_roles = prepared_metadata(plan['roles'])
    # The dedicated imported helper is live Python, not compiled producer
    # policy. Keep every original runtime_source/ABI/artifact field exact.
    import copy
    comparisons = [copy.deepcopy(value) for value in (original_roles,native_roles.records)]
    for value in comparisons:
        value['dict-bundle-build']['dependencies'].pop('extraction_helper',None)
    if comparisons[0] != comparisons[1]:
        initial_sealed_role_successor(original_roles, native_roles)
    workspace = Path(plan['workspace'])
    if (not workspace.is_absolute() or workspace.resolve() != workspace
            or any(p.is_symlink() for p in (workspace, *workspace.parents))
            or not workspace.is_dir() or plan['repository'] != str(PROJECT)):
        raise ValueError('Unsafe initial sealed workspace')
    root = workspace / 'expander' / '.bundle-expander'
    for key, name in (('completed_expander_seal', '.completed-expander.json'),
                      ('worker', 'dict-bundle-expander'), ('metadata', 'lua-program.meta'),
                      ('source_receipt', 'extraction-source.json')):
        if (result[key] != closed.get(key) or result[key]['path'] != str(root / name)):
            raise ValueError('Initial sealed preparation changed its output origin')
    if result['expander'] != str(root):
        raise ValueError('Initial sealed preparation selected another expander')
    native_roles.require_unchanged()
    return selected, result, plan, workspace


def initial_page_language_providers(plan, expected, build_identity, snapshots, providers, native_roles):
    """Join selected capture companions to the exact closed native input authority."""
    names={'page-language.raw.json','page-language.html'} & set(providers)
    names={name for name in names if providers[name] is not None}
    if not names:return {}
    path=Path((snapshots or {}).get('page-language',''))
    if not path.is_absolute():raise ValueError('Initial sealed page-language capture is not selected')
    capture=validated_auxiliary_capture('page-language',path,expected['edition'],expected['date'])
    if capture is None:raise ValueError('Initial sealed page-language capture is not validated')
    manifest,inventory=capture
    manifests,artifacts=_project_auxiliary_capture_identities({'page-language':(*capture,auxiliary_manifest_filename('page-language',path))})
    if (manifest['output_sha256']!=build_identity.get('auxiliary_snapshot_sha256',{}).get('page-language')
            or manifest['namespace_registry_sha256']!=build_identity.get('auxiliary_snapshot_sha256',{}).get('namespace-registry')
            or any(identity.get('auxiliary_capture_sha256',{}).get('page-language')!=manifests['page-language']
                   or identity.get('auxiliary_capture_artifact_sha256',{}).get('page-language')!=artifacts['page-language']
                   for identity in (expected,build_identity))):
        raise ValueError('Initial sealed page-language capture identity differs')
    # Every selected member, including the manifest and logical snapshot, must
    # already be declared by the independently closed preparation at this path.
    for filename,digest in inventory.items():
        member=path.with_name(filename)
        observed=native_roles.bind_input(member)
        descriptor={key:observed[key] for key in ('path','bytes','sha256')}
        if (observed['sha256']!=digest or
                sum(row==descriptor for row in plan.get('inputs',[]))!=1):
            raise ValueError('Initial sealed page-language member is not a closed preparation input')
    result={}
    for name in names:
        row=manifest['artifacts'].get(name)
        if row is None or providers[name]!=[row['bytes'],row['sha256']]:
            raise ValueError('Initial sealed page-language provider differs from capture')
        result[name]=row['sha256']
    return result


def initial_external_writer_language(hashes, providers):
    """True only for a selected Writer capture and three sealed absent Providers."""
    if 'page-language' not in (hashes or {}):
        return False
    return all(name in providers and providers[name] is None for name in
               ('page-language.json', 'page-language.raw.json', 'page-language.html'))


def initial_sealed_worker_hashes(hashes, providers):
    """Keep sealed worker Providers distinct from the selected Writer Book."""
    result = dict(hashes or {})
    sealed_book = providers.get('figure-page-observations.json')
    if sealed_book is None:
        result.pop('figure-page-observations', None)
    elif 'figure-page-observations' in result:
        result['figure-page-observations'] = sealed_book[1]
    if initial_external_writer_language(result, providers):
        result.pop('page-language')
    return result


def initial_sealed_writer_book(expected, build_identity, snapshots, providers, native_roles):
    hashes = build_identity.get('auxiliary_snapshot_sha256', {})
    if 'figure-page-observations' not in hashes:
        return dict(hashes)
    path = Path((snapshots or {}).get('figure-page-observations', ''))
    if not path.is_absolute():
        raise ValueError('Initial Writer Book is not explicitly selected')
    capture = validated_auxiliary_capture('figure-page-observations', path, expected['edition'], expected['date'])
    if capture is None:
        raise ValueError('Initial Writer Book lacks validated capture authority')
    manifest, inventory = capture
    manifest_name = auxiliary_manifest_filename('figure-page-observations', path)
    if manifest_name not in inventory:
        raise ValueError('Initial Writer Book lacks its capture manifest')
    manifests, artifacts = _project_auxiliary_capture_identities({
        'figure-page-observations': (manifest, inventory, manifest_name)})
    for identity in (expected, build_identity):
        if (manifest['output_sha256'] != identity.get('auxiliary_snapshot_sha256', {}).get('figure-page-observations')
                or manifest['namespace_registry_sha256'] != identity.get('auxiliary_snapshot_sha256', {}).get('namespace-registry')
                or identity.get('auxiliary_capture_sha256', {}).get('figure-page-observations') != manifests['figure-page-observations']
                or identity.get('auxiliary_capture_artifact_sha256', {}).get('figure-page-observations') != artifacts['figure-page-observations']):
            raise ValueError('Initial Writer Book capture identity differs')
    for filename, digest in inventory.items():
        relative = Path(filename)
        if relative.is_absolute() or any(part in ('.', '..') for part in relative.parts):
            raise ValueError('Initial Writer Book capture escapes its package')
        if native_roles.bind_input(path.parent / relative)['sha256'] != digest:
            raise ValueError('Initial Writer Book capture bytes changed')
    observed = native_roles.bind_input(path)
    if observed['sha256'] != hashes['figure-page-observations']:
        raise ValueError('Initial Writer Book snapshot differs')
    book = prepared_metadata({key: observed[key] for key in ('path', 'bytes', 'sha256')})
    if (book.get('wiki') != expected['edition'] or book.get('date') != expected['date']
            or book.get('namespace_sha256') != hashes.get('namespace-registry')
            or book.get('defaults_sha256') != hashes.get('figure-siteinfo')):
        raise ValueError('Initial Writer Book namespace or site authority differs')
    native_roles.require_unchanged()
    return initial_sealed_worker_hashes(hashes, providers)


def initial_sealed_writer_inputs(expected, build_identity, snapshots, providers, native_roles):
    """Authenticate explicit Writer-only inputs without rewriting a sealed worker."""
    hashes = initial_sealed_writer_book(expected, build_identity, snapshots, providers, native_roles)
    selected = build_identity.get('auxiliary_snapshot_sha256', {}).get('page-language')
    if selected is None:
        return hashes
    sealed = providers.get('page-language.json')
    if sealed is not None and sealed[1] == selected:
        return hashes  # Existing closed preparation/companion checks still apply.
    if not initial_external_writer_language(build_identity.get('auxiliary_snapshot_sha256'), providers):
        raise ValueError('External Writer language snapshot cannot replace sealed language Providers')
    path = Path((snapshots or {}).get('page-language', ''))
    if not path.is_absolute():
        raise ValueError('External Writer language snapshot is not explicitly selected')
    capture = validated_auxiliary_capture('page-language', path, expected['edition'], expected['date'])
    if capture is None:
        raise ValueError('External Writer language snapshot lacks validated capture authority')
    manifest, inventory = capture
    manifest_name = auxiliary_manifest_filename('page-language', path)
    if manifest_name not in inventory:
        raise ValueError('External Writer language snapshot lacks its capture manifest')
    manifests, artifacts = _project_auxiliary_capture_identities({'page-language': (manifest, inventory, manifest_name)})
    for identity in (expected, build_identity):
        if (manifest['output_sha256'] != identity.get('auxiliary_snapshot_sha256', {}).get('page-language')
                or manifest['namespace_registry_sha256'] != identity.get('auxiliary_snapshot_sha256', {}).get('namespace-registry')
                or identity.get('auxiliary_capture_sha256', {}).get('page-language') != manifests['page-language']
                or identity.get('auxiliary_capture_artifact_sha256', {}).get('page-language') != artifacts['page-language']):
            raise ValueError('External Writer language capture identity differs')
    for filename, digest in inventory.items():
        relative = Path(filename)
        if relative.is_absolute() or any(part in ('.', '..') for part in relative.parts):
            raise ValueError('External Writer language capture escapes its package')
        if native_roles.bind_input(path.parent / relative)['sha256'] != digest:
            raise ValueError('External Writer language capture bytes changed')
    if native_roles.bind_input(path)['sha256'] != selected:
        raise ValueError('External Writer language snapshot differs')
    native_roles.require_unchanged()
    hashes.pop('page-language', None)
    return hashes


def initial_sealed_writer_snapshot_args(initial_reference, closed_whole, snapshots, providers=None):
    """Keep the established Book route; external language requires sealed absence."""
    result = []
    if (closed_whole is not None or
            (initial_reference is not None and 'figure-page-observations' in (snapshots or {}))):
        result += ['--figure-page-observations-snapshot', str(snapshots['figure-page-observations'])]
    if (initial_reference is not None and
            initial_external_writer_language(snapshots, providers or {})):
        result += ['--page-language-snapshot', str(snapshots['page-language'])]
    return result


def adopt_initial_sealed_workspace(workspace, expected, now_unix, build_identity, dump, reference, native_roles, auxiliary_snapshots=None):
    """Create genuine ordinary initial state for an explicitly selected sealed worker."""
    import extraction_cache as cache
    selected, result, plan, selected_workspace = initial_sealed_generation(reference, native_roles)
    if (workspace.is_relative_to(selected_workspace) or selected_workspace.is_relative_to(workspace)
            or dump is None or str(dump) != selected.get('restored_dump', plan['dump'])['path']
            or build_identity is None or expected.get('source') != build_identity.get('source')
            or native_roles.provenance() != build_identity.get('native_tool_roles')
            or plan['zig_sha256'] != build_identity.get('zig_sha256')
            or expected.get('auxiliary_snapshot_sha256', {}) != build_identity.get('auxiliary_snapshot_sha256', {})
            or expected.get('interwiki_map_sha256') != build_identity.get('interwiki_map_sha256')):
        raise ValueError('Initial sealed generation differs from ordinary inputs or tools')
    root = selected_workspace / 'expander' / '.bundle-expander'
    seal_reference = (selected.get('sitelinks_provider_update',selected.get('file_metadata_provider_update'))['current_seal'] if (selected.get('file_metadata_provider_update') is not None or selected.get('sitelinks_provider_update') is not None) else result['completed_expander_seal'])
    seal = prepared_metadata(seal_reference)
    context_options = {}
    expected_context = seal
    if (selected.get('file_metadata_provider_update') is not None or selected.get('sitelinks_provider_update') is not None):
        if getattr(native_roles,'_closed_native_context',None)!=(root,Path(dump),seal_reference['sha256']):
            raise ValueError('Initial Provider update differs from its authenticated constructor')
        expected_context=getattr(native_roles,'closed_native_origin',None)
        if expected_context is None:raise ValueError('Initial Provider update lacks a closed native origin')
    context_options = initial_sealed_context_options(selected, native_roles,
        root=root, seal_reference=seal_reference, original_dump=plan['dump'])
    if context_options:
        if context_options != getattr(native_roles, '_closed_native_context_options', {}):
            raise ValueError('Initial metadata custody differs from its authenticated constructor')
        expected_context = getattr(native_roles, 'closed_native_origin', None)
        if expected_context is None:
            raise ValueError('Initial metadata custody lacks its closed native origin')
    elif getattr(native_roles, '_closed_native_context_options', {}):
        raise ValueError('Initial metadata custody selection changed')
    require_initial_custody_inputs(context_options, auxiliary_snapshots, build_identity)
    selected_role = native_roles.records['dict-bundle-build']
    dependencies = selected_role['dependencies']
    graph = seal['origin_graph']
    source_root = Path(selected_role['source_root'])
    expected_provenance=('ordinary-sitelinks-provider-update' if selected.get('sitelinks_provider_update') is not None else 'ordinary-file-metadata-provider-update' if (selected.get('file_metadata_provider_update') is not None or selected.get('sitelinks_provider_update') is not None) else 'ordinary-linked-expander')
    if (seal.get('provenance') != expected_provenance
            or not source_root.is_absolute() or source_root.resolve() != source_root
            or any(path.is_symlink() for path in (source_root, *source_root.parents))
            or not source_root.is_dir()
            or graph.get('project_root') not in ('.', str(source_root))):
        raise ValueError('Initial sealed native graph has an unbound project root')
    source_stamp = source_root.stat()
    source_identity = (source_stamp.st_dev, source_stamp.st_ino, source_stamp.st_mode, source_stamp.st_uid)
    # Ordinary default drivers record cache paths relative to their bound
    # working directory. Normalize observations only; retain the exact seal.
    observation_graph = dict(graph, project_root=str(source_root))
    for field, dependency in (('extractor', 'modules'), ('llvm', 'llvm'), ('runtime', 'worker_object'),
                              ('leaf', 'value_leaf_bc'), ('main_c', 'worker_main_c'), ('zig', 'zig')):
        value = graph.get(field)
        if not isinstance(value, str) or not value:
            raise ValueError('Initial sealed native graph differs from selected role')
        path = Path(value)
        if not path.is_absolute():
            if '..' in path.parts:
                raise ValueError('Initial sealed native graph escapes its project root')
            path = source_root / path
        if any(node.is_symlink() for node in (path, *path.parents)):
            raise ValueError('Initial sealed native graph contains a symlink')
        path = Path(os.path.normpath(str(path)))
        if (str(path) != dependencies[dependency]['path']
                or (getattr(native_roles,'closed_native_origin',None) is None
                    and native_roles.bind_input(path) != dependencies[dependency])):
            raise ValueError('Initial sealed native graph differs from selected role')
        observation_graph[field] = str(path)
    providers = seal['identity']['providers']
    worker_hashes = initial_sealed_writer_inputs(expected, build_identity, auxiliary_snapshots, providers, native_roles)
    snapshots = {auxiliary_snapshot_filename(name): digest for name, digest in worker_hashes.items()}
    # Historical preparations used either registry role. The authenticated
    # original command, not hash membership, determines which one was named.
    registry = plan.get('registry')
    arguments = plan.get('expander_args')
    if (not isinstance(registry, dict) or not isinstance(registry.get('path'), str)
            or not registry['path'] or not isinstance(arguments, list)
            or any(not isinstance(value, str) for value in arguments)):
        raise ValueError('Initial sealed registry role is not bound by original arguments')
    registry_roles = []
    for name in ('namespace-registry', 'language-registry'):
        flag = '--' + name + '-snapshot'
        positions = [index for index, value in enumerate(arguments) if value == flag]
        if (len(positions) != 1 or positions[0] + 1 >= len(arguments)
                or not arguments[positions[0] + 1]
                or arguments[positions[0] + 1].startswith('--')
                or any(value.startswith(flag + '=') for value in arguments)):
            raise ValueError('Initial sealed registry role is not bound by original arguments')
        if arguments[positions[0] + 1] == registry['path']:
            registry_roles.append(name)
    if len(registry_roles) != 1:
        raise ValueError('Initial sealed registry role is not bound by original arguments')
    if (registry.get('sha256') != expected.get('auxiliary_snapshot_sha256', {}).get(registry_roles[0])
            or expected.get('registry_sha256') != expected.get('auxiliary_snapshot_sha256', {}).get('language-registry')
            or plan['interwiki']['sha256'] != expected.get('interwiki_map_sha256')):
        raise ValueError('Initial sealed registry or interwiki source differs')
    snapshots.update({'interwiki-map.tsv': expected.get('interwiki_map_sha256'),
                      'wikibase-page-links.tsv': plan['page_links']['sha256'],
                      'page-redirects.tsv': plan['page_redirects']['sha256']})
    snapshots.update(initial_page_language_providers(plan,expected,build_identity,auxiliary_snapshots,providers,native_roles))
    if (any(value is not None and value[1] != snapshots.get(name) for name, value in providers.items())
            or any(name not in providers or providers[name] is None or providers[name][1] != value
                   for name, value in snapshots.items())
            or seal['identity']['verified_input'][0] != plan['dump']['sha256']):
        raise ValueError('Initial sealed snapshot or dump inputs differ')
    # This existing validator authenticates native mode/toolchain/ABI provenance,
    # source/index/sidecars and physical asset inventory without rehashing payloads.
    if (os.path.lexists(root / '.incomplete')
            or cache.frozen_runtime_context(root, dump, seal_reference['sha256'],**context_options) != expected_context):
        raise ValueError('Initial sealed generation is not finalized')
    # A closed, ready generation cannot enter post-link finalization again.
    # Preserve the exact authenticated closed producer without recomputing
    # unused current compiler source; other callers retain their original check.
    closed_origin=getattr(native_roles,'closed_native_origin',None)
    producer=(closed_origin['identity']['producer'] if closed_origin is not None else
              cache.completed_producer_identity(observation_graph)[0])
    after = source_root.stat()
    if (producer != seal['identity']['producer']
            or (after.st_dev, after.st_ino, after.st_mode, after.st_uid) != source_identity):
        raise ValueError('Initial sealed native producer changed')
    native_roles.require_unchanged()
    checked_context = (getattr(native_roles, 'initial_sealed_context', None)
                       or getattr(native_roles, '_closed_native_context', None))
    if closed_origin is not None and checked_context is not None:
        # require_unchanged just replayed the full frozen-context validator and
        # compared its result with this exact origin. Reuse only that same call's
        # pins here; the earlier and final adoption validators remain separate.
        if (checked_context != (root, Path(dump), seal_reference['sha256'])
                or getattr(native_roles, '_closed_native_context_options', {}) != context_options
                or getattr(native_roles, 'closed_native_origin', None) is not closed_origin
                or closed_origin != expected_context):
            raise ValueError('Initial sealed checked context differs from adoption')
    elif cache.frozen_runtime_context(root, dump, seal_reference['sha256'],**context_options) != expected_context:
        raise ValueError('Initial sealed generation is not finalized')
    assets = {name: (size, digest) for name, size, digest in seal['identity']['assets']}
    for key, name in (('worker', 'dict-bundle-expander'), ('metadata', 'lua-program.meta'),
                      ('source_receipt', 'extraction-source.json')):
        if assets.get(name) != (result[key]['bytes'], result[key]['sha256']):
            raise ValueError('Initial sealed output proof differs from native assets')
    state_path = workspace / 'state.json'
    if state_path.is_symlink():
        raise ValueError('Unsafe initial sealed state')
    binding = dict(seal_sha256=seal_reference['sha256'], dump=str(dump), build_inputs=build_identity, retained_expander_root=str(root))
    # Only the expander and the exact required tool copies belong to this
    # preparation. Read-only origins remain outside its owned inventory.
    def inventory():
        found = {}
        directories = [selected_workspace]
        if copied_roles:
            directories.extend((selected_workspace / 'native-blob-tools', selected_workspace / 'native-blob-tools' / 'bin'))
        for path in directories:
            st = path.lstat()
            if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
                raise ValueError('Unsafe initial sealed preparation directory')
            found[str(path)] = (st.st_dev, st.st_ino, st.st_mode, st.st_mtime_ns, st.st_ctime_ns)
        if ({p.name for p in selected_workspace.iterdir()} != ({'expander', 'native-blob-tools'} if copied_roles else {'expander'})
                or (copied_roles and ({p.name for p in (selected_workspace / 'native-blob-tools').iterdir()} != {'bin'}
                    or {p.name for p in (selected_workspace / 'native-blob-tools' / 'bin').iterdir()} != copied_roles))):
            raise ValueError('Initial sealed workspace has partial or unexpected output')
        return found
    raw_path = expected.get('raw_shards_path')
    if raw_path is not None:
        raw_input = Path(raw_path)
        if raw_input.is_relative_to(selected_workspace) or selected_workspace.is_relative_to(raw_input):
            raise ValueError('Ordinary raw shards overlap retained sealed input')
        raw = external_raw_shards(workspace, raw_path)
        if not state_path.exists() and raw.exists() and any(p.name != RAW_SHARD_OWNER for p in raw.iterdir()):
            raise ValueError('Initial sealed adoption has partial raw shards')
    if set(result['installed_tools']) != set(BLOB_TOOL_NAMES):
        raise ValueError('Initial sealed installed role inventory differs')
    # The closed result names each Blob tool. The original role map binds its
    # read-only origin; writable origins require the exact owned install copy.
    original_roles = prepared_metadata(plan['roles'])
    installed_tools, copied_roles = {}, set()
    for name in RETAINED_NATIVE_ROLE_NAMES:
        expected_artifact = original_roles[name]['artifact']
        private_path = selected_workspace / 'native-blob-tools' / 'bin' / name
        descriptor = result['installed_tools'].get(name)
        if descriptor is None:
            # Older closed all-copied preparations omit the Driver descriptor.
            # Preserve that exact legacy copy, not arbitrary extra tool paths.
            legacy_copy = copied_roles == set(BLOB_TOOL_NAMES) and os.path.lexists(private_path)
            path = private_path if expected_artifact['mode'] != 0o555 or legacy_copy else Path(expected_artifact['path'])
            descriptor = dict(expected_artifact, path=str(path))
        if any(descriptor[k] != expected_artifact[k] for k in ('bytes', 'sha256')):
            raise ValueError('Initial sealed installed role differs')
        if descriptor['path'] == str(private_path):
            copied_roles.add(name)
        elif descriptor['path'] != expected_artifact['path'] or expected_artifact['mode'] != 0o555:
            raise ValueError('Initial sealed installed role differs')
        installed_tools[name] = descriptor
    before = inventory()
    for descriptor in installed_tools.values():
        actual = native_roles.bind_input(Path(descriptor['path']))
        if any(actual[k] != descriptor[k] for k in ('path', 'bytes', 'sha256')) or actual['mode'] != 0o555:
            raise ValueError('Initial sealed installed role bytes or mode changed')
    native_roles.require_unchanged()
    prepared_metadata(reference); prepared_metadata(selected['preparation_result']); prepared_metadata(selected['preparation_closure'])
    if inventory() != before or cache.frozen_runtime_context(root, dump, seal_reference['sha256'],**context_options) != expected_context:
        raise ValueError('Initial sealed workspace changed during adoption')
    native_roles.initial_sealed_context = (root, Path(dump), seal_reference['sha256'])
    if os.path.lexists(state_path):
        state = read_build_envelope(state_path)
        epoch = state.get('now_unix')
        validate_now_unix(epoch)
        if (epoch is None or now_unix not in (None, epoch)
                or state != dict(expected, now_unix=epoch, native_generation=binding)):
            raise ValueError('Initial sealed ordinary state differs')
        return epoch
    if workspace.exists():
        if workspace.is_symlink() or not workspace.is_dir() or any(workspace.iterdir()):
            raise ValueError('Initial sealed adoption has partial ordinary workspace')
    else:
        workspace.mkdir(parents=True, mode=0o700)
    epoch = now_unix if now_unix is not None else int(time.time())
    state = dict(expected, now_unix=epoch, native_generation=binding)
    temporary = state_path.with_suffix('.part')
    if os.path.lexists(temporary):
        raise ValueError('Unexpected initial sealed state transaction')
    try:
        with temporary.open('x') as stream:
            stream.write(build_envelope_text(state))
        # Publish without replacing a concurrent state or following a symlink.
        os.link(temporary, state_path)
    finally:
        temporary.unlink(missing_ok=True)
    return epoch


def closed_whole_worker_inputs(value, *, state=False):
    """Keep sealed worker inputs exact; Book and replay observations belong to Writer."""
    result=writer_figure_worker_inputs(value,state=state)
    for field in ('auxiliary_snapshot_sha256','auxiliary_capture_sha256','auxiliary_capture_artifact_sha256'):
        result[field].pop('figure-page-observations',None)
    if state:result.pop('raw_shards_path',None)
    return result


def adopt_closed_whole_workspace(workspace,expected,now_unix,build_identity,dump,reference,native_roles):
    """Bind a fresh ordinary output to an authenticated failed-whole worker."""
    import copy
    if (native_roles is None or native_roles.closed_whole_execution!=reference
            or native_roles.initial_sealed_generation is not None
            or native_roles.closed_native_origin is None
            or getattr(native_roles,'_closed_whole_workspace_state',None)is None):
        raise ValueError('Closed whole adoption lacks its original history')
    original_context=native_roles._closed_native_context
    if native_roles.initial_sealed_context not in (None,original_context):
        raise ValueError('Closed whole adoption selected a different sealed worker')
    root,original_dump,seal_sha=original_context
    original=native_roles._closed_whole_workspace_state
    old_workspace=root.parent.parent
    # provenance() verifies the selected seal, loader and tool identities together.
    if (Path(dump)!=original_dump or workspace==old_workspace
            or workspace.is_relative_to(old_workspace) or old_workspace.is_relative_to(workspace)
            or build_identity is None or expected.get('source')!=build_identity.get('source')
            or native_roles.provenance()!=build_identity.get('native_tool_roles')
            or expected.get('edition')!=original.get('edition') or expected.get('date')!=original.get('date')
            or now_unix!=original.get('now_unix')
            or closed_whole_worker_inputs(expected,state=True)!=closed_whole_worker_inputs(original,state=True)
            or closed_whole_worker_inputs(build_identity)!=closed_whole_worker_inputs(original['native_generation']['build_inputs'])):
        raise ValueError('Closed whole adoption changed worker inputs, source, root or epoch')
    state_path=workspace/'state.json'
    binding=dict(seal_sha256=seal_sha,dump=str(dump),build_inputs=copy.deepcopy(build_identity),
                 retained_expander_root=str(root),closed_whole_execution=copy.deepcopy(reference))
    desired=dict(expected,now_unix=now_unix,native_generation=binding)
    if os.path.lexists(state_path):
        if state_path.is_symlink() or read_build_envelope(state_path)!=desired:
            raise ValueError('Closed whole ordinary state differs')
    else:
        if workspace.exists():
            if workspace.is_symlink() or not workspace.is_dir() or any(workspace.iterdir()):
                raise ValueError('Closed whole adoption has partial ordinary workspace')
        else:workspace.mkdir(parents=True,mode=0o700)
        raw_path=expected.get('raw_shards_path')
        if raw_path is not None:
            raw=external_raw_shards(workspace,raw_path)
            if raw.exists() and any(path.name!=RAW_SHARD_OWNER for path in raw.iterdir()):
                raise ValueError('Closed whole adoption has partial raw output')
        temporary=state_path.with_suffix('.part')
        if os.path.lexists(temporary):raise ValueError('Unexpected closed whole state transaction')
        prepared_metadata(reference)
        native_roles.require_unchanged()
        try:
            with temporary.open('x')as stream:stream.write(build_envelope_text(desired))
            os.link(temporary,state_path)
        finally:temporary.unlink(missing_ok=True)
    native_roles.require_unchanged()
    native_roles.initial_sealed_context=original_context
    return now_unix


def prepare_shard_workspace(workspace, expected, now_unix=None, raw_shards_path=None, *, provider_update=None, build_identity=None, dump=None, sealed_recovery=None, native_roles=None, writer_figure_transition=None, initial_generation=None, auxiliary_snapshots=None, closed_whole_execution=None):
    expected=dict(expected)
    if 'raw_shards_path' in expected: raise ValueError('Raw shard path must be supplied explicitly')
    artifact_path(workspace)
    selected=str(Path(raw_shards_path).absolute()) if raw_shards_path is not None else None
    if selected is not None: expected['raw_shards_path']=selected
    embedded=expected.pop('now_unix',None)
    if now_unix is None: now_unix=embedded
    elif embedded is not None and embedded!=now_unix: raise ValueError('Conflicting build timestamps')
    validate_now_unix(now_unix)
    expected_comparable=shard_cache_identity(expected)
    generation=getattr(_PREPARED_SOURCE,'value',None)
    if generation is not None:
        generation.require_unchanged(full_context=False)
        original=generation.record['workspace_state']
        if (workspace!=generation.workspace or expected_comparable!=shard_cache_identity(original)
                or now_unix not in (None,generation.record['now_unix'])):
            raise ValueError('Own-cap retry requires the exact original prepared workspace and epoch')
        return generation.record['now_unix']
    if workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
    if closed_whole_execution is not None:
        if any(value is not None for value in (initial_generation,sealed_recovery,writer_figure_transition)):
            raise ValueError('Closed whole adoption cannot borrow another transition')
        return adopt_closed_whole_workspace(workspace,expected,now_unix,build_identity,dump,closed_whole_execution,native_roles)
    if initial_generation is not None:
        if sealed_recovery is not None or writer_figure_transition is not None:
            raise ValueError('Initial sealed adoption cannot borrow another transition')
        return adopt_initial_sealed_workspace(workspace, expected, now_unix, build_identity, dump, initial_generation, native_roles, auxiliary_snapshots)
    if writer_figure_transition is not None:
        if sealed_recovery is not None or generation is not None:
            raise ValueError('Writer Figure transition requires an ordinary completed worker')
        return writer_figure_adopt_workspace(workspace, expected, now_unix, build_identity, dump, writer_figure_transition, native_roles)
    existing=None
    state_path=workspace/'state.json'
    if state_path.is_symlink(): raise ValueError(f'Unsafe shard state: {state_path}')
    if state_path.is_file():
        try: existing=read_build_envelope(state_path)
        except (OSError,json.JSONDecodeError): existing=None
        if isinstance(existing,dict) and existing.get('version')==2 and expected.get('version')==SHARD_STATE_VERSION:
            raise ValueError('Legacy shard source identity requires a new workspace; existing output preserved')
        comparable=shard_cache_identity(existing) if isinstance(existing,dict) else None
        if isinstance(existing,dict) and existing.get('raw_shards_path')!=selected:
            previous=existing.get('raw_shards_path')
            unchanged={k:v for k,v in comparable.items() if k!='raw_shards_path'}=={k:v for k,v in expected_comparable.items() if k!='raw_shards_path'}
            if previous is not None or unchanged:
                raise ValueError('Raw shard location differs from resumable workspace; preserve it or choose a new workspace')
        if comparable==expected_comparable and type(existing.get('now_unix')) is int and 0<existing['now_unix']<=(1<<63)-1 and (now_unix is None or existing['now_unix']==now_unix):
            if sealed_recovery is not None:
                proof=prepared_metadata(sealed_recovery)
                if (proof['current_state']!=expected or proof['current_build_identity']!=build_identity
                        or existing.get('native_generation')!=dict(seal_sha256=proof['seal']['sha256'],
                            dump=str(dump),build_inputs=build_identity)):
                    raise ValueError('Adopted sealed recovery identity changed')
                prepared_metadata(proof['original_state']);prepared_metadata(proof['seal'])
                native_roles.require_unchanged()
                if native_roles.provenance()!=build_identity['native_tool_roles']:
                    raise ValueError('Adopted sealed recovery native selection changed')
            if selected is not None: external_raw_shards(workspace,selected,create=True)
            return existing['now_unix']
    if sealed_recovery is not None:
        return recover_sealed_workspace(workspace, expected, now_unix, build_identity, dump, sealed_recovery, native_roles)
    if (provider_update is not None and existing is not None and
            wikibase_provider_only_change(comparable, expected_comparable)):
        binding=existing.get('native_generation')
        if (isinstance(binding,dict) and set(binding)=={'seal_sha256','dump','build_inputs'} and
                dump is not None and binding['dump']==str(dump) and
                wikibase_provider_only_change(binding['build_inputs'],build_identity)):
            import extraction_cache as native_cache
            root=workspace/'expander'/'.bundle-expander'
            proof=native_cache.prepare_wikibase_provider_update(root,Path(dump),binding['seal_sha256'])
            if proof is not None:
                # No worker is admitted inside the edition-locked reset. A
                # crash leaves an unready generation that ordinary build replaces.
                with (root/'.incomplete').open('xb') as marker:
                    marker.write(native_cache.PROVIDER_UPDATE_MARKER)
                provider_update.update(proof)
    if workspace.exists():
        if not workspace.is_dir() or workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
        cache=workspace/'input'
        if cache.is_symlink(): raise ValueError(f'Unsafe cached dump path: {cache}')
        if selected is not None:
            raw=external_raw_shards(workspace,selected,create=True)
            cleanup_dead_private_shards(raw)
            remove_artifact_tree(raw)
        # Compiler/registry changes invalidate the expander and shards, but
        # the verified compressed XML repack has independent inputs.
        for child in workspace.iterdir():
            if child.name=='input' and child.is_dir(): continue
            if provider_update and child.name=='expander': continue
            if child.is_dir() and not child.is_symlink(): remove_artifact_tree(child)
            else: unlink_artifact(child)
    else:
        workspace.mkdir(parents=True)
    if selected is not None: external_raw_shards(workspace,selected,create=True)
    now_unix=now_unix if now_unix is not None else int(time.time())
    state=dict(expected,now_unix=now_unix)
    temp=state_path.with_suffix('.part')
    temp.write_text(build_envelope_text(state))
    os.replace(temp,state_path)
    return now_unix


def validated_staged_dump(items, cache):
    """Authenticate an existing repack; never create, repair or retire it."""
    cache=Path(cache)
    paths=[cache/name for name in ('pages.xml.zst','pages-index.txt.bz2','.complete.json')]
    if cache.is_symlink() or not cache.is_dir() or any(p.is_symlink() for p in paths):
        raise ValueError('Unsafe staged input root')
    def stamp(path):
        info=path.lstat()
        if not stat.S_ISREG(info.st_mode):raise ValueError('Staged input is not a regular file')
        return (info.st_dev,info.st_ino,info.st_mode,info.st_size,info.st_mtime_ns,info.st_ctime_ns)
    before={path:stamp(path) for path in paths}
    dump,index,marker=paths
    record=read_small_json(marker)
    valid=isinstance(record,dict) and record.get('version')==DUMP_STAGING_VERSION and record.get('input_sha256')==dump_input_fingerprint(items)
    valid=valid and record.get('dump_codec')=='zstd' and record.get('dump_stream_kind')=='multistream-zstd'
    valid=valid and type(record.get('source_pages')) is int and record['source_pages']>=0
    for label,path in (('dump',dump),('index',index)):
        valid=valid and type(record.get(label+'_size')) is int and record[label+'_size']>0
        valid=valid and before[path][3]==record[label+'_size']
        valid=valid and sha256_file(path)==record.get(label+'_sha256')
    if not valid or before!={path:stamp(path) for path in paths}:
        raise ValueError('Staged input identity or bytes differ')
    return record,before


def selected_staged_input_root(items, root, output, raw_shard_root=None, extraction_cache_root=None):
    # Cheap ownership preflight runs before build() creates even its lock path.
    if root is None:return None
    root=Path(root).absolute()
    if root.resolve(strict=True)!=root or any(p.is_symlink() for p in (root,*root.parents)):
        raise ValueError('Borrowed staged input must be a direct existing directory')
    edition,date=phase_identity(items)
    parent=Path(output).absolute()/edition
    protected=[parent/date,parent/(date+'.building'),parent/(date+'.shards')]
    state=parent/(date+'.shards')/'state.json'
    if state.is_symlink():raise ValueError('Unsafe recorded shard owner')
    if state.is_file():
        recorded=read_build_envelope(state)
        raw=recorded.get('raw_shards_path') if isinstance(recorded,dict) else None
        if raw is not None:
            if not isinstance(raw,str):raise ValueError('Invalid recorded raw shard owner')
            protected.append(Path(raw).absolute())
    if raw_shard_root is not None:protected.append(Path(raw_shard_root).absolute())
    if extraction_cache_root is not None:protected.append(Path(extraction_cache_root).absolute())
    protected=[variant for path in protected for variant in (path,path.resolve())]
    if any(root.is_relative_to(p) or p.is_relative_to(root) for p in protected):
        raise ValueError('Borrowed staged input overlaps owned build paths')
    return root


@contextmanager
def borrowed_staged_input(items, root, output, raw_shard_root=None, extraction_cache_root=None):
    """Hold a selected external input read-only across success and failure."""
    root=selected_staged_input_root(items,root,output,raw_shard_root,extraction_cache_root)
    if root is None:
        yield None,None
        return
    _,before=validated_staged_dump([item for item in items if '.xml' in item['name']],root)
    def check():
        for path,expected in before.items():
            info=path.lstat()
            actual=(info.st_dev,info.st_ino,info.st_mode,info.st_size,info.st_mtime_ns,info.st_ctime_ns)
            if path.is_symlink() or actual!=expected or root.resolve(strict=True)!=root:
                raise ValueError('Borrowed staged input changed during build')
    try:
        yield root,check
    finally:
        # If build execution also failed, Python retains that original exception
        # as __context__; never replace its diagnostic files or process receipt.
        check()


def cached_shard_dump(items, downloads, workspace):
    """Reuse only a completed, content-verified repack for these XML inputs."""
    edition,date=phase_identity(items)
    cache=workspace/'input'
    dump=cache/'pages.xml.zst'
    index=cache/'pages-index.txt.bz2'
    marker=cache/'.complete.json'
    with build_phase(edition,date,'cache_verification') as result:
        if cache.is_symlink(): raise ValueError(f'Unsafe cached dump path: {cache}')
        input_hash=dump_input_fingerprint(items)
        if cache.is_dir() and not any(path.is_symlink() for path in (dump,index,marker)):
            try:
                record,_=validated_staged_dump(items,cache)
                valid=True
                if valid:
                    result['cache_hit']=True
                    result['compressed_bytes']=record['dump_size']
                    print(f'Reusing verified staged dump: {dump}',flush=True)
                    return dump
            except (OSError,ValueError,json.JSONDecodeError):
                pass
        result['cache_hit']=False
    if cache.exists():
        if not cache.is_dir(): raise ValueError(f'Unsafe cached dump path: {cache}')
        remove_artifact_tree(cache)
    cache.mkdir()
    metadata={}
    stage_seekable_dump(items,downloads,cache,metadata)
    record=dict(metadata,version=DUMP_STAGING_VERSION,input_sha256=input_hash)
    temp=marker.with_suffix('.part')
    temp.write_text(json.dumps(record,sort_keys=True)+'\n')
    os.replace(temp,marker)
    return dump


def expander_ready(root, auxiliary_hashes=None, interwiki_sha=None, page_links_sha=None, page_redirects_sha=None):
    marker=root/'.incomplete'
    expander=root/'.bundle-expander'
    try: ready=marker.read_text()=='expander ready'
    except OSError: return False
    if not (ready and not (expander/'.incomplete').exists() and (expander/'page-index.tsv').is_file() and (expander/'dict-bundle-expander').is_file() and (expander/'namespace-registry.tsv').is_file()):return False
    try:
        if interwiki_sha is not None and sha256_file(expander/'interwiki-map.tsv')!=interwiki_sha:return False
        if interwiki_sha is None and (expander/'interwiki-map.tsv').exists():return False
        if page_links_sha is not None and sha256_file(expander/'wikibase-page-links.tsv')!=page_links_sha:return False
        if page_links_sha is None and 'wikibase-page-links' not in (auxiliary_hashes or {}) and (expander/'wikibase-page-links.tsv').exists():return False
        if page_redirects_sha is not None and sha256_file(expander/'page-redirects.tsv')!=page_redirects_sha:return False
        if page_redirects_sha is None and (expander/'page-redirects.tsv').exists():return False
        return all(sha256_file(expander/(auxiliary_snapshot_filename(name)))==digest for name,digest in (auxiliary_hashes or {}).items()
                   if name!='wikibase-page-links' or page_links_sha is None)
    except OSError:return False


def run_checked(command):
    subprocess.run(command,cwd=PROJECT,check=True)


def phase_event(edition, date, name, event, **fields):
    try:
        record=dict(edition=edition,date=date,phase=name,event=event,**fields)
        print('BUILD_PHASE '+json.dumps(record,sort_keys=True,separators=(',',':')),flush=True)
    except Exception:
        # Observability must never change the result of a build stage.
        pass


@contextmanager
def build_phase(edition, date, name, **fields):
    started=time.monotonic()
    # Inclusive CPU of this process (all its threads), excluding child processes.
    try: cpu_started=time.process_time()
    except Exception: cpu_started=None
    phase_event(edition,date,name,'start',**fields)
    result=dict(fields)
    status='failure'
    try:
        yield result
        status='success'
    finally:
        cpu_fields={}
        if cpu_started is not None:
            try: cpu_fields['self_cpu_seconds']=round(time.process_time()-cpu_started,6)
            except Exception: pass  # Optional timing cannot replace the stage result.
        phase_event(edition,date,name,'end',status=status,seconds=round(time.monotonic()-started,3),**(result|cpu_fields))


def timed_run(command, edition, date, phase, *, native_working_directory=None, **fields):
    if native_working_directory is not None:
        fields=dict(fields,native_working_directory=str(native_working_directory))
    with build_phase(edition,date,phase,**fields):
        if native_working_directory is None:run_checked(command)
        else:subprocess.run(command,cwd=native_working_directory,check=True)


BLOB_TOOL_NAMES = ('dict-blob-build', 'dict-blob-merge', 'dict-blob-verify')


def require_native_tool_directory(prefix):
    for path in (prefix/'bin',prefix,*prefix.parents):
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise ValueError('Invalid native blob tool installation directory: '+str(path))


def require_private_native_tool(path):
    info=path.lstat()
    if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111 or info.st_nlink!=1:
        raise ValueError('Native blob tool must be a private regular executable: '+str(path))
    return info


def native_tool_stamp(path):
    for parent in (path.parent, *path.parent.parents):
        if parent.is_symlink():
            raise ValueError('Prepared native tool parent is a symlink: '+str(parent))
    info=path.lstat()
    if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111 or info.st_mode & 0o222:
        raise ValueError('Prepared native tool is not a read-only executable: '+str(path))
    return (info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns,info.st_mode)


def figure_compatibility_paths(snapshots):
    snapshots=snapshots or {}
    if not set(FIGURE_SNAPSHOT_FILES).intersection(snapshots):return None
    require_figure_inputs(snapshots,required=True)
    names=('namespace-registry',*FIGURE_SNAPSHOT_FILES)
    if any(name not in snapshots for name in names):
        raise ValueError('Figure compatibility requires the selected namespace input')
    paths=tuple(Path(snapshots[name]) for name in names)
    if any(not path.is_absolute() for path in paths):
        raise ValueError('Figure compatibility requires absolute selected paths')
    return paths


def check_figure_compatibility(tool, paths, edition, date):
    if paths is None:return
    if len(paths)!=5:raise ValueError('Incomplete Figure compatibility input tuple')
    def identities():
        values=[]
        for path in paths:
            path=Path(path)
            info=path.lstat()
            if not path.is_absolute() or not stat.S_ISREG(info.st_mode):
                raise ValueError('Unsafe Figure compatibility input')
            values.append((info.st_dev,info.st_ino,info.st_mode,info.st_size,info.st_mtime_ns,info.st_ctime_ns))
        return tuple(values)
    before=identities()
    # This is the selected Writer's bounded capability check, not acceptance of
    # file records or batch bodies. Ordinary Writer replay remains mandatory.
    tool.run(['--check-figure-compatibility',*(str(path) for path in paths)],
        edition,date,'figure_input_compatibility',compatibility_only=True,full_input_validation=False)
    if identities()!=before:raise ValueError('Figure compatibility inputs changed during check')


class PreparedBlobTool:
    def __init__(self, path):
        self.path=path
        self.stamp=native_tool_stamp(path)
        self.runtime_identity=None
        if getattr(_PREPARED_SOURCE,'request',None) is not None:
            import extraction_cache as cache
            self.runtime_identity=cache.tool_identity(path)
            self.sha256=self.runtime_identity['extractor_sha256']
        else:
            self.sha256=sha256_file(path)
        self.require_unchanged()

    def require_unchanged(self):
        if native_tool_stamp(self.path)!=self.stamp:
            raise ValueError('Prepared native tool changed: '+str(self.path))

    def command(self, args):
        retained=getattr(self,'retained_roles',None)
        if retained is not None:
            retained.require_unchanged()
            retained.require_command(self.path.name, args)
        self.require_unchanged()
        return [str(self.path),*args]

    def run(self, args, edition, date, phase, **fields):
        generation=getattr(_PREPARED_SOURCE,'value',None)
        if generation is not None:
            generation.require_unchanged(full_context=False)
            if generation.tools.get(self.path.name) is not self:
                raise ValueError('Native command does not use the authorized prepared tool')
        command=self.command(args)
        if 'native_working_directory' in fields:
            raise ValueError('Selected native working directory cannot be overridden')
        working_directory=getattr(self,'native_working_directory',None)
        if working_directory is not None:
            fields=dict(fields,native_working_directory=working_directory)
        try:
            timed_run(command,edition,date,phase,**fields)
        finally:
            self.require_unchanged()
            if generation is not None:generation.require_unchanged(full_context=False)
            retained=getattr(self,'retained_roles',None)
            if retained is not None:retained.require_unchanged()


RETAINED_NATIVE_ROLE_NAMES = (*BLOB_TOOL_NAMES, 'dict-bundle-build')
RETAINED_EXPANDER_ABI_PATHS = (
    'src/lua/abi/globals.zig', 'src/lua/abi/static_fields.zig',
    'src/lua/runtime/llvm_abi.zig', 'src/lua/runtime/static_literal_format.zig',
    'src/lua/program_metadata.zig')
RETAINED_NATIVE_ABI_PATHS = (
    'src/encoder/blob_format.zig', 'src/encoder/blob_catalog.zig',
    'src/encoder/presentation_codec.zig', 'src/encoder/presentation_types.zig',
    'src/lua/bundle_protocol.zig', 'src/ffi/dict.h',
    'src/lua/runtime/value_leaf.zig', *RETAINED_EXPANDER_ABI_PATHS)
# Existing extraction_cache ABI_FILES, LIVE_LEAF_SOURCE_PATHS and completed
# producer policy. These are actually read at build time, unlike Writer source.
# These are process interfaces, not replacements for each artifact's complete
# authenticated compilation projection. The merger copies opaque payloads;
# the retained bundle driver is restricted to expander-only commands.
RETAINED_NATIVE_ROLE_ABI_INTERFACES = (
    ('blob-envelope', ('dict-blob-build', 'dict-blob-merge', 'dict-blob-verify'),
     ('src/encoder/blob_format.zig', 'src/encoder/blob_catalog.zig')),
    ('presentation-wire', ('dict-blob-build', 'dict-blob-verify'),
     ('src/encoder/presentation_codec.zig', 'src/encoder/presentation_types.zig')),
    # The Writer communicates with the selected worker through this wire
    # protocol. Blob tools never execute or import the worker's Lua C ABI.
    # Each role still authenticates its complete original source projection;
    # the driver separately binds its own live ABI and paired runtime inputs.
    ('expansion-wire', ('dict-blob-build', 'dict-bundle-build'),
     ('src/lua/bundle_protocol.zig',)),
)
RETAINED_BUNDLE_RUNTIME_SOURCES = (
    *RETAINED_EXPANDER_ABI_PATHS, 'src/lua/value_leaf_build.zig',
    'src/lua/runtime/value_leaf.zig', 'build.zig', 'tools/bundle_build.zig',
    'tools/extraction_cache.py')
RETAINED_BUNDLE_DEPENDENCIES = frozenset((
    'pipeline_paths', 'modules', 'llvm', 'worker_object', 'value_leaf_bc',
    'worker_main_c', 'zig', 'clang', 'extraction_helper'))


class RetainedNativeToolRoles:
    """Select caller-qualified roles, retaining their original source authority.

    This is a tool-selection boundary, not a qualification assessor. The caller
    must join its existing qualification and observed command/dependency proof.
    No receipt status or new schema is invented here. Original compilation
    payloads are authenticated from retained bytes/Git on ordinary paths. An
    exact closed initial generation retains those authenticated source facts
    without rereading unused compiler payloads; execution dependencies stay guarded.
    """
    def __init__(self, roles, *, zig_sha256):
        import copy
        if set(roles) != set(RETAINED_NATIVE_ROLE_NAMES):
            raise ValueError('Incomplete retained native tool roles')
        self.records = copy.deepcopy(roles)
        self.initial_sealed_context = None
        self.initial_sealed_generation = self.records['dict-bundle-build'].pop('initial_sealed_generation', None)
        self.closed_whole_execution = self.records['dict-bundle-build'].pop('closed_whole_execution', None)
        self._closed_native_context_options = {}
        self.sealed_expander_recovery = self.records['dict-bundle-build'].pop('sealed_expander_recovery', None)
        self.writer_figure_transition = self.records['dict-blob-build'].pop('writer_figure_transition', None)
        if self.writer_figure_transition is not None and self.sealed_expander_recovery is not None:
            raise ValueError('Writer observation and pre-blob recovery transitions are distinct')
        if self.initial_sealed_generation is not None and (self.sealed_expander_recovery is not None or self.writer_figure_transition is not None):
            raise ValueError('Initial sealed adoption requires its own selection')
        if self.closed_whole_execution is not None and any(value is not None for value in (self.initial_sealed_generation,self.sealed_expander_recovery,self.writer_figure_transition)):
            raise ValueError('Closed whole execution requires its own selection')
        self.tools, self.inputs, self.input_identities, self.directories = {}, {}, {}, {}
        self.zig_sha256 = zig_sha256
        self.compilation_payloads = {}
        self.closed_native_origin=(self.closed_whole_origin() if self.closed_whole_execution is not None else
                                   self.closed_execution_origin() if self.initial_sealed_generation is not None else None)
        shared_interfaces, shared_runtime = {}, None
        for role, row in self.records.items():
            artifact = row['artifact']
            path = Path(artifact['path'])
            if path.name != role or not path.is_absolute():
                raise ValueError('Retained native tool has the wrong role')
            if row['zig_sha256'] != zig_sha256:
                raise ValueError('Retained native tool compiler differs')
            source = prepared_metadata(row['source'])
            inventory = source.get('files', source)
            compiled = retained_compilation_source(row, self)
            compilation_reference = row['source'] if compiled == source else row['compiled_source_authority']
            fingerprint = compiled.get('fingerprint', compilation_reference['sha256'])
            if fingerprint != row['producer_source']:
                raise ValueError('Retained native tool source authority differs')
            root = Path(row['source_root'])
            if not root.is_absolute() or root.resolve() != root:
                raise ValueError('Unsafe retained native source root')
            if self.initial_sealed_generation is None:
                st=root.stat()
                self.directories[root]=(st.st_dev,st.st_ino,st.st_mode,st.st_uid)
            required = {*RETAINED_NATIVE_ABI_PATHS, {
                'dict-blob-build': 'tools/blob_build.zig',
                'dict-blob-merge': 'tools/blob_merge.zig',
                'dict-blob-verify': 'tools/blob_verify.zig',
                'dict-bundle-build': 'tools/bundle_build.zig'}[role]}
            projection = row['source_paths']
            if (not isinstance(projection, list) or len(set(projection)) != len(projection)
                    or not required <= set(projection)):
                raise ValueError('Retained native role lacks its source/ABI projection')
            payloads=row.get('source_payload_files',{})
            if not isinstance(payloads,dict) or not set(payloads)<=set(projection):
                raise ValueError('Retained source payload mapping differs from projection')
            payload_paths=[value.get('path') for value in payloads.values() if isinstance(value,dict)]
            if (len(payload_paths)!=len(payloads) or any(not isinstance(path,str) for path in payload_paths)
                    or len(set(payload_paths))!=len(payload_paths)):
                raise ValueError('Duplicate or unbound retained source payload')
            for relative in projection:
                if (not isinstance(relative, str) or Path(relative).is_absolute()
                        or '..' in Path(relative).parts or relative not in inventory):
                    raise ValueError('Unsafe retained native source projection')
                expected = inventory[relative]
                identity = (dict(expected,mode=source.get('modes',{}).get(relative,expected.get('mode',0o644)))
                            if self.initial_sealed_generation is not None else self.compilation_identity(row, relative))
                if (identity['bytes'] != expected['bytes'] or identity['sha256'] != expected['sha256']
                        or ('mode' in expected and identity['mode'] != expected['mode'])
                        or ('modes' in source and identity['mode'] != source['modes'][relative])):
                    raise ValueError('Retained native role source/ABI changed: '+relative)
            for interface, members, names in RETAINED_NATIVE_ROLE_ABI_INTERFACES:
                if role not in members:
                    continue
                identity = {name: (inventory[name]['bytes'], inventory[name]['sha256']) for name in names}
                if interface in shared_interfaces and identity != shared_interfaces[interface]:
                    raise ValueError('Retained roles have incompatible '+interface+' ABI sources')
                shared_interfaces[interface] = identity
            dependencies = row['dependencies']
            if not isinstance(dependencies, dict) or not {'zig', 'worker_object', 'value_leaf_bc', 'worker_main_c'} <= set(dependencies):
                raise ValueError('Retained native role compiler dependency missing')
            if role == 'dict-bundle-build' and not (RETAINED_BUNDLE_DEPENDENCIES |
                    {'runtime_source:'+name for name in RETAINED_BUNDLE_RUNTIME_SOURCES}) <= set(dependencies):
                raise ValueError('Retained bundle role lacks observed pipeline dependencies')
            for name, descriptor in dependencies.items():
                if name.startswith('runtime_source:'):
                    relative=name.removeprefix('runtime_source:')
                    if role!='dict-bundle-build' or relative not in RETAINED_BUNDLE_RUNTIME_SOURCES or descriptor['path']!=str(root/relative):
                        raise ValueError('Retained runtime source path differs')
                    if relative in RETAINED_EXPANDER_ABI_PATHS and descriptor['sha256']!=inventory[relative]['sha256']:
                        raise ValueError('Retained live runtime ABI differs from compiled authority')
                if not self.execution_dependency(name):continue
                if self.initial_sealed_generation is not None and name == 'extraction_helper':
                    import extraction_cache as cache
                    if Path(cache.__file__).absolute() != Path(descriptor['path']):
                        raise ValueError('Initial sealed imported extraction helper differs')
                actual = self.bind_input(Path(descriptor['path']))
                if actual != descriptor:
                    raise ValueError('Retained native dependency differs: '+name)
                if name == 'zig' and descriptor['sha256'] != zig_sha256:
                    raise ValueError('Retained native compiler bytes differ')
            runtime = {name: (dependencies[name]['bytes'], dependencies[name]['sha256'])
                       for name in ('worker_object', 'value_leaf_bc', 'worker_main_c')}
            if shared_runtime is not None and runtime != shared_runtime:
                raise ValueError('Retained roles have incompatible runtime leaf dependencies')
            shared_runtime = runtime
            # Bind the old inventory descriptor as well as the source projection.
            source_identity = self.bind_input(Path(row['source']['path']))
            if (source_identity['bytes'] != row['source']['bytes'] or
                    source_identity['sha256'] != row['source']['sha256']):
                raise ValueError('Retained native source metadata changed')
            actual = self.bind_input(path)
            if actual != artifact or not actual['mode'] & 0o111:
                raise ValueError('Retained native artifact bytes or mode differ')
            self.tools[role] = (None if self.closed_whole_execution is not None and role=='dict-bundle-build' else
                                self.bind_tool(role,path) if not actual['mode'] & 0o222 else None)
        if self.initial_sealed_generation is not None:
            initial_sealed_generation(self.initial_sealed_generation, self)
            self.bind_input(Path(self.initial_sealed_generation['path']))
        if self.sealed_expander_recovery is not None:
            prepared_metadata(self.sealed_expander_recovery)
            self.bind_input(Path(self.sealed_expander_recovery['path']))
        if self.writer_figure_transition is not None:
            prepared_metadata(self.writer_figure_transition)
            self.bind_input(Path(self.writer_figure_transition['path']))
        self.require_unchanged()

    @staticmethod
    def closed_input_identity(path):
        """Current physical custody for a named ordinary input, including aliases."""
        path=Path(path)
        if not os.path.lexists(path):return None
        st=path.stat()
        route=[]
        for part in reversed((path,*path.parents)):
            observed=part.lstat()
            route.append([str(part),observed.st_dev,observed.st_ino,observed.st_mode,
                          observed.st_ctime_ns if part.is_symlink() else None,os.readlink(part) if part.is_symlink() else None])
        return dict(stamp=[st.st_dev,st.st_ino,st.st_mode,st.st_size,st.st_mtime_ns,st.st_ctime_ns,st.st_nlink],route=route)

    def closed_whole_origin(self):
        """Execute a closed worker; its failed whole attempt remains a failure."""
        import copy
        import extraction_cache as cache
        def auth(descriptor):
            if not isinstance(descriptor,dict) or set(descriptor)not in ({'path','bytes','sha256'},{'path','bytes','sha256','mode'}):
                raise ValueError('Invalid closed whole authority descriptor')
            path=Path(descriptor['path']);actual=self.bind_input(path)
            if 'mode'in descriptor and actual['mode']!=descriptor['mode']:
                raise ValueError('Closed whole authority mode changed')
            if any(actual[key]!=descriptor[key]for key in ('path','bytes','sha256')):
                raise ValueError('Closed whole authority changed')
            return path
        def metadata(descriptor):return json.loads(auth(descriptor).read_text())
        selected=metadata(self.closed_whole_execution)
        required={'ordinary_input','roles','execution_python','live_helper_application','input_stamps'}
        if not required<=set(selected)<=required|{'workspace_state'}:
            raise ValueError('Invalid closed whole execution selection')
        plan=metadata(selected['ordinary_input']);h=metadata(plan['normal_handoff'])
        if self.records!=metadata(selected['roles']):
            raise ValueError('Closed whole role selection changed')
        whole=plan.get('closed_whole_authority')
        if not isinstance(whole,dict) or plan.get('file_metadata_provider_update') is not None:
            raise ValueError('Closed whole execution requires its original failed whole authority')
        # Reuse the ordinary failed-whole lineage joins; no zero-page receipt is created.
        if not set(whole) == {'configuration', 'closure', 'attempt_result', 'producer_source', 'seal', 'wire_correspondence'}:
            raise ValueError('Closed whole lineage differs')
        closed = json.loads(auth(whole['closure']).read_text())
        attempt = json.loads(auth(whole['attempt_result']).read_text())
        if not closed['status'] == 'ALL-SELECTED-PHYSICALLY-CLOSED':
            raise ValueError('Closed whole lineage differs')
        if not all((closed[x] is True for x in ('physical_closure', 'cleanup_complete', 'source_guard_after', 'source_lease_released', 'locks_reacquired_same_inode', 'ps_owned_absent'))):
            raise ValueError('Closed whole lineage differs')
        evidence = closed['attempt_evidence'][whole['attempt_result']['path']]
        if not (evidence['result'] == whole['attempt_result'] and evidence['physical_closure'] is True and (evidence['source_guard_after'] is True)):
            raise ValueError('Closed whole lineage differs')
        if not all((attempt[x] is True for x in ('cleanup_proven', 'control_proven', 'source_guard', 'production_started'))):
            raise ValueError('Closed whole lineage differs')
        if not attempt['source_observation']['producer_inventory'] == whole['producer_source']:
            raise ValueError('Closed whole lineage differs')
        cfg = json.loads(auth(whole['configuration']).read_text())
        auth(whole['producer_source'])
        if not (cfg['production_preparations'] == [] and cfg['prepared_source_custody'] is False):
            raise ValueError('Closed whole lineage differs')
        if not closed['configuration'] == whole['configuration']:
            raise ValueError('Closed whole lineage differs')
        if not cfg['source']['inventory'] == whole['producer_source'] == closed['source_observation_after']['producer_inventory']:
            raise ValueError('Closed whole lineage differs')
        edition = attempt['edition']
        date = attempt['edition_build']['date']
        if not (attempt['edition_build']['edition'] == edition and cfg['date'] == date and (closed['selected_editions'] == [edition])):
            raise ValueError('Closed whole lineage differs')
        if not Path(h['expander_root']) == Path(cfg['output']) / edition / (date + '.shards') / 'expander/.bundle-expander':
            raise ValueError('Closed whole lineage differs')
        wire = json.loads(auth(whole['wire_correspondence']).read_text())
        if not (wire['old_configuration'] == whole['configuration'] and wire['old_source'] == whole['producer_source']):
            raise ValueError('Closed whole lineage differs')
        if not (wire['old_worker'] == h['worker'] and wire['old_seal'] == whole['seal'] and (wire['current_roles'] == h['normal_role_binding'])):
            raise ValueError('Closed whole lineage differs')
        if not (wire['standalone_wire_equal'] is True and wire['native_abi_equivalence_claimed'] is False):
            raise ValueError('Closed whole lineage differs')
        old_source = json.loads(auth(wire['old_source']).read_text())
        current_source = json.loads(auth(wire['current_writer_source']).read_text())
        current_map = json.loads(auth(h['normal_role_binding']).read_text())
        if not current_map['dict-blob-build']['source'] == wire['current_writer_source']:
            raise ValueError('Closed whole lineage differs')
        if not current_map['dict-blob-build']['artifact'] == h['writer']:
            raise ValueError('Closed whole lineage differs')
        if not ({pair['relative'] for pair in wire['source_pairs']} == {'src/lua/bundle_protocol.zig', 'tools/bundle_expander.zig'} and len(wire['source_pairs']) == 2):
            raise ValueError('Closed whole lineage differs')
        for pair in wire['source_pairs']:
            relative = pair['relative']
            if not (pair['old'] == old_source['files'][relative] and pair['current'] == current_source['files'][relative]):
                raise ValueError('Closed whole lineage differs')
            if not old_source['modes'][relative] == current_source['modes'][relative]:
                raise ValueError('Closed whole lineage differs')
            if not (pair['old']['bytes'] == pair['current']['bytes'] and pair['old']['sha256'] == pair['current']['sha256']):
                raise ValueError('Closed whole lineage differs')
            auth(pair['old'])
            auth(pair['current'])
        prepared = {name: h[name] for name in ('worker', 'metadata', 'source_receipt')}
        prepared['expander'] = h['expander_root']
        if not Path(whole['seal']['path']) == Path(prepared['expander']) / '.completed-expander.json':
            raise ValueError('Closed whole lineage differs')
        seal = json.loads(auth(whole['seal']).read_text())
        assets = {n: (size, digest) for n, size, digest in seal['identity']['assets']}
        for name, leaf in (('worker', 'dict-bundle-expander'), ('metadata', 'lua-program.meta')):
            if not Path(prepared[name]['path']) == Path(prepared['expander']) / leaf:
                raise ValueError('Closed whole lineage differs')
            if not (prepared[name]['bytes'], prepared[name]['sha256']) == assets[leaf]:
                raise ValueError('Closed whole lineage differs')
        if not Path(prepared['source_receipt']['path']) == Path(prepared['expander']) / 'extraction-source.json':
            raise ValueError('Closed whole lineage differs')
        if not plan['dump'] == h['dump']:
            raise ValueError('Closed whole lineage differs')
        if not Path(plan['dump']['path']) == Path(seal['identity']['source']['path']):
            raise ValueError('Closed whole lineage differs')
        if not set(plan['dump']) == {'path', 'bytes', 'physical'}:
            raise ValueError('Closed whole lineage differs')
        if not plan['dump']['physical'] == seal['identity']['source']['receipt']['source']:
            raise ValueError('Closed whole lineage differs')
        if not plan['dump']['bytes'] == plan['dump']['physical']['size']:
            raise ValueError('Closed whole lineage differs')
        restoration = wire.get('provider_restoration')
        if restoration is not None:
            if not set(restoration) == {'result', 'closure', 'input_authority', 'original_seal_archive'}:
                raise ValueError('Closed whole lineage differs')
            restored = json.loads(auth(restoration['result']).read_text())
            restored_close = json.loads(auth(restoration['closure']).read_text())
            restored_data = json.loads(auth(restoration['input_authority']).read_text())
            if not (restored_close['outcome'] == 'PASSED-PHYSICALLY-SOURCE-CLOSED' and restored_close['source_after'] is True and (restored_close['allocation_released'] is True) and (restored_close['derived_provider_restoration'] is True) and (restored_close['pages_executed'] == 0)):
                raise ValueError('Closed whole lineage differs')
            if not (restored_close['restoration_result'] == restoration['result'] and restored_close['input_authority'] == restoration['input_authority'] == restored['input_authority']):
                raise ValueError('Closed whole lineage differs')
            if not (restored['passed'] is True and restored['ready'] is True and (restored['source_after'] is True) and (restored['lua_pages_executed'] == 0) and (restored['compiler_executed'] is False) and (restored['worker_rebuilt'] is False)):
                raise ValueError('Closed whole lineage differs')
            if not all((restored[name] is True for name in ('original_native_producer_unchanged', 'logical_provider_identity_unchanged', 'original_source_receipt_unchanged', 'all_other_native_asset_stamps_unchanged', 'source_metadata_and_nlinks_unchanged'))):
                raise ValueError('Closed whole lineage differs')
            if not (restored['current_seal'] == restored_close['current_seal'] == whole['seal'] and restored['worker'] == restored_close['original_worker'] == h['worker']):
                raise ValueError('Closed whole lineage differs')
            if not restored['original_seal_archive'] == restored_close['original_seal_archive'] == restoration['original_seal_archive']:
                raise ValueError('Closed whole lineage differs')
            if not (restored_data['configuration'] == whole['configuration'] and restored_data['original_whole_closure'] == whole['closure'] and (restored_data['root'] == h['expander_root']) and (restored_data['dump'] == plan['dump']['path'])):
                raise ValueError('Closed whole lineage differs')
            if not (restored_data['original_seal']['path'] == whole['seal']['path'] and restored_data['original_seal']['sha256'] == restored['original_seal_sha256'] == restoration['original_seal_archive']['sha256']):
                raise ValueError('Closed whole lineage differs')
            archive = restoration['original_seal_archive']
            if not archive['bytes'] == restored_data['original_seal']['bytes']:
                raise ValueError('Closed whole lineage differs')
            original_seal = json.loads(auth(archive).read_text())
            for name in ('identity', 'origin_graph', 'link'):
                if not original_seal[name] == seal[name]:
                    raise ValueError('Closed whole lineage differs')
            if not (seal['provenance'] == 'ordinary-derived-provider-restoration' and seal['provider_update']['original_seal_sha256'] == archive['sha256']):
                raise ValueError('Closed whole lineage differs')
            expected_sources = {name + '.tsv': cfg['edition_options'][edition]['auxiliary_snapshots'][name] for name in ('category-stats', 'category-tree', 'wikibase-entities', 'wikibase-entity-terms')}
            if not (restored_data['sources'] == expected_sources and restored['aliases'] == restored_close['aliases'] == {name: value['path'] for name, value in expected_sources.items()}):
                raise ValueError('Closed whole lineage differs')
            for name, value in original_seal['runtime_stamps']['assets'].items():
                if name not in expected_sources:
                    if not (seal['runtime_stamps']['assets'][name] == value and seal['runtime_stamps']['snapshot_links'][name] == original_seal['runtime_stamps']['snapshot_links'][name]):
                        raise ValueError('Closed whole lineage differs')
            if not seal['runtime_stamps']['plans'] == original_seal['runtime_stamps']['plans']:
                raise ValueError('Closed whole lineage differs')
        elif not seal['provenance'] == 'ordinary-linked-expander':
            raise ValueError('Closed whole lineage differs')
        original_roles=metadata(h['normal_role_binding'])
        comparisons=[copy.deepcopy(value)for value in (original_roles,self.records)]
        for value in comparisons:value['dict-bundle-build']['dependencies'].pop('extraction_helper',None)
        if comparisons[0]!=comparisons[1]:
            initial_sealed_blob_successor(original_roles,self)
        executed=selected['execution_python']
        if set(executed)!={'builder','extraction_helper'}:raise ValueError('Invalid closed whole Python inputs')
        if Path(executed['builder']['path'])!=Path(__file__).absolute() or Path(executed['extraction_helper']['path'])!=Path(cache.__file__).absolute():
            raise ValueError('Closed whole loaded Python differs')
        for descriptor in executed.values():auth(descriptor)
        live=self.records['dict-bundle-build']['dependencies']['extraction_helper']
        if live!=executed['extraction_helper']:raise ValueError('Closed whole live helper selection differs')
        old_live=original_roles['dict-bundle-build']['dependencies']['extraction_helper']
        applications=selected['live_helper_application']
        if applications is None: applications=[]
        elif isinstance(applications,dict): applications=[applications]
        if not isinstance(applications,list):raise ValueError('Invalid closed whole helper application chain')
        if live!=old_live:
            if not applications:raise ValueError('Closed whole helper application is missing')
            cursor=old_live
            for descriptor in applications:
                application=metadata(descriptor)
                rows=[row for row in application['rows']if row['path']=='tools/extraction_cache.py']
                if application.get('applied')is not True or len(rows)!=1:
                    raise ValueError('Closed whole live helper application differs')
                row=rows[0];before=row['before'];after=row['actual_post']
                recorded_after=row.get('after')
                if 'mode'in row:
                    mode=row['mode']
                else:
                    if (not isinstance(recorded_after,dict) or 'mode'not in before
                            or 'mode'not in recorded_after):
                        raise ValueError('Closed whole helper application lacks exact modes')
                    mode=before['mode']
                if (type(mode)is not int or mode!=live['mode'] or mode!=cursor['mode']
                        or any('mode'in value and (type(value['mode'])is not int or value['mode']!=mode)
                               for value in (before,after,recorded_after) if isinstance(value,dict))
                        or (recorded_after is not None and (not isinstance(recorded_after,dict)
                            or any(recorded_after.get(key)!=after.get(key)for key in ('bytes','sha256'))))):
                    raise ValueError('Closed whole helper application modes differ')
                if (after.get('path')!=cursor['path']
                        or any(before.get(key)!=cursor[key]for key in ('bytes','sha256'))
                        or before.get('mode',mode)!=mode
                        or after.get('mode',mode)!=mode):
                    raise ValueError('Closed whole live helper application chain differs')
                if before.get('path')!=cursor['path']:
                    # Applied receipts may retain their exact preimage separately
                    # from the canonical target; authenticate that owned snapshot.
                    preimage=Path(before['path'])
                    if (not preimage.is_absolute() or str(preimage)!=os.path.normpath(before['path'])
                            or preimage.stat().st_uid!=os.geteuid()):
                        raise ValueError('Unsafe closed whole helper preimage')
                    observed=self.bind_input(auth(before))
                    if observed['mode']!=mode:
                        raise ValueError('Closed whole helper preimage mode differs')
                cursor=dict(after,mode=mode)
            if cursor!=live:raise ValueError('Closed whole helper chain does not reach loaded helper')
        else:
            for descriptor in applications:metadata(descriptor)
        if (attempt.get('outcome')!='failed' or attempt.get('exit_code')!=1
                or attempt.get('accepted')is not None or attempt['edition_build'].get('status')!='failure'):
            raise ValueError('Closed whole attempt is not the original failed whole build')
        producer=seal['identity']['producer'];inventory=old_source['files']
        if (producer['abi']!=[[name,inventory[name]['sha256']]for name in RETAINED_EXPANDER_ABI_PATHS]
                or producer['policy']!=[[name,[inventory[name]['bytes'],inventory[name]['sha256']]]for name in ('build.zig','tools/bundle_build.zig','tools/extraction_cache.py')]):
            raise ValueError('Closed whole executed ABI or producer policy differs')
        root=Path(prepared['expander']);dump=Path(plan['dump']['path'])
        for descriptor in prepared.values():
            if isinstance(descriptor,dict):auth(descriptor)
        self._closed_native_context_options={}
        custody=plan.get('metadata_custody_refresh')
        if custody is not None:
            if set(custody)!={'helper','authority','qualification'}:raise ValueError('Invalid closed whole custody selection')
            auth(custody['helper']);authority=metadata(custody['authority']);qualified=metadata(custody['qualification'])
            if (qualified.get('outcome')!='PASSED-PHYSICALLY-SOURCE-CLOSED'
                    or qualified.get('source_after')is not True or qualified.get('allocation_released')is not True
                    or authority['original_seal']!=whole['seal']
                    or authority['original_native_seal_archive']!=wire['provider_restoration']['original_seal_archive']
                    or authority['original_restoration_closure']!=wire['provider_restoration']['closure']
                    or authority['receipt']['original_seal_sha256']!=whole['seal']['sha256']
                    or any(custody['helper'][key]!=live[key]for key in ('bytes','sha256'))):
                raise ValueError('Closed whole metadata custody differs')
            repaired=metadata(authority['repaired_input_handoff'])
            if h['command']['argv'][h['command']['argv'].index('--figure-input-root')+1]!=str(Path(repaired['output_manifest']['path']).parent):
                raise ValueError('Closed whole repaired input selection differs')
            self._closed_native_context_options={'metadata_custody_refresh':authority['receipt']}
        context=cache.frozen_runtime_context(root,dump,whole['seal']['sha256'],**self._closed_native_context_options)
        if context is None or any(context[name]!=seal[name]for name in ('identity','origin_graph','link')):
            raise ValueError('Closed whole native context is not finalized')
        expected_rows={row['path']:row for row in h['normal_input_rows']}
        if len(expected_rows)!=len(h['normal_input_rows']) or set(selected['input_stamps'])!=set(expected_rows):
            raise ValueError('Closed whole input custody membership differs')
        self._closed_whole_input_stamps=selected['input_stamps']
        for name,row in expected_rows.items():
            current=self.closed_input_identity(name)
            if current!=self._closed_whole_input_stamps[name]:raise ValueError('Closed whole input custody changed')
            value=row['identity']
            if value is None:
                if current is not None:raise ValueError('Closed whole optional input appeared')
            else:
                st=Path(name).stat()
                if dict(device_major=os.major(st.st_dev),device_minor=os.minor(st.st_dev),inode=st.st_ino,size=st.st_size,mtime_ns=st.st_mtime_ns)!=value:
                    raise ValueError('Closed whole input identity changed')
        if cache.tool_identity(root/'dict-bundle-expander')!=seal['identity']['runtime_libraries'] or cache.unicode_case_identity()!=producer['unicode']:
            raise ValueError('Closed whole executed runtime libraries changed')
        self._closed_native_worker_stamp=cache._full_stamp((root/'dict-bundle-expander').stat())
        self._closed_library_routes={}
        libraries=[*seal['identity']['runtime_libraries']['libraries'],*[[row['path'],row['sha256']]for row in producer['unicode']['libraries']]]
        for name,digest in libraries:
            if self.bind_input(Path(name).resolve(strict=True))['sha256']!=digest:
                raise ValueError('Closed whole loaded library changed')
            self._closed_library_routes[name]=str(Path(name).resolve(strict=True))
        self._closed_whole_workspace_state=None
        if 'workspace_state'in selected:
            state_reference=selected['workspace_state'];state=metadata(state_reference)
            binding=state.get('native_generation',{})
            expected_sha=(restoration['original_seal_archive']['sha256'] if restoration is not None else whole['seal']['sha256'])
            if (state_reference['path']!=str(root.parent.parent/'state.json')
                    or state.get('edition')!=edition or state.get('date')!=date
                    or state.get('source')!=cfg['source'].get('fingerprint')
                    or state.get('now_unix')!=cfg.get('now_unix')
                    or not isinstance(binding,dict) or set(binding)!={'seal_sha256','dump','build_inputs'}
                    or binding['dump']!=str(dump) or binding['seal_sha256']!=expected_sha
                    or not isinstance(binding['build_inputs'],dict)
                    or binding['build_inputs'].get('source')!=state['source']
                    or not isinstance(binding['build_inputs'].get('auxiliary_snapshot_sha256'),dict)
                    or any(seal['identity']['providers'].get(auxiliary_snapshot_filename(name)) is None
                        or seal['identity']['providers'][auxiliary_snapshot_filename(name)][1]!=digest
                        for name,digest in binding['build_inputs']['auxiliary_snapshot_sha256'].items())):
                raise ValueError('Closed whole original workspace history differs')
            self._closed_whole_workspace_state=state
        self._closed_native_context=(root,dump,whole['seal']['sha256'])
        return context

    def closed_execution_origin(self):
        """Authenticate the selected closed producer, never current compiler source."""
        import extraction_cache as cache
        selected,result,plan,workspace=initial_sealed_generation(self.initial_sealed_generation,self)
        original_reference=result['completed_expander_seal'];reference=original_reference
        root=workspace/'expander'/'.bundle-expander';deps=self.records['dict-bundle-build']['dependencies']
        sitelinks_update=selected.get('sitelinks_provider_update') is not None
        update=selected.get('sitelinks_provider_update',selected.get('file_metadata_provider_update'));update_references=[]
        update_kind='sitelinks' if sitelinks_update else 'file_metadata'
        if update is None:
            seal=prepared_metadata(reference);ready_seal=seal
        else:
            required={'result','closure','input_authority','original_seal_archive','current_seal','helper','snapshot_metadata_refresh_authority','wire_correspondence'}
            if not isinstance(update,dict) or set(update)!=required:
                raise ValueError('Invalid closed prepared Provider update selection')
            changed=prepared_metadata(update['result']);closed=prepared_metadata(update['closure']);data=prepared_metadata(update['input_authority'])
            if (closed.get('outcome')!='PASSED-PHYSICALLY-SOURCE-CLOSED'
                    or any(closed.get(k)is not True for k in ('source_after','source_lease_released','allocation_released','ready',update_kind+'_provider_update','old_native_producer_unchanged','logical_provider_identity_changed_only_'+update_kind,'source_metadata_nlinks_unchanged'))
                    or closed.get('pages_executed')!=0 or closed.get('worker_rebuilt')is not False
                    or any(changed.get(k)is not True for k in ('passed','ready','source_after','original_native_producer_unchanged','original_source_receipt_unchanged','logical_provider_identity_changed_only_'+update_kind,'all_other_native_asset_stamps_unchanged_except_bound_book_ctime','source_metadata_and_nlinks_unchanged'))
                    or changed.get('compiler_executed')is not False or changed.get('worker_rebuilt')is not False or changed.get('lua_pages_executed')!=0):
                raise ValueError('Prepared Provider update is not independently closed')
            if (closed.get('restoration_result')!=update['result'] or closed.get('input_authority')!=update['input_authority'] or changed.get('input_authority')!=update['input_authority']
                    or data.get('original_preparation')!=selected['preparation_result'] or data.get('original_closure')!=selected['preparation_closure']
                    or data.get('root')!=str(root) or data.get('dump')!=plan['dump']['path'] or data.get('original_seal')!=original_reference
                    or data.get('helper')!=update['helper'] or changed.get('worker')!=result['worker'] or closed.get('original_worker')!=result['worker']
                    or changed.get('current_seal')!=update['current_seal'] or closed.get('current_seal')!=update['current_seal']
                    or changed.get('original_seal_archive')!=update['original_seal_archive'] or closed.get('original_seal_archive')!=update['original_seal_archive']
                    or any(update['original_seal_archive'][k]!=original_reference[k]for k in ('bytes','sha256'))
                    or changed.get('original_seal_sha256')!=original_reference['sha256']
                    or update['current_seal']['path']!=original_reference['path']):
                raise ValueError('Prepared Provider update changed original preparation or output origin')
            seal=prepared_metadata(update['original_seal_archive']);reference=update['current_seal'];ready_seal=prepared_metadata(reference)
            baseline=seal
            refresh=update['snapshot_metadata_refresh_authority']
            if (data.get('snapshot_metadata_refresh_authority')!=refresh or changed.get('snapshot_metadata_refresh_authority')!=refresh or closed.get('snapshot_metadata_refresh_authority')!=refresh):
                raise ValueError('Prepared Provider metadata custody authority differs')
            if refresh is not None:
                authority=prepared_metadata(refresh)
                if authority.get('old_seal')!=original_reference:raise ValueError('Prepared Provider custody has another original seal')
                baseline=cache._snapshot_metadata_refresh(root,seal,original_reference['sha256'],authority['receipt'])
                update_references.append(refresh)
            wire=prepared_metadata(update['wire_correspondence'])
            if (wire.get('original_preparation')!=selected['preparation_result']
                    or wire.get('old_worker')!=result['worker'] or wire.get('dependency')!=data.get('dependency')
                    or wire.get('standalone_wire_equal')is not True or wire.get('native_abi_equivalence_claimed')is not False):
                raise ValueError('Prepared Provider update wire origin differs')
            if changed.get('current_seal_sha256')!=reference['sha256']:
                raise ValueError('Prepared Provider update current seal digest differs')
            source=data['selected_source'];name='wikibase-sitelinks.tsv' if sitelinks_update else 'file-metadata.tsv';value=[source['bytes'],source['sha256']]
            actual=self.bind_input(Path(source['path']))
            if any(actual[key]!=source[key]for key in ('path','bytes','sha256')):
                raise ValueError('Prepared Provider update source differs')
            if sitelinks_update:
                old_source=baseline['runtime_stamps']['snapshot_links'][name]
                old=self.bind_input(Path(old_source))
                if [old['bytes'],old['sha256']]!=baseline['identity']['providers'][name]:
                    raise ValueError('Prepared sitelinks original source differs')
                cache._sitelinks_append(Path(old_source).read_bytes(),Path(source['path']).read_bytes(),data.get('selected_rows'))
            expected=dict(baseline);expected['identity']=dict(baseline['identity']);expected['identity']['providers']=dict(baseline['identity']['providers'])
            expected['identity']['providers'][name]=value
            expected['identity']['assets']=[[name,*value]if row[0]==name else row for row in baseline['identity']['assets']]
            expected['runtime_stamps']=dict(baseline['runtime_stamps']);expected['runtime_stamps']['assets']=dict(baseline['runtime_stamps']['assets']);expected['runtime_stamps']['snapshot_links']=dict(baseline['runtime_stamps']['snapshot_links'])
            expected['runtime_stamps']['assets'][name]=ready_seal['runtime_stamps']['assets'][name]
            expected['runtime_stamps']['snapshot_links'][name]=source['path']
            expected['provenance']='ordinary-sitelinks-provider-update' if sitelinks_update else 'ordinary-file-metadata-provider-update'
            expected['provider_update']=dict(original_seal_sha256=original_reference['sha256'],previous_seal_sha256=original_reference['sha256'],original_providers={name:seal['identity']['providers'][name]})
            if (expected!=ready_seal or changed.get('aliases')!={name:source['path']} or closed.get('aliases')!={name:source['path']}
                    or data['selected_source']['path']!=ready_seal['runtime_stamps']['snapshot_links'][name]):
                raise ValueError('Prepared Provider update exceeds its authorized data delta')
            update_references.extend([update[k]for k in ('result','closure','input_authority','original_seal_archive','current_seal','helper','wire_correspondence')])
        ready_seal_reference=reference
        producer=seal['identity']['producer']
        options = initial_sealed_context_options(selected, self,
            root=root, seal_reference=reference, original_dump=plan['dump'])
        dump = Path(selected.get('restored_dump', plan['dump'])['path'])
        context = cache.frozen_runtime_context(root,dump,reference['sha256'],**options)
        comparable = context
        if context is not None and options:
            comparable = dict(context)
            comparable['runtime_stamps'] = dict(context['runtime_stamps'])
            comparable['runtime_stamps']['assets'] = dict(context['runtime_stamps']['assets'])
            names = []
            if 'snapshot_metadata_refresh' in options:
                refresh = options['snapshot_metadata_refresh']
                names.extend(member['name'] for member in refresh.get('snapshots', [refresh]))
            if 'metadata_custody_refresh' in options:
                names.extend(options['metadata_custody_refresh']['names'])
            if 'extraction_metadata_refresh' in options:
                names.extend(options['extraction_metadata_refresh']['names'])
            if 'restored_indexes' in options:
                names.extend(cache.RESTORED_INDEX_NAMES)
            for name in names:
                comparable['runtime_stamps']['assets'][name] = ready_seal['runtime_stamps']['assets'][name]
        if seal.get('provenance')!='ordinary-linked-expander' or comparable != ready_seal:
            raise ValueError('Selected closed execution origin is not finalized')
        self._closed_native_context_options = options
        for field,dependency in (('runtime','worker_object'),('leaf','value_leaf_bc'),('main_c','worker_main_c')):
            if producer.get(field)!=[deps[dependency]['bytes'],deps[dependency]['sha256']]:
                raise ValueError('Closed execution native ABI artifact differs')
        for field,dependency in (('extractor','modules'),('llvm','llvm')):
            if producer.get(field,{}).get('extractor_sha256')!=deps[dependency]['sha256']:
                raise ValueError('Closed execution compiler artifact origin differs')
        if (producer.get('zig',{}).get('tool_sha256')!=deps['zig']['sha256']
                or producer.get('abi')!=[[name,deps['runtime_source:'+name]['sha256']] for name in RETAINED_EXPANDER_ABI_PATHS]
                or producer.get('policy')!=[[name,[deps['runtime_source:'+name]['bytes'],deps['runtime_source:'+name]['sha256']]] for name in ('build.zig','tools/bundle_build.zig','tools/extraction_cache.py')]
                or producer.get('clang',{}).get('tool',{}).get('extractor_sha256')!=deps['clang']['sha256']
                or producer.get('link_flags')!=['cc','-O2','-pthread','-lm','-lbz2','-lzstd','-lc']):
            raise ValueError('Closed execution producer source or ABI facts differ')
        assets={name:(size,digest) for name,size,digest in seal['identity']['assets']}
        for key,name in (('worker','dict-bundle-expander'),('metadata','lua-program.meta'),('source_receipt','extraction-source.json')):
            if assets.get(name)!=(result[key]['bytes'],result[key]['sha256']):
                raise ValueError('Closed execution output differs from authenticated preparation')
        for reference in (self.initial_sealed_generation,selected['preparation_result'],selected['preparation_closure'],
                          result['input_authority'],plan['roles'],reference,*update_references):
            actual=self.bind_input(Path(reference['path']))
            if any(actual[key]!=reference[key] for key in ('path','bytes','sha256')):
                raise ValueError('Closed execution authority changed')
        if 'snapshot_metadata_refresh' in selected:
            descriptor = selected['snapshot_metadata_refresh']
            actual = self.bind_input(Path(descriptor['path']))
            if any(actual[key] != descriptor[key] for key in ('path','bytes','sha256')):
                raise ValueError('Initial snapshot metadata refresh authority changed')
        worker_stamp=cache._full_stamp((root/'dict-bundle-expander').stat())
        if (cache.tool_identity(root/'dict-bundle-expander')!=seal['identity']['runtime_libraries']
                or cache.unicode_case_identity()!=producer['unicode']):
            raise ValueError('Closed execution worker runtime libraries changed')
        if cache._full_stamp((root/'dict-bundle-expander').stat())!=worker_stamp:
            raise ValueError('Closed execution worker changed during full authentication')
        self._closed_native_worker_stamp=worker_stamp
        self._closed_library_routes={}
        libraries=[*seal['identity']['runtime_libraries']['libraries'],
                   *[[row['path'],row['sha256']] for row in producer['unicode']['libraries']]]
        for name,digest in libraries:
            resolved=Path(name).resolve(strict=True)
            if self.bind_input(resolved)['sha256']!=digest:
                raise ValueError('Closed execution library bytes differ')
            self._closed_library_routes[name]=str(resolved)
        self._closed_native_context=(root,dump,ready_seal_reference['sha256'])
        return context

    def closed_execution_resolution(self, root):
        """Fresh loader paths and original stamps, not another whole ELF hash.

        Full tool/Unicode identities were authenticated at selection; prepared
        generation full-context/final checks retain their original full probes.
        """
        import extraction_cache as cache
        worker=root/'dict-bundle-expander'
        if cache._full_stamp(worker.stat())!=self._closed_native_worker_stamp:
            raise ValueError('Closed execution worker identity changed')
        observed=subprocess.run(['ldd',str(worker)],capture_output=True,text=True,check=True,
                                timeout=cache.identity_probe_timeout(30))
        libraries=set()
        for line in observed.stdout.splitlines():
            match=re.search(r'(?:=>\s*)?(/[^\s]+)\s*\(',line)
            if match:libraries.add(match[1])
            elif 'not found' in line:raise ValueError('Unresolved closed worker library')
        expected=self.closed_native_origin['identity']
        if libraries!={name for name,_ in expected['runtime_libraries']['libraries']}:
            raise ValueError('Closed execution library resolution changed')
        unicode_paths={str(Path(line.split(maxsplit=5)[5].strip()).resolve())
            for line in Path('/proc/self/maps').read_text().splitlines()
            if len(line.split(maxsplit=5))==6 and ('/libunistring.so' in line or '/libutf8proc.so' in line)}
        if (unicode_paths!={row['path'] for row in expected['producer']['unicode']['libraries']}
                or any(str(Path(name).resolve(strict=True))!=resolved for name,resolved in self._closed_library_routes.items())
                or cache._full_stamp(worker.stat())!=self._closed_native_worker_stamp):
            raise ValueError('Closed execution runtime resolution or worker changed')

    def execution_dependency(self, name):
        # runtime_source retains the closed worker's original producer policy.
        # The separate extraction_helper names the actually imported live Python.
        # Ordinary compilation still authenticates every dependency.
        return ((self.initial_sealed_generation is None and getattr(self,'closed_whole_execution',None) is None) or name in
                ('zig','extraction_helper'))

    def compilation_identity(self, row, relative):
        """Authenticate old payload custody, not a live source dependency.

        Git may hold byte-identical payloads after integration; that commit is
        not substituted for the original producer fingerprint/inventory.
        """
        payloads=row.get('source_payload_files',{})
        if relative in payloads:
            descriptor=payloads[relative]
            if (not isinstance(descriptor,dict) or set(descriptor)!={'path','bytes','sha256','mode'}
                    or type(descriptor['bytes'])is not int or descriptor['bytes']<0
                    or type(descriptor['mode'])is not int or not 0<=descriptor['mode']<=0o777
                    or not isinstance(descriptor['sha256'],str)
                    or re.fullmatch('[0-9a-f]{64}',descriptor['sha256'])is None):
                raise ValueError('Invalid retained source payload file authority')
            identity=self.bind_input(Path(descriptor['path']),retain=False)
            if identity!=descriptor:
                raise ValueError('Retained source payload file changed')
            return identity
        git=row.get('source_payload_git')
        if git is None:
            return self.bind_input(Path(row['source_root'])/relative,retain=False)
        if (not isinstance(git,dict) or set(git)!={'repository','commit'}
                or re.fullmatch('[0-9a-f]{40}',git['commit']) is None):
            raise ValueError('Invalid retained source payload Git authority')
        repository=Path(git['repository'])
        if not repository.is_absolute() or repository.resolve()!=repository or not repository.is_dir():
            raise ValueError('Unsafe retained source payload repository')
        key=(str(repository),git['commit'],relative)
        if key not in self.compilation_payloads:
            command=['git','--no-replace-objects','--literal-pathspecs']
            environment=dict(os.environ,GIT_NO_LAZY_FETCH='1')
            entry=subprocess.check_output([*command,'ls-tree','-z',git['commit'],'--',relative],
                cwd=repository,env=environment)
            rows=[value for value in entry.split(b'\0') if value]
            if len(rows)!=1:raise ValueError('Original source Git payload unavailable')
            metadata,name=rows[0].split(b'\t',1)
            mode,kind,oid=metadata.decode('ascii').split()
            if name.decode('utf8')!=relative or mode not in ('100644','100755') or kind!='blob':
                raise ValueError('Original source Git payload role differs')
            raw=subprocess.check_output([*command,'cat-file','blob',oid],cwd=repository,env=environment)
            self.compilation_payloads[key]=dict(bytes=len(raw),mode=int(mode[-3:],8),
                sha256=hashlib.sha256(raw).hexdigest())
        return dict(self.compilation_payloads[key])

    def bind_tool(self, role, path):
        tool=PreparedBlobTool(path)
        tool.retained_roles=self
        if role=='dict-bundle-build':tool.native_working_directory=Path(self.records[role]['source_root'])
        return tool

    def install_role(self, role, workspace):
        if role=='dict-bundle-build' and (self.initial_sealed_generation is not None or getattr(self,'closed_whole_execution',None) is not None):
            raise ValueError('Selected initial sealed generation cannot prepare bundle driver')
        # Use the existing private native-tools install location. Never chmod
        # or overwrite an origin in the shared Zig artifact cache.
        self.require_unchanged()
        artifact=self.records[role]['artifact']
        prefix=(workspace/'native-blob-tools').absolute()
        require_native_tool_directory(prefix)
        (prefix/'bin').mkdir(parents=True,exist_ok=True)
        target=prefix/'bin'/role
        if target.exists() or target.is_symlink():
            require_private_native_tool(target)
            if sha256_file(target)!=artifact['sha256'] or target.stat().st_size!=artifact['bytes']:
                raise ValueError('Existing private native role differs')
        else:
            with tempfile.NamedTemporaryFile(dir=target.parent, prefix=target.name+'.', suffix='.part') as output:
                temporary = Path(output.name)
                with Path(artifact['path']).open('rb') as source:
                    # A private CoW inode preserves origin stamps and survives cache
                    # eviction without duplicating immutable executable extents.
                    try:
                        fcntl.ioctl(output.fileno(),0x40049409,source.fileno())  # Linux FICLONE
                    except OSError as error:
                        import errno
                        if error.errno not in (errno.EXDEV,errno.EOPNOTSUPP,errno.ENOTTY,errno.EINVAL,errno.ENOSYS):
                            raise
                        output.seek(0);output.truncate();source.seek(0)
                        shutil.copyfileobj(source,output,1024*1024)
                output.flush()
                self.require_unchanged()
                if sha256_file(temporary)!=artifact['sha256'] or temporary.stat().st_size!=artifact['bytes']:
                    raise ValueError('Private native role copy differs')
                temporary.chmod(artifact['mode'] & ~0o222)
                # Link the verified copy without overwriting an existing installation.
                os.link(temporary,target)
        require_private_native_tool(target)
        self.tools[role]=self.bind_tool(role,target)
        self.require_unchanged()

    def provenance(self):
        import copy
        self.require_unchanged()
        return copy.deepcopy(self.records)

    def prepared_dispatch(self):
        """Snapshot existing dispatch guards for explicit parent authorization."""
        import copy
        self.require_unchanged()
        if ((self.initial_sealed_generation is None and self.closed_whole_execution is None) or self.sealed_expander_recovery is not None
                or self.writer_figure_transition is not None or self.initial_sealed_context is None):
            raise ValueError('Prepared retained custody requires an adopted initial sealed generation')
        selection = copy.deepcopy(self.records)
        kind='closed_whole_execution' if self.closed_whole_execution is not None else 'initial_sealed_generation'
        selection['dict-bundle-build'][kind]=copy.deepcopy(getattr(self,kind))
        return dict(selection=selection,
            inputs=[dict(identity=self.input_identities[path],stamp=list(stamp)) for path,stamp in self.inputs.items()],
            directories={str(path):list(value) for path,value in self.directories.items()},
            capture_directories={str(path):[*value[:-1],[str(member) for member in value[-1]]]
                for path,value in getattr(self,'borrowed_capture_directories',{}).items()},
            initial_context=[str(self.initial_sealed_context[0]),str(self.initial_sealed_context[1]),self.initial_sealed_context[2]])

    @classmethod
    def from_prepared_dispatch(cls, binding, *, _authenticated_origin=None):
        """Reopen only guards in an authenticated parent-bound generation record.

        Parent admission independently reconstructs the closed selection and
        derives its mandatory readset before authorizing this snapshot. Compilation payloads stay original
        provenance; this does not authorize recompilation or a new role choice.
        """
        import copy
        if not isinstance(binding,dict) or set(binding)!={'selection','inputs','directories','capture_directories','initial_context'}:
            raise ValueError('Invalid prepared retained dispatch binding')
        self=object.__new__(cls)
        self.records=copy.deepcopy(binding['selection'])
        self.initial_sealed_generation=self.records['dict-bundle-build'].pop('initial_sealed_generation',None)
        self.closed_whole_execution=self.records['dict-bundle-build'].pop('closed_whole_execution',None)
        if ((self.initial_sealed_generation is None)==(self.closed_whole_execution is None) or set(self.records)!=set(RETAINED_NATIVE_ROLE_NAMES)):
            raise ValueError('Prepared retained selection differs')
        self.sealed_expander_recovery=None;self.writer_figure_transition=None
        self.inputs={};self.input_identities={};self.directories={};self.borrowed_capture_directories={}
        self.tools={name:None for name in RETAINED_NATIVE_ROLE_NAMES}
        self.zig_sha256=self.records['dict-bundle-build']['zig_sha256'];self.compilation_payloads={}
        for row in binding['inputs']:
            identity=row['identity'];stamp=row['stamp'];path=Path(identity['path'])
            if (set(row)!={'identity','stamp'} or set(identity)!={'path','bytes','sha256','mode'}
                    or not path.is_absolute() or path in self.inputs
                    or not isinstance(stamp,list) or len(stamp)!=6 or any(type(value)is not int for value in stamp)
                    or identity['bytes']!=stamp[3] or identity['mode']!=stat.S_IMODE(stamp[2])
                    or not isinstance(identity['sha256'],str) or re.fullmatch('[0-9a-f]{64}',identity['sha256'])is None):
                raise ValueError('Invalid prepared retained input stamp')
            self.inputs[path]=tuple(stamp);self.input_identities[path]=copy.deepcopy(identity)
        for name,value in binding['directories'].items():
            if not isinstance(value,list) or len(value)!=4 or any(type(v)is not int for v in value):
                raise ValueError('Invalid prepared retained directory')
            self.directories[Path(name)]=tuple(value)
        for name,value in binding['capture_directories'].items():
            if not isinstance(value,list) or len(value)!=7 or any(type(v)is not int for v in value[:-1]):
                raise ValueError('Invalid prepared retained capture directory')
            self.borrowed_capture_directories[Path(name)]=(*value[:-1],tuple(Path(member) for member in value[-1]))
        context=binding['initial_context']
        if not isinstance(context,list) or len(context)!=3:
            raise ValueError('Invalid prepared initial context')
        self.initial_sealed_context=(Path(context[0]),Path(context[1]),context[2])
        if _authenticated_origin is None:
            derived=cls(binding['selection'],zig_sha256=self.zig_sha256)
        else:
            derived=_authenticated_origin
            if (not isinstance(derived,cls) or derived.records!=self.records
                    or derived.initial_sealed_generation!=self.initial_sealed_generation
                    or derived.closed_whole_execution!=self.closed_whole_execution
                    or derived.zig_sha256!=self.zig_sha256 or derived.closed_native_origin is None
                    or derived.sealed_expander_recovery is not None or derived.writer_figure_transition is not None):
                raise ValueError('Authenticated retained origin differs from prepared dispatch')
            # The normal constructor already checked closed source/ABI/producer
            # semantics. Recheck its live readset before using those same facts.
            derived.require_unchanged()
        self.closed_native_origin=derived.closed_native_origin
        self._closed_native_context_options=copy.deepcopy(getattr(derived,'_closed_native_context_options',{}))
        if 'restored_dump' in self._closed_native_context_options:
            self._restored_dump_binding = self._closed_native_context_options['restored_dump']
        if 'restored_indexes' in self._closed_native_context_options:
            self._restored_index_binding = self._closed_native_context_options['restored_indexes']
        self._closed_native_context=derived._closed_native_context
        self._closed_library_routes=derived._closed_library_routes
        self._closed_native_worker_stamp=derived._closed_native_worker_stamp
        if self.closed_whole_execution is not None:
            self._closed_whole_input_stamps=copy.deepcopy(derived._closed_whole_input_stamps)
            self._closed_whole_workspace_state=copy.deepcopy(derived._closed_whole_workspace_state)
        for path,identity in derived.input_identities.items():
            if self.input_identities.get(path)!=identity or self.inputs.get(path)!=derived.inputs[path]:
                raise ValueError('Prepared retained binding omitted a selected execution dependency')
        if any(self.directories.get(path)!=value for path,value in derived.directories.items()):
            raise ValueError('Prepared retained binding omitted an execution directory')
        self.require_unchanged()
        if self.closed_whole_execution is not None:
            if self._closed_whole_workspace_state is None or self.initial_sealed_context!=self._closed_native_context:
                raise ValueError('Prepared closed whole readonly origin differs')
        else:
            selected, result, plan, workspace = initial_sealed_generation(self.initial_sealed_generation,self)
            current_reference=(selected.get('sitelinks_provider_update',selected.get('file_metadata_provider_update'))['current_seal'] if (selected.get('file_metadata_provider_update') is not None or selected.get('sitelinks_provider_update') is not None) else result['completed_expander_seal'])
            if self.initial_sealed_context!=(workspace/'expander'/'.bundle-expander',
                    Path(selected.get('restored_dump', plan['dump'])['path']),current_reference['sha256']):
                raise ValueError('Prepared retained readonly origin differs')
        return self

    def authenticate_prepared_captures(self, observed, cfg):
        """Derive borrowed readsets from the same selected capture validators."""
        import copy
        options=cfg.get('edition_options',{})
        if len(options)!=1:raise ValueError('Prepared retained captures require one edition')
        edition,option=next(iter(options.items()))
        snapshots={name:Path(value['path'] if isinstance(value,dict) else value)
                   for name,value in option.get('auxiliary_snapshots',{}).items()}
        figures=validated_figure_tuple(snapshots,edition,cfg['date'])
        owned=tuple(Path(value['path'] if isinstance(value,dict) else value).resolve() for value in
            (cfg['output'],cfg['raw_shard_root'],option['extraction_cache_root']))
        def overlaps(path):
            path=path.resolve()
            return any(path==root or path in root.parents or root in path.parents for root in owned)
        for name,path in snapshots.items():
            root=path.parent
            if (path.name!=auxiliary_snapshot_filename(name) or not root.is_absolute()
                    or root.resolve()!=root or overlaps(root)
                    or any(node.is_symlink() for node in (root,*root.parents))):continue
            capture=figures.get(name) if name in figures else validated_auxiliary_capture(name,path,edition,cfg['date'])
            if capture is None:
                if name in ('category-tree','category-stats'):
                    declared=option['auxiliary_snapshots'][name]
                    digest=declared['sha256'] if isinstance(declared,dict) else sha256_file(path)
                    if self.bind_plain_category(name,path,digest,owned_roots=owned):
                        if (observed.input_identities.get(path)!=self.input_identities[path]
                                or observed.inputs.get(path)!=self.inputs[path]
                                or observed.directories.get(root)!=self.directories[root]):
                            raise ValueError('Prepared retained binding omitted a borrowed category input or route')
                continue
            _,inventory=capture
            if name in figures:
                key=tuple(sorted((role,str(snapshots[role].absolute())) for role in figures))
                with _FIGURE_TUPLE_REPLAY_LOCK:
                    prior=_FIGURE_TUPLE_REPLAYS.get(key)
                    guard=None if prior is None else copy.deepcopy(prior[0])
                if guard is None:continue
                if any(Path(member).resolve()!=Path(member) or overlaps(Path(member))
                       for member in (*guard[1],*guard[2])):continue
                required={Path(member):identity['sha256'] for member,(_,identity) in guard[1].items()}
                directories={Path(directory) for directory in guard[2]}
            else:
                if name not in ('wikibase-entities','wikibase-entity-terms'):continue
                members=tuple(sorted(root.iterdir()))
                if ({member.name for member in members}!=set(inventory)
                        or any(member.is_symlink() or not member.is_file() for member in members)):continue
                required={root/member:digest for member,digest in inventory.items()};directories={root}
            for member,digest in required.items():
                if observed.input_identities.get(member,{}).get('sha256')!=digest:
                    raise ValueError('Prepared retained binding omitted a borrowed capture input')
            if not directories<=set(observed.borrowed_capture_directories):
                raise ValueError('Prepared retained binding omitted a borrowed directory guard')

    def authenticate_prepared_dispatch(self, binding, cfg=None):
        """Parent-only pre-adoption check, while original full source is leased."""
        observed=self.from_prepared_dispatch(binding,_authenticated_origin=self)
        if (self.records!=observed.records or self.initial_sealed_generation!=observed.initial_sealed_generation
                or self.closed_whole_execution!=observed.closed_whole_execution):
            raise ValueError('Prepared retained origin selection differs')
        for path,identity in self.input_identities.items():
            if observed.input_identities.get(path)!=identity or observed.inputs.get(path)!=self.inputs[path]:
                raise ValueError('Prepared retained binding lost an original guard')
        if any(observed.directories.get(path)!=value for path,value in self.directories.items()):
            raise ValueError('Prepared retained origin directory differs')
        if cfg is not None:self.authenticate_prepared_captures(observed,cfg)
        elif observed.borrowed_capture_directories:
            raise ValueError('Prepared borrowed captures lack their selected input configuration')
        for path,identity in observed.input_identities.items():
            if self.bind_input(path)!=identity or self.inputs[path]!=observed.inputs[path]:
                raise ValueError('Prepared retained input differs before authorization')
        self.require_unchanged();observed.require_unchanged()
        return observed

    def bind_input(self, path, *, retain=True):
        if not path.is_absolute() or any(parent.is_symlink() for parent in (path, *path.parents)):
            raise ValueError('Unsafe retained native dependency path')
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('Retained native dependency is not a regular file')
        stamp = (before.st_dev, before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
        previous = self.inputs.get(path)
        if previous is not None:
            if previous != stamp:raise ValueError('Retained native dependency identity changed')
            return dict(self.input_identities[path])
        digest = sha256_file(path)
        after = path.lstat()
        if stamp != (after.st_dev, after.st_ino, after.st_mode, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError('Retained native dependency changed while hashing')
        previous = self.inputs.get(path)
        if previous is not None and previous != stamp:
            raise ValueError('Retained native dependency identity changed')
        identity=dict(path=str(path), bytes=before.st_size, mode=stat.S_IMODE(before.st_mode), sha256=digest)
        if retain:
            self.inputs[path] = stamp
            self.input_identities[path]=identity
        return dict(identity)

    def bind_plain_category(self, name, path, digest, *, owned_roots):
        """Borrow an authenticated category payload, not an inferred capture."""
        if name not in ('category-tree','category-stats'):return False
        root=path.parent
        if (path.name!=auxiliary_snapshot_filename(name) or not path.is_absolute()
                or path.resolve()!=path or any(node.is_symlink() for node in (path,*path.parents))
                or any(root==owned or root in owned.parents or owned in root.parents for owned in owned_roots)):
            return False
        st=root.stat();identity=(st.st_dev,st.st_ino,st.st_mode,st.st_uid)
        if root in self.directories and self.directories[root]!=identity:
            raise ValueError('Borrowed category source directory changed')
        if self.bind_input(path)['sha256']!=digest:
            raise ValueError('Borrowed category input differs from selected bytes')
        after=root.stat()
        if identity!=(after.st_dev,after.st_ino,after.st_mode,after.st_uid):
            raise ValueError('Borrowed category source directory changed while binding')
        self.directories[root]=identity
        return True

    def bind_capture(self, root, inventory, *, figure_guard=None):
        """Borrow only a complete freshly replayed capture under dispatch guards."""
        directories={root:tuple(sorted(root.iterdir()))}
        expected={root/name:digest for name,digest in inventory.items()}
        if figure_guard is not None:
            runtime,identities,parents=figure_guard
            import prepare_figure_metadata as figure
            if (figure.producer(),figure.metadata.producer(),figure.site_info.producer())!=runtime:
                raise ValueError('Borrowed Figure helper changed after replay')
            for path,(stamp,identity) in identities.items():
                path=Path(path)
                if _figure_replay_identity(path)!=stamp:
                    raise ValueError('Borrowed Figure input changed after replay')
                expected[path]=identity['sha256']
            for directory,identity in parents.items():
                directory=Path(directory)
                if (directory.stat().st_dev,directory.stat().st_ino,tuple(sorted(directory.iterdir())),
                        _figure_replay_identity(directory,directory=True))!=identity:
                    raise ValueError('Borrowed Figure directory changed after replay')
                directories[directory]=identity[2]
            import prepare_figure_metadata as figure
            for module in (figure,figure.evidence,figure.metadata,figure.site_info):
                self.bind_input(Path(module.__file__).absolute())
            for name in figure.evidence.dependencies():
                self.bind_input(figure.evidence.REPO/name)
        guards=getattr(self,'borrowed_capture_directories',{})
        for directory,members in directories.items():
            if any(path.is_symlink() for path in (directory,*directory.parents)):
                raise ValueError('Unsafe borrowed capture directory')
            st=directory.stat()
            guard=(st.st_dev,st.st_ino,st.st_mode,st.st_uid,st.st_mtime_ns,st.st_ctime_ns,members)
            if directory in guards and guards[directory]!=guard:
                raise ValueError('Borrowed capture directory changed')
            guards[directory]=guard
        self.borrowed_capture_directories=guards
        reused={}
        for path,digest in expected.items():
            proof=identities.get(str(path)) if figure_guard is not None else None
            identity=None if proof is None else proof[1]
            if (path not in self.inputs and isinstance(identity,dict)
                    and set(identity) in ({'size','sha256'},{'size','sha1','sha256'})
                    and type(identity['size']) is int and identity['size']==proof[0][1][6]
                    and ('sha1' not in identity or isinstance(identity['sha1'],str)
                         and re.fullmatch('[0-9a-f]{40}',identity['sha1']))
                    and isinstance(identity['sha256'],str) and re.fullmatch('[0-9a-f]{64}',identity['sha256'])):
                # The completed Figure replay already hashed these exact bytes.
                # Keep the normal borrower guard; publish only after final checks.
                if (not path.is_absolute() or any(parent.is_symlink() for parent in (path,*path.parents))
                        or _figure_replay_identity(path)!=proof[0]):
                    raise ValueError('Borrowed Figure input changed before binding')
                actual=dict(path=str(path),bytes=identity['size'],
                    mode=stat.S_IMODE(proof[0][1][2]),sha256=identity['sha256'])
                reused[path]=(proof[0],actual)
            else:
                actual=self.bind_input(path)
            if actual['sha256']!=digest:
                raise ValueError('Borrowed capture input differs from validated bytes')
        if figure_guard is not None and (figure.producer(),figure.metadata.producer(),figure.site_info.producer())!=runtime:
            raise ValueError('Borrowed Figure helper changed while binding')
        self.require_unchanged()
        for path,(stamp,_) in reused.items():
            if (any(parent.is_symlink() for parent in (path,*path.parents))
                    or _figure_replay_identity(path)!=stamp):
                raise ValueError('Borrowed Figure input changed during binding')
        for path,(stamp,identity) in reused.items():
            value=stamp[1]
            self.inputs[path]=(value[0],value[1],value[2],value[6],value[7],value[8])
            self.input_identities[path]=identity

    def require_inputs_unchanged(self):
        for path,expected in getattr(self,'_closed_whole_input_stamps',{}).items():
            if self.closed_input_identity(path)!=expected:
                raise ValueError('Closed whole input custody changed')
        context=(getattr(self, 'initial_sealed_context', None) or getattr(self,'_closed_native_context',None))
        if context is not None:
            import extraction_cache as native_cache
            frozen=native_cache.frozen_runtime_context(*context,**getattr(self,'_closed_native_context_options',{}))
            if frozen is None or (getattr(self,'closed_native_origin',None) is not None and frozen!=self.closed_native_origin):
                raise ValueError('Retained initial sealed input changed')
            closed=getattr(self,'closed_native_origin',None)
            if closed is not None:
                self.closed_execution_resolution(context[0])
        for path,expected in getattr(self,'borrowed_capture_directories',{}).items():
            st=path.stat()
            if (any(parent.is_symlink() for parent in (path,*path.parents)) or
                    (st.st_dev,st.st_ino,st.st_mode,st.st_uid,st.st_mtime_ns,st.st_ctime_ns,tuple(sorted(path.iterdir())))!=expected):
                raise ValueError('Borrowed capture membership changed')
        for path, expected in self.directories.items():
            st=path.stat()
            if path.is_symlink() or (st.st_dev,st.st_ino,st.st_mode,st.st_uid)!=expected:
                raise ValueError('Retained native working directory changed')
        # Many retained files are siblings. Reuse only the path spellings;
        # check each symlink and file identity anew for every dependency.
        ancestor_names = {}
        for path, stamp in self.inputs.items():
            parent = path.parent
            names = ancestor_names.get(parent)
            if names is None:
                names = tuple(map(os.fspath, (parent, *parent.parents)))
                ancestor_names[parent] = names
            if os.path.islink(path) or any(map(os.path.islink, names)):
                raise ValueError('Retained native dependency parent changed')
            current = path.lstat()
            if (current.st_dev, current.st_ino, current.st_mode, current.st_size,
                    current.st_mtime_ns, current.st_ctime_ns) != stamp:
                raise ValueError('Retained native dependency changed: '+str(path))
    def require_unchanged(self):
        self.require_inputs_unchanged()
        for tool in self.tools.values():
            if tool is not None:tool.require_unchanged()

    def release_staged_provider_inputs(self):
        # Called only after ordinary merged verification and its staging seal,
        # immediately before disposing this owned workspace. Originals stay bound.
        self.require_unchanged()
        for path in getattr(self,'staged_provider_inputs',{}).values():
            del self.inputs[path]
            del self.input_identities[path]
        self.staged_provider_inputs={}

    def require_command(self, role, args):
        if role not in self.records:
            raise ValueError('Unknown retained native command role')
        if role == 'dict-bundle-build':
            if self.initial_sealed_generation is not None or getattr(self,'closed_whole_execution',None) is not None or getattr(_PREPARED_SOURCE,'value',None) is not None:
                raise ValueError('Prepared retained generation cannot recompile or relink')
            # parseOptions starts at index 2; another occurrence may be a value.
            if len(args) < 3 or args[2] != '--expander-only' or args.count('--expander-only') != 1:
                raise ValueError('Retained bundle role is restricted to expander-only execution')

    def prepare(self, expander_args, edition, date, *, workspace=None, figure_inputs=None):
        if expander_args is not None and (self.initial_sealed_generation is not None or getattr(self,'closed_whole_execution',None) is not None):
            raise ValueError('Selected initial sealed generation cannot recompile or relink')
        self.require_unchanged()
        needed=(*BLOB_TOOL_NAMES, *(['dict-bundle-build'] if expander_args is not None else []))
        for role in needed:
            if self.tools[role] is None:
                if workspace is None:raise ValueError('Writable retained origin requires private installation')
                self.install_role(role,workspace)
        check_figure_compatibility(self.tools['dict-blob-build'],figure_inputs,edition,date)
        if expander_args is not None:
            self.require_command('dict-bundle-build', expander_args)
            try:
                self.tools['dict-bundle-build'].run(expander_args, edition, date, 'retained_expander_prepare')
            finally:
                self.require_unchanged()
        return {name: self.tools[name] for name in BLOB_TOOL_NAMES}


def prepare_blob_tools(workspace, zig, edition, date, build_identity=None, *, expander_args=None, figure_inputs=None, retained_roles=None):
    """Use the existing Zig graph once, then bind its private installed outputs."""
    if getattr(_PREPARED_SOURCE,'value',None) is not None:
        raise ValueError('An authorized generation cannot silently prepare current native source')
    phase='blob_tools_prepare' if expander_args is None else 'expander_and_blob_tools_prepare'
    with build_phase(edition,date,phase) as outcome:
        started=time.monotonic()
        command_started=post_started=None
        try:
            runtime_scope = retained_runtime_scope(retained_roles)
            if runtime_scope is not None:
                if (expander_args is not None or build_identity is None
                        or build_identity.get('retained_runtime_source') != runtime_scope):
                    raise ValueError('Retained runtime selection cannot compile or relink')
                selected_provenance = retained_roles.provenance()
                source = retained_runtime_fingerprints(runtime_scope, selected_provenance)[0]
            else:
                if build_identity is not None and 'retained_runtime_source' in build_identity:
                    raise ValueError('Retained runtime selection lost its sealed worker')
                source=source_fingerprint()
            compiler=shutil.which(zig)
            if compiler is None:raise ValueError('Zig compiler executable is unavailable')
            compiler=Path(compiler).resolve(strict=True)
            compiler_sha=(retained_roles.bind_input(compiler)['sha256']
                          if isinstance(retained_roles, RetainedNativeToolRoles) else sha256_file(compiler))
            if build_identity is not None and (source!=build_identity['source'] or compiler_sha!=build_identity['zig_sha256']):
                raise ValueError('Native blob tool preparation source or compiler differs from build identity')
            if retained_roles is not None:
                if (not isinstance(retained_roles, RetainedNativeToolRoles)
                        or retained_roles.zig_sha256 != compiler_sha
                        or build_identity is None
                        or build_identity.get('native_tool_roles') != (selected_provenance
                            if runtime_scope is not None else retained_roles.provenance())):
                    raise ValueError('Retained roles do not match this ordinary preparation')
                request=getattr(_PREPARED_SOURCE,'request',None)
                if request is not None:
                    if not isinstance(request,PreparedSourceRequest):
                        raise ValueError('Retained preparation requires its bound pending request')
                    request.require_retained_preparation(retained_roles,workspace,build_identity,edition,date,expander_args)
                command_started=time.monotonic()
                tools=retained_roles.prepare(expander_args, edition, date, workspace=workspace,figure_inputs=figure_inputs)
                post_started=time.monotonic()
                if runtime_scope is not None:
                    selected_provenance = retained_roles.provenance()
                    current = retained_runtime_fingerprints(
                        retained_runtime_scope(retained_roles), selected_provenance)[0]
                else:
                    current = source_fingerprint()
                if current!=source or retained_roles.bind_input(compiler)['sha256']!=compiler_sha:
                    raise ValueError('Source or compiler changed during retained role selection')
                outcome.update(preparation='retained-role-selection', orchestration_source=source,
                    zig_sha256=compiler_sha, native_role_provenance=(selected_provenance
                        if runtime_scope is not None else retained_roles.provenance()),
                    selected_native_artifacts={name:dict(path=str(tool.path),bytes=tool.stamp[2],
                        mode=stat.S_IMODE(tool.stamp[-1]),sha256=tool.sha256)
                        for name,tool in retained_roles.tools.items() if tool is not None})
                return tools
            prefix=(workspace/'native-blob-tools').absolute()
            require_native_tool_directory(prefix)
            for name in BLOB_TOOL_NAMES:
                path=prefix/'bin'/name
                if path.exists() or path.is_symlink():require_private_native_tool(path)
            command=[str(compiler),'build','-j1','-Doptimize=fast','--prefix',str(prefix),'prepare-blob-tools']
            if expander_args is not None and figure_inputs is None:
                command.extend(['--summary','all','build-dictionary','--',*expander_args])
            command_started=time.monotonic()
            run_checked(command)
            post_started=time.monotonic()
            if source_fingerprint()!=source or sha256_file(compiler)!=compiler_sha:
                raise ValueError('Source or compiler changed during native blob tool preparation')
            require_native_tool_directory(prefix)
            tools={}
            for name in BLOB_TOOL_NAMES:
                path=prefix/'bin'/name
                info=require_private_native_tool(path)
                # These are private install copies, never the shared Zig cache artifacts.
                path.chmod(stat.S_IMODE(info.st_mode)&~0o222)
                tools[name]=PreparedBlobTool(path)
            check_figure_compatibility(tools['dict-blob-build'],figure_inputs,edition,date)
            if expander_args is not None and figure_inputs is not None:
                # The normal build graph may reuse its prepared tools, but it
                # must not execute the expensive expander before this check.
                post_started=None
                run_checked([str(compiler),'build','-j1','-Doptimize=fast','--prefix',str(prefix),
                    '--summary','all','build-dictionary','--',*expander_args])
                post_started=time.monotonic()
                if source_fingerprint()!=source or sha256_file(compiler)!=compiler_sha:
                    raise ValueError('Source or compiler changed during expander preparation')
                for tool in tools.values():tool.require_unchanged()
            record=dict(schema='wikidict.prepared-blob-tools.v1',source=source,zig_sha256=compiler_sha,
                        optimize='fast',tools={name:dict(path=str(tool.path),sha256=tool.sha256,
                            bytes=tool.stamp[2],mode=stat.S_IMODE(tool.stamp[-1])) for name,tool in tools.items()})
            # This source/artifact binding survives workspace retirement in the
            # existing BUILD_PHASE log; no independent receipt or cache is needed.
            outcome.update(record)
            return tools
        finally:
            finished=time.monotonic()
            # Subintervals are inside phase seconds; absent means not entered.
            outcome['pre_verification_seconds']=round((command_started if command_started is not None else finished)-started,3)
            if command_started is not None:
                outcome['command_seconds']=round((post_started if post_started is not None else finished)-command_started,3)
            if post_started is not None:
                outcome['post_verification_seconds']=round(finished-post_started,3)

class DeterministicPresentationFailure(subprocess.CalledProcessError):
    def __init__(self, original, receipt):
        super().__init__(original.returncode, original.cmd, output=original.output, stderr=original.stderr)
        self.failure_receipt = str(receipt)
        self.presentation_audit = None
        self.presentation_continuation_safe = False


class DeterministicBuildInputFailure(subprocess.CalledProcessError):
    def __init__(self, original, receipt):
        super().__init__(original.returncode, original.cmd, output=original.output, stderr=original.stderr)
        self.failure_receipt = str(receipt)
        self.presentation_audit = None
        self.presentation_continuation_safe = False


def write_failure_evidence(path, row):
    try:
        path.write_text(json.dumps(row, sort_keys=True) + '\n')
    except OSError:
        # Reporting must never replace the builder or coverage failure.
        try:
            print(f'Unable to write shard failure evidence: {path}', file=sys.stderr, flush=True)
        except OSError:
            pass


def matching_presentation_capture(receipt, invocation_id, invocation_args, start, limit):
    """Verify the complete typed capture used when no outer failure receipt exists."""
    root=receipt.parent/'.presentation-first-failure'
    capture=root/'capture.json'
    try:
        if receipt.is_symlink() or receipt.parent.name!=invocation_id or root.is_symlink() or capture.is_symlink():return None
        if not stat.S_ISREG(capture.lstat().st_mode):return None
        with capture.open('rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):return None
            raw=stream.read(64*1024+1)
        if len(raw)>64*1024:return None
        row=json.loads(raw)
        if (not isinstance(row,dict) or row.get('schema')!='wikidict.presentation-first-failure.v1'
                or row.get('record_complete') is not True or row.get('diagnostic_only') is not True
                or row.get('publication_created') is not False or row.get('semantic_acceptance') is not False
                or row.get('error_name') not in ('UncompiledTemplate','InvalidHeadingProjection','RenderLimit','InvalidPreContext')
                or row.get('invocation_id')!=invocation_id):return None
        digest=hashlib.sha256()
        for arg in invocation_args:
            encoded=arg.encode('utf-8');digest.update(len(encoded).to_bytes(8,'little'));digest.update(encoded)
        if (row.get('invocation_args_hash_framing')!='each argv item: u64 little-endian byte length then exact bytes'
                or row.get('invocation_args_sha256')!=digest.hexdigest()):return None
        title=row.get('title')
        if (type(row.get('ordinal')) is not int or not start<=row['ordinal']<start+limit
                or type(row.get('namespace')) is not int or row['namespace']<0
                or type(row.get('page_id')) is not int or row['page_id']<0
                or type(row.get('revision_id')) is not int or row['revision_id']<0
                or not isinstance(title,str) or not title or row.get('title_truncated') is not False):return None
        title_bytes=title.encode('utf-8')
        if type(row.get('title_bytes')) is not int or row['title_bytes']!=len(title_bytes) or row.get('title_sha256')!=hashlib.sha256(title_bytes).hexdigest():return None
        context=row.get('input')
        if (not isinstance(context,dict) or len(invocation_args)<2
                or context.get('dump_path')!=invocation_args[0]
                or type(context.get('start_page')) is not int or context['start_page']!=start
                or type(context.get('requested_limit')) is not int or context['requested_limit']!=limit
                or row.get('payload_limit_bytes')!=4*1024*1024):return None
        # Hash framing binds every argument; also check the captured source role.
        flag='--expander-root'
        if invocation_args.count(flag)!=1:return None
        index=invocation_args.index(flag)+1
        if index>=len(invocation_args) or context.get('expander_root')!=invocation_args[index]:return None
        payloads=(('raw_source','raw.wikitext',256*1024,True),('expanded','expanded.wikitext',2*1024*1024,True),
                  ('display_title','display-title.wikitext',256*1024,False),('poem_metadata','poem.json',256*1024,False),
                  ('missing_dependency_metadata','missing-dependency.json',256*1024,False),
                  ('index_row','index-row.tsv',256*1024,True),('alias_record','alias.json',256*1024,False))
        retained=0
        for key,suffix,maximum,required in payloads:
            part=row.get(key)
            if (not isinstance(part,dict) or part.get('truncated') is not False or part.get('unretained') is not False
                    or type(part.get('bytes')) is not int or type(part.get('retained_bytes')) is not int):return None
            if part.get('present') is False:
                if required or part['bytes']!=0 or part['retained_bytes']!=0 or part.get('path') is not None or part.get('sha256') is not None:return None
                continue
            size=part['bytes'];path=root/('failure-00000001-'+suffix)
            if (part.get('present') is not True or not 0<=size<=maximum or part['retained_bytes']!=size
                    or part.get('path')!=str(path) or path.is_symlink()):return None
            if not stat.S_ISREG(path.lstat().st_mode):return None
            with path.open('rb') as stream:
                info=os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size!=size:return None
                data=stream.read(size+1)
            if len(data)!=size or hashlib.sha256(data).hexdigest()!=part.get('sha256'):return None
            retained+=size
        return row['error_name'] if retained<=4*1024*1024 else None
    except (OSError,ValueError,TypeError,KeyError,UnicodeError,AttributeError):
        return None


def matching_build_failure(path, invocation_id, invocation_args, start, limit):
    # Return the exact typed error and evidence path, never a classification from
    # exit 1, page text, or inherited stderr. Input identity is checked by caller.
    try:
        with path.open('rb') as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode): return None
            raw = stream.read(64 * 1024 + 1)
        if len(raw) > 64 * 1024: return None
        row = json.loads(raw)
        if not isinstance(row, dict): return None
        if (row.get('schema') != 'wikidict.blob-build.failure.v1'
                or row.get('invocation_id') != invocation_id
                or row.get('invocation_args') != invocation_args): return None
        if (row.get('failure_class'),row.get('error_name')) == ('deterministic-presentation','UncompiledPresentation'):
            pass
        elif (row.get('failure_class') == 'deterministic-build-input' and row.get('error_name') in
              ('InterfaceMessageSnapshotMissing','FileMetadataSnapshotMissing')):
            worker=row.get('worker');source=row.get('source')
            if (not isinstance(worker,dict) or worker.get('stage')!='expand'
                    or worker.get('error_name')!=row['error_name']
                    or not isinstance(worker.get('detail'),str)
                    or not isinstance(source,dict) or type(source.get('bytes')) is not int or source['bytes']<0
                    or not isinstance(source.get('sha256'),str)
                    or re.fullmatch(r'[0-9a-f]{64}',source['sha256']) is None): return None
        else: return None
        page = row.get('page')
        if (isinstance(page, dict) and type(page.get('ordinal')) is int
                and start <= page['ordinal'] < start + limit
                and type(page.get('namespace')) is int and page['namespace'] >= 0
                and isinstance(page.get('title'), str) and bool(page['title'])
                and type(page.get('page_id')) is int and page['page_id'] >= 0
                and type(page.get('revision_id')) is int and page['revision_id'] >= 0):
            return row['error_name'],path
    except FileNotFoundError:
        captured_error=matching_presentation_capture(path,invocation_id,invocation_args,start,limit)
        if captured_error is not None:
            return captured_error,path.parent/'.presentation-first-failure'/'capture.json'
    except (OSError, ValueError, TypeError):
        pass
    return None


def shard_completion_present(shard):
    if any((shard/name).exists() or (shard/name).is_symlink() for name in
           ('.verified','page-coverage.json','namespace-coverage.json','complete.json')):
        return True
    catalog=shard/'languages.tsv'
    return catalog.is_symlink() or (catalog.is_file() and catalog.stat().st_size>0)


def cleanup_incomplete_shard_payload(shard, diagnostics, *, retire_payload=True):
    """Closed builder only: preserve diagnostics before retiring disposable output."""
    shard=artifact_path(shard)
    result=dict(shard=str(shard),status='absent',removed=[],diagnostics=[],
                allocated_file_bytes_removed=0,exclusive_filesystem_gain_claimed=False)
    if not shard.exists(): return result
    if shard.is_symlink() or not shard.is_dir(): raise ValueError('Unsafe incomplete shard')
    if retire_payload and shard_completion_present(shard):
        return dict(result,status='retained-completed')
    def identity(path):
        s=path.lstat()
        return (s.st_dev,s.st_ino,s.st_mode,s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    root_identity=identity(shard)[:2]
    payload=[]
    spool_names={f'lang-{i:02d}.tmp' for i in range(32)}|{
        name+'.tmp' for name in ('thesaurus','citations','reconstruction','rhymes','sign-gloss','supplemental','aliases')}
    for name in ('.spool','languages'):
        if not retire_payload: break
        directory=shard/name
        if not directory.exists() and not directory.is_symlink(): continue
        artifact_path(directory)
        if directory.is_symlink() or not directory.is_dir(): raise ValueError('Unsafe generated shard directory')
        for path in directory.iterdir():
            selected=path.name in spool_names if name=='.spool' else re.fullmatch(r'[0-9a-f]{64}\.wikblb(?:\.xz(?:\.part)?)?',path.name)
            if not selected: continue
            before=identity(path)
            # A shared inode can belong to another publication/cache. Leave it.
            if stat.S_ISREG(before[2]) and before[3]==1: payload.append((path,before,path.lstat().st_blocks*512))
    diagnostic_files=[]
    fallback=shard/'fallback-pages.jsonl'
    if fallback.exists() or fallback.is_symlink(): diagnostic_files.append(fallback)
    capture=shard/'.presentation-first-failure'
    if capture.exists() or capture.is_symlink():
        if capture.is_symlink() or not capture.is_dir(): raise ValueError('Unsafe first-failure capture')
        diagnostic_files.extend(capture.iterdir())
    if diagnostic_files:
        diagnostics=Path(diagnostics)
        diagnostics.mkdir(mode=0o700,parents=True,exist_ok=False)
        for source in diagnostic_files:
            artifact_path(source)
            before=identity(source)
            if not stat.S_ISREG(before[2]): raise ValueError('Unexpected failure diagnostic entry')
            target=diagnostics/source.relative_to(shard)
            target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
            with source.open('rb') as src,target.open('xb') as dst:
                if identity(source)!=before: raise ValueError('Failure diagnostic changed')
                # Keep a private inode for evidence without allocating the same data twice.
                try:
                    fcntl.ioctl(dst.fileno(), 0x40049409, src.fileno())  # Linux FICLONE
                except OSError as error:
                    if error.errno not in (errno.EXDEV, errno.EOPNOTSUPP, errno.ENOTTY, errno.EINVAL, errno.ENOSYS):
                        raise
                    dst.seek(0)
                    dst.truncate()
                    src.seek(0)
                    shutil.copyfileobj(src, dst, 1024 * 1024)
                dst.flush(); os.fsync(dst.fileno())
            original_sha=sha256_file(source); retained_sha=sha256_file(target)
            if identity(source)!=before or original_sha!=retained_sha:
                raise ValueError('Failure diagnostic copy differs')
            if identity(target)[:2]==before[:2]: raise ValueError('Failure diagnostic archive shares inode')
            result['diagnostics'].append(dict(original=str(source),retained=str(target),bytes=before[4],sha256=retained_sha))
    for path,before,allocated in payload:
        if identity(shard)[:2]!=root_identity or shard_completion_present(shard):
            raise ValueError('Incomplete shard ownership/completion changed')
        if identity(path)!=before: raise ValueError('Generated shard payload changed')
        unlink_artifact(path)
        result['removed'].append(dict(path=str(path),device=before[0],inode=before[1],bytes=before[4],allocated_bytes=allocated))
        result['allocated_file_bytes_removed']+=allocated
    return dict(result,status='generated-payload-retired' if payload else 'diagnostics-retained' if diagnostic_files else 'no-generated-payload')


def cleanup_failed_attempt_shards(cfg, edition, folder, attempt):
    """Controller post-join hook; never infer closure from a failed exit alone."""
    if (attempt.get('accepted') is not None or attempt.get('outcome')!='failed'
            or attempt.get('controller_interrupted') is not False
            or not all(attempt.get(key) is True for key in ('cleanup_proven','source_guard','control_proven'))
            or type(attempt.get('exit_code')) is not int or attempt['exit_code']==0):
        return dict(status='retained-unproven-or-complete-attempt',shards=[])
    if not cfg.get('raw_shard_root'): return dict(status='retained-no-external-raw-owner',shards=[])
    workspace=Path(cfg['output'])/edition/(cfg['date']+'.shards')
    artifact_path(workspace)
    if workspace.is_symlink() or not workspace.is_dir(): return dict(status='retained-no-workspace-owner',shards=[])
    state_path=workspace/'state.json'
    if state_path.is_symlink() or not state_path.is_file():
        return dict(status='retained-no-workspace-owner',shards=[])
    state=read_build_envelope(state_path)
    if not isinstance(state,dict): raise ValueError('Invalid failed-attempt workspace owner')
    expected=Path(cfg['raw_shard_root']).absolute()/edition/(cfg['date']+'.raw-shards')
    if state.get('raw_shards_path')!=str(expected): raise ValueError('Failed-attempt raw shard owner differs')
    raw=external_raw_shards(workspace,expected)
    if not raw.exists(): return dict(status='absent',shards=[])
    results=[]
    for shard in sorted(raw.iterdir()):
        if re.fullmatch(r'[0-9]{8}',shard.name):
            results.append(cleanup_incomplete_shard_payload(shard,Path(folder)/'generated-shard-diagnostics'/shard.name))
    return dict(status='closed-attempt-processed',shards=results)


def retain_failed_shard_diagnostics(shard, evidence, *, retire_payload=True):
    try:
        # Existing coverage retry policy owns marker-bearing rejected output.
        # Archive its diagnostics, without changing the normal retry decision.
        result=cleanup_incomplete_shard_payload(shard,evidence/'shard-diagnostics',
            retire_payload=retire_payload and not shard_completion_present(shard))
    except (OSError,ValueError) as error:
        result=dict(status='cleanup-error',error=f'{type(error).__name__}: {error}',partial_cleanup_possible=True)
    write_failure_evidence(evidence/'payload-cleanup.json',result)
    return result['status'] not in ('cleanup-error','retained-completed')


def build_shard_with_retries(tool, native_args, shard, evidence_root, edition, date, start, limit, check_identity, validate):
    evidence_root.mkdir(mode=0o700, exist_ok=True)
    if evidence_root.is_symlink() or not evidence_root.is_dir():
        raise ValueError('Invalid shard failure evidence directory')
    last_error = None
    for attempt in range(1, SHARD_RETRIES + 1):
        if shard.exists(): remove_artifact_tree(shard)
        invocation_id = uuid.uuid4().hex
        # Receipts and diagnostic copies survive workspace retirement. Only
        # recognized generated payload is retired after a joined failed builder.
        evidence = evidence_root / invocation_id
        evidence.mkdir(mode=0o700)
        receipt = evidence / 'failure.json'
        invocation_args = list(native_args) + ['--failure-receipt', str(receipt), '--invocation-id', invocation_id]
        argv = tool.command(invocation_args)
        (evidence / 'invocation.json').write_text(json.dumps(dict(
            invocation_id=invocation_id, argv=argv, start_page=start, pages=limit,
            attempt=attempt), sort_keys=True) + '\n')
        try:
            tool.run(invocation_args, edition, date, 'shard_build', start_page=start, pages=limit, attempt=attempt)
        except subprocess.CalledProcessError as error:
            write_failure_evidence(evidence / 'exit.json', dict(returncode=error.returncode,
                classification='pending-input-identity'))
            # Preserve the command evidence first. Changed input identity is an
            # independent fatal condition, never a typed-data failure or retry.
            check_identity()
            matched_failure = matching_build_failure(receipt, invocation_id, invocation_args, start, limit)
            deterministic = matched_failure is not None
            missing_input = deterministic and matched_failure[0] in ('InterfaceMessageSnapshotMissing','FileMetadataSnapshotMissing')
            write_failure_evidence(evidence / 'classification.json', dict(
                deterministic_presentation=deterministic and not missing_input,
                deterministic_build_input=missing_input))
            # A signaled command can leave descendants alive. Archive evidence,
            # but leave new payload retirement to the controller's proven join.
            may_retry=retain_failed_shard_diagnostics(shard,evidence,
                retire_payload=type(error.returncode) is int and error.returncode>0)
            if deterministic:
                phase_event(edition, date, 'shard_build', 'retry_suppressed', start_page=start,
                            pages=limit, attempt=attempt, failure_receipt=str(matched_failure[1]),
                            error_name=matched_failure[0])
                failure_type = DeterministicBuildInputFailure if missing_input else DeterministicPresentationFailure
                failure = failure_type(error, matched_failure[1])
                failure.error_name = matched_failure[0]
                failure.presentation_continuation_safe = type(error.returncode) is int and error.returncode > 0 and may_retry
                raise failure from error
            # No native protocol currently proves an unmatched exit transient.
            # Keep it unclassified and failed; absence of a matching receipt is
            # never permission to repeat the same command or audit more pages.
            phase_event(edition,date,'shard_build','retry_suppressed',start_page=start,
                        pages=limit,attempt=attempt,reason='no-positive-transient-evidence',
                        failure_receipt=None,requested_failure_receipt=str(receipt),returncode=error.returncode)
            raise error
        check_identity()
        try:
            validate()
        except ValueError as error:
            write_failure_evidence(evidence / 'coverage-error.json', dict(error=str(error)))
            if not retain_failed_shard_diagnostics(shard,evidence): raise
            last_error = error
            print(f'Retrying shard with invalid coverage {edition} start={start} attempt={attempt}/{SHARD_RETRIES}', flush=True)
            continue
        # Successful invocations have no failure evidence to retain.
        (evidence / 'invocation.json').unlink()
        evidence.rmdir()
        return attempt
    raise last_error


def validate_presentation_audit_pages(pages, continue_failed_shards=False):
    if type(continue_failed_shards) is not bool or (continue_failed_shards and pages is None):
        raise ValueError('Shard continuation requires an explicit presentation audit bound')
    if pages is not None and (type(pages) is not int or not 1 <= pages <= (1 << 63)-1):
        raise ValueError('Presentation audit pages must be a positive bounded integer')


def audit_failed_shard(tool, dump, expander, evidence_root, edition, date, start, indexed_pages,
                       pages, workers, now_unix, timeout_args, reviewed_args, check_identity, failure_receipt):
    """Diagnostic range only; the caller always retains the original build failure."""
    validate_presentation_audit_pages(pages)
    if not 0 <= start < indexed_pages: raise ValueError('Invalid failed shard audit boundary')
    count=min(pages,indexed_pages-start)
    root=evidence_root/('presentation-audit-'+uuid.uuid4().hex)
    # The existing audit command creates an absent root and owns its bounded
    # scratch/captures. Never reuse the failed shard or copy its partial records.
    args=[str(dump),str(root),'--expander-root',str(expander),
          '--audit-presentation-errors','--audit-expanded-bytes',str(2*1024*1024),
          '--start-page',str(start),'--limit-pages',str(count),
          '--workers',str(workers),'--now-unix',str(now_unix),*timeout_args,*reviewed_args]
    with build_phase(edition,date,'presentation_diagnostic_continuation',
                     start_page=start,pages=count,indexed_pages=indexed_pages,
                     original_edition_failed=True,publication_created=False,
                     original_failure_receipt=failure_receipt,
                     unrun_prefix_pages=start,unrun_suffix_pages=indexed_pages-start-count,
                     range_complete=False,counters_status='unknown-until-complete-summary',
                     payload_completeness='per-failure-record',output=str(root)) as result:
        check_identity()
        exit_code=0
        try:
            # PreparedBlobTool keeps the original binary guard. The native audit
            # authenticates every source/provider before and after this range.
            tool.run(args,edition,date,'presentation_audit_command',start_page=start,pages=count)
        except subprocess.CalledProcessError as error:
            if error.returncode != 1: raise
            exit_code=1
        finally:
            check_identity()
        row=read_small_json(root/'audit-summary.json',64*1024)
        expected=dict(schema='wikidict.presentation-audit.summary.v1',diagnostic_only=True,
            range_complete=True,failure_index_complete=True,inventory_complete=False,audit_scope='page-range',
            start_page=start,requested_limit=count,selected_end_exclusive=start+count,
            reached_eof=start+count==indexed_pages,
            index_rows_seen=indexed_pages if start+count==indexed_pages else start+count+1,
            semantic_acceptance=False,publication_created=False,error_name=None)
        if not isinstance(row,dict) or any(k not in row or type(row[k]) is not type(v) or row[k]!=v for k,v in expected.items()):
            raise ValueError('Presentation audit did not complete its selected range')
        fields=('selected','dispatched','consumed','skipped','direct_aliases','expansion_fallbacks',
                'compile_attempts','succeeded','failed','failure_records','payload_bytes','report_bytes')
        if any(type(row.get(k)) is not int or row[k]<0 for k in fields):
            raise ValueError('Invalid presentation audit counters')
        # Old v1 summaries had only Writer failures. Accept them without
        # inventing proof that every expansion completed. New fields are atomic.
        input_fields=('expansion_input_failures','presentation_failures','expansion_complete')
        extended=any(k in row for k in input_fields)
        input_failures=0
        presentation_failures=row['failed']
        expansion_complete=None
        if extended:
            if (any(k not in row for k in input_fields) or
                    any(type(row[k]) is not int or row[k]<0 for k in input_fields[:2]) or
                    type(row['expansion_complete']) is not bool):
                raise ValueError('Invalid expansion input audit counters')
            input_failures=row['expansion_input_failures']
            presentation_failures=row['presentation_failures']
            expansion_complete=row['expansion_complete']
            if (row['failed']!=input_failures+presentation_failures or
                    expansion_complete!=(input_failures==0 and row['expansion_fallbacks']==0)):
                raise ValueError('Inconsistent expansion input audit completion')
        if (row['selected']!=count or row['dispatched']!=row['consumed'] or
                count!=row['skipped']+row['direct_aliases']+row['consumed'] or
                row['consumed']!=row['compile_attempts']+row['expansion_fallbacks']+input_failures or
                row['compile_attempts']!=row['succeeded']+presentation_failures or
                row['failed']!=row['failure_records'] or exit_code!=int(row['failed']!=0)):
            raise ValueError('Inconsistent presentation audit completion')
        result.update({k:row[k] for k in fields})
        result.update(expansion_input_failures=input_failures,presentation_failures=presentation_failures,
                      expansion_complete=expansion_complete)
        result.update(range_complete=True,failure_index_complete=True,counters_status='complete-summary',semantic_acceptance=False,
                      summary=str(root/'audit-summary.json'),failure_records_path=str(root/'failures.jsonl'))
        return row


def shard_blob_paths(shard):
    paths = []
    language_root = shard/'languages'
    if language_root.exists():
        if language_root.is_symlink() or not language_root.is_dir():
            raise ValueError('Unsafe shard language directory')
        paths.extend(language_root.iterdir())
    paths.extend(path for path in shard.iterdir() if path.name.endswith(('.wikblb','.wikblb.xz','.wikblb.xz.part')))
    for path in sorted(paths):
        if not stat.S_ISREG(path.lstat().st_mode): raise ValueError(f'Unsafe shard blob: {path}')
        if not path.name.endswith(('.wikblb','.wikblb.xz','.wikblb.xz.part')):
            raise ValueError(f'Unexpected shard blob: {path}')
        yield path


def cleanup_shard_compression_parts(shard):
    for part in list(shard_blob_paths(shard)):
        if not part.name.endswith('.xz.part'): continue
        raw = Path(str(part)[:-8]);target = Path(str(part)[:-5])
        # Never remove a possible sole recovery copy.
        recovery = [p for p in (raw,target) if p.exists()]
        if not recovery or any(not stat.S_ISREG(p.lstat().st_mode) for p in recovery):
            raise ValueError(f'Unresolved shard compression partial: {part}')
        unlink_artifact(part)


def sync_shard_directory(path):
    fd = os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)


def compress_verified_shard(shard):
    """Native verification precedes this; all compressed recovery copies survive merge."""
    cleanup_shard_compression_parts(shard)
    def commit_batch(raws):
        missing = []
        for raw in raws:
            target = Path(str(raw)+'.xz')
            if target.exists():
                if not stat.S_ISREG(target.lstat().st_mode): raise ValueError(f'Unsafe compressed shard: {target}')
                verify_round_trip(raw,target)
            else:
                missing.append(raw)
        if len(missing) > 1:
            compress_small_batch_keep(missing,1024*1024)
        elif missing:
            compress(missing[0],1024*1024,workers=1)
        parents = sorted({raw.parent for raw in raws})
        for raw in raws:
            fd = os.open(Path(str(raw)+'.xz'),os.O_RDONLY|os.O_NOFOLLOW)
            try: os.fsync(fd)
            finally: os.close(fd)
        # Every target and renamed entry is durable before the first raw deletion.
        for parent in parents: sync_shard_directory(parent)
        for raw in raws: unlink_artifact(raw)
        for parent in parents: sync_shard_directory(parent)

    pending = []
    for raw in list(shard_blob_paths(shard)):
        if not raw.name.endswith('.wikblb'): continue
        if raw.stat().st_size > 64*1024:
            commit_batch([raw])
        else:
            pending.append(raw)
            if len(pending) == 128: commit_batch(pending); pending = []
    if pending: commit_batch(pending)


def extraction_cache_args(cache_root, staged):
    if cache_root is None:return []
    cache_root=Path(cache_root).absolute()
    if cache_root.is_symlink() or (cache_root.exists() and not cache_root.is_dir()):
        raise ValueError('Extraction cache root must be a regular directory')
    return ['--extraction-cache-root',str(cache_root),
            '--verified-dump-sha256',staged['dump_sha256'],
            '--verified-index-sha256',staged['index_sha256']]


def build_sharded(dump, staging, workspace, registry, zig, workers, items, now_unix, expansion_workers=None, interwiki_snapshot=None, interwiki_sha=None, auxiliary_snapshots=None, auxiliary_hashes=None, expansion_timeout_ms=None, build_identity=None, page_links_snapshot=None, page_redirects_snapshot=None, raw_shards_path=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical=None, llvm_workers=None, staged_input_root=None, _staged_input_guard=None, presentation_audit_pages=None, retained_roles=None, continue_failed_shards=False, provider_update=None, shard_pages=None):
    interval=selected_shard_pages(shard_pages)
    if retained_roles is not None and (not compress_shards or not isinstance(retained_roles, RetainedNativeToolRoles)):
        raise ValueError('Retained roles require ordinary compressed sharded execution')
    if (retained_roles is not None and (getattr(_PREPARED_SOURCE,'request',None) is not None
            or getattr(_PREPARED_SOURCE,'value',None) is not None)
            and retained_roles.initial_sealed_generation is None and retained_roles.closed_whole_execution is None):
        raise ValueError('Prepared retained custody requires explicit closed execution selection')
    validate_presentation_audit_pages(presentation_audit_pages, continue_failed_shards)
    validate_llvm_workers(llvm_workers)
    if type(compress_shards) is not bool: raise ValueError('Invalid compressed shard mode')
    timeout_args=expansion_deadline_args(expansion_timeout_ms)
    if raw_shards_path is not None:
        raw_shards_path=external_raw_shards(workspace,raw_shards_path,create=True)
        state=read_build_envelope(workspace/'state.json')
        if state.get('raw_shards_path')!=str(raw_shards_path):
            raise ValueError('Raw shard location does not match workspace state')
        cleanup_dead_private_shards(raw_shards_path)
    edition,date=items[0]['wiki'],items[0]['date']
    workers=min(workers,MAX_PIPELINE_WORKERS)
    llvm_workers=workers if llvm_workers is None else llvm_workers
    expansion_workers=workers if expansion_workers is None else expansion_workers
    if type(expansion_workers) is not int or not 1 <= expansion_workers <= MAX_PAGE_EXPANSION_WORKERS:
        raise ValueError('Invalid page expansion worker count')
    initial_reference=getattr(retained_roles, 'initial_sealed_generation', None) if retained_roles is not None else None
    retained_workspace=initial_sealed_generation(initial_reference, retained_roles)[3] if initial_reference is not None else None
    closed_whole=getattr(retained_roles,'closed_whole_execution',None) if retained_roles is not None else None
    if closed_whole is not None:
        if retained_roles.initial_sealed_context!=retained_roles._closed_native_context or retained_roles._closed_whole_workspace_state is None:
            raise ValueError('Closed whole worker has not been adopted')
        retained_workspace=retained_roles._closed_native_context[0].parent.parent
    expander_build=(retained_workspace if retained_workspace is not None else workspace)/'expander'
    page_links_sha=sha256_file(page_links_snapshot) if page_links_snapshot is not None else None
    page_redirects_sha=sha256_file(page_redirects_snapshot) if page_redirects_snapshot is not None else None
    generation=getattr(_PREPARED_SOURCE,'value',None)
    if generation is not None:
        generation.require_identity(build_identity)
        if generation.workspace!=workspace or generation.dump!=dump or generation.root!=expander_build/'.bundle-expander':
            raise ValueError('Retry selected another prepared generation')
    tools=generation.tools if generation is not None else None
    native_snapshots={**(auxiliary_snapshots or {}),**getattr(retained_roles,'staged_provider_inputs',{})}
    figure_inputs=figure_compatibility_paths(auxiliary_snapshots)
    if tools is not None:
        check_figure_compatibility(tools['dict-blob-build'],figure_inputs,edition,date)
    native_ready=True
    writer_transition=getattr(retained_roles, 'writer_figure_transition', None) if retained_roles is not None else None
    worker_auxiliary_hashes=auxiliary_hashes
    if initial_reference is not None:
        worker_auxiliary_hashes=initial_sealed_worker_hashes(auxiliary_hashes,retained_roles.closed_native_origin['identity']['providers'])
    if closed_whole is not None:
        worker_auxiliary_hashes=retained_roles._closed_whole_workspace_state['native_generation']['build_inputs']['auxiliary_snapshot_sha256']
    seal_for_provider_updates=(generation is None and getattr(_PREPARED_SOURCE,'request',None) is None
                               and WIKIBASE_PROVIDER_ROLES <= set(auxiliary_hashes or {}))
    if provider_update:
        if (initial_reference is not None or not seal_for_provider_updates or provider_update['root']!=str(expander_build/'.bundle-expander')
                or provider_update['dump']!=str(dump)):
            raise ValueError('Provider update selected another native generation')
        import extraction_cache as native_cache
        with build_phase(edition,date,'wikibase_provider_update') as update_result:
            native_cache.finish_wikibase_provider_update(provider_update,
                {auxiliary_snapshot_filename(name):auxiliary_hashes[name] for name in WIKIBASE_PROVIDER_ROLES})
            update_result['seal_sha256']=bind_native_generation(workspace,dump,build_identity,updating=True)
            update_result['native_recompiled']=False
    elif generation is None:
        state_path=workspace/'state.json'
        binding=read_build_envelope(state_path).get('native_generation') if state_path.is_file() else None
        if binding is not None:
            import extraction_cache as native_cache
            expected_binding_keys=({'seal_sha256','dump','build_inputs','retained_expander_root','closed_whole_execution'} if closed_whole is not None else {'seal_sha256','dump','build_inputs','retained_expander_root'} if initial_reference is not None else {'seal_sha256','dump','build_inputs','writer_figure_transition'} if writer_transition is not None else {'seal_sha256','dump','build_inputs'})
            if (not isinstance(binding,dict) or set(binding)!=expected_binding_keys
                    or binding['dump']!=str(dump)):
                raise ValueError('Bound ordinary native generation changed')
            if retained_workspace is not None and binding['retained_expander_root']!=str(expander_build/'.bundle-expander'):
                raise ValueError('Retained initial sealed root changed')
            if closed_whole is not None and binding['closed_whole_execution']!=closed_whole:
                raise ValueError('Closed whole native generation history changed')
            if writer_transition is not None:
                if binding['writer_figure_transition']!=writer_transition:
                    raise ValueError('Writer Figure transition binding changed')
                worker_auxiliary_hashes=binding['build_inputs']['auxiliary_snapshot_sha256']
            native_ready=native_cache.frozen_runtime_context(expander_build/'.bundle-expander',dump,binding['seal_sha256'],
                **getattr(retained_roles,'_closed_native_context_options',{})) is not None
    worker_ready=native_ready and expander_ready(expander_build,worker_auxiliary_hashes,interwiki_sha,page_links_sha,page_redirects_sha) if generation is None else True
    if writer_transition is not None and not worker_ready:
        raise ValueError('Selected Writer Figure transition worker changed; existing generation preserved')
    if retained_workspace is not None and not worker_ready:
        raise ValueError('Selected initial sealed worker inputs changed; existing generation preserved')
    if generation is None and not worker_ready:
        if expander_build.exists(): remove_artifact_tree(expander_build)
        staged=read_small_json((staged_input_root if staged_input_root is not None else workspace/'input')/'.complete.json')
        extraction_cache=Path(extraction_cache_root) if extraction_cache_root is not None else workspace/'input'/'extraction-cache'
        tools=prepare_blob_tools(workspace,zig,edition,date,build_identity,
                  expander_args=[str(dump),str(expander_build),
                     *(['--expander-only'] if retained_roles is not None else []),
                     *(['--interwiki-map-snapshot',str(interwiki_snapshot)] if interwiki_snapshot else []),
                     *pipeline_snapshot_args(registry,native_snapshots,page_links_snapshot,page_redirects_snapshot),
                     '--llvm-workers',str(llvm_workers),
                     '--parse-workers',str(min(workers,64)),'--page-workers',str(min(workers,16)),
                     *(['--expander-only'] if retained_roles is None else []),
                     *(['--seal-prepared-source'] if seal_for_provider_updates or getattr(_PREPARED_SOURCE,'request',None) is not None else []),
                     *extraction_cache_args(extraction_cache,staged)], **({'figure_inputs':figure_inputs} if figure_inputs is not None else {}), **({'retained_roles':retained_roles} if retained_roles is not None else {}))
        if seal_for_provider_updates:
            bind_native_generation(workspace,dump,build_identity)
    expander=expander_build/'.bundle-expander'
    with build_phase(edition,date,'page_index_count') as result:
        index_path=expander/'page-index.tsv'
        index=inspect_page_index(index_path, **shard_page_options(shard_pages))
        indexed_pages=index['rows']
        result['pages']=indexed_pages
        result['sha256']=index['sha256']
    def check_shard_inputs():
        require_index_identity(index_path,index)
        if _staged_input_guard is not None:_staged_input_guard()
    cache_record=json.loads(((staged_input_root if staged_input_root is not None else workspace/'input')/'.complete.json').read_text())
    if type(cache_record.get('source_pages')) is not int or cache_record['source_pages']<0:
        raise ValueError('Staged dump lacks a verified source page count')
    if indexed_pages!=cache_record['source_pages']:
        raise ValueError('Page index count differs from staged source pages')
    reviewed_path = None
    if reviewed_nonlexical is not None:
        reviewed_path = nonlexical.materialize(reviewed_nonlexical,dump,index_path,workspace/nonlexical.NAME)
        nonlexical.bind_identity(workspace,build_identity,reviewed_nonlexical)
    reviewed_args = ['--reviewed-nonlexical',str(reviewed_path)] if reviewed_path is not None else []
    writer_input_args = []
    if writer_transition is not None or closed_whole is not None:
        roots={Path(auxiliary_snapshots[name]).parent for name in WRITER_FIGURE_ROLES}
        if len(roots)!=1:raise ValueError('Writer Figure observations require one complete pinned root')
        writer_input_args += ['--figure-input-root',str(roots.pop())]
    writer_input_args += initial_sealed_writer_snapshot_args(initial_reference, closed_whole, auxiliary_snapshots,
        retained_roles.closed_native_origin['identity']['providers'] if initial_reference is not None else None)

    if tools is None:
        tools=prepare_blob_tools(workspace,zig,edition,date,build_identity, **({'figure_inputs':figure_inputs} if figure_inputs is not None else {}), **({'retained_roles':retained_roles} if retained_roles is not None else {}))
    request=getattr(_PREPARED_SOURCE,'request',None)
    if generation is None and request is not None:
        with build_phase(edition,date,'prepared_source_authorization') as authorization:
            generation=request.offer(workspace,dump,tools,build_identity,now_unix)
            authorization['authorized']=generation is not None
        if generation is not None:tools=generation.tools
    blob_builder=tools['dict-blob-build'];verifier=tools['dict-blob-verify'];merger=tools['dict-blob-merge']
    shards_root=raw_shards_path if raw_shards_path is not None else workspace/'shards'
    shards_root.mkdir(exist_ok=True)
    cleanup_dead_private_shards(shards_root)
    # A verified or complete-but-unmarked contiguous prefix is reusable after
    # a crash. The native continuous builder owns only an absent suffix, so it
    # cannot replace an existing shard directory.
    shard_starts=list(range(0,indexed_pages,interval))
    prefix=[]
    for start in ([] if compress_shards else shard_starts):
        shard=shards_root/f'{start:08d}'
        if not shard.exists(): break
        limit=min(interval,indexed_pages-start)
        check_shard_inputs()
        try:
            validate_page_coverage(shard,start,limit,index,index['offsets'][start])
        except ValueError:
            print(f'Rebuilding shard with invalid coverage {items[0]["wiki"]} start={start}',flush=True)
            remove_artifact_tree(shard)
            break
        # A verifier failure can be a transient resource/tool failure. Preserve
        # the existing shard and stop; only invalid coverage permits deletion.
        verifier.run([str(shard)],
                  edition,date,'resume_shard_verify',start_page=start,pages=limit)
        check_shard_inputs()
        marker=shard/'.verified'
        if not marker.is_file(): marker.write_text('verified\n')
        prefix.append(shard)
    missing_starts=shard_starts[len(prefix):]
    shard_paths=list(prefix)
    continuous_handled=not missing_starts
    # A noncontiguous set of completed shards can arise from older builds.
    # Preserve those outputs and use the existing single-shard fallback.
    if presentation_audit_pages is None and not compress_shards and missing_starts and all(not (shards_root/f'{start:08d}').exists() for start in missing_starts):
        first=missing_starts[0]
        check_shard_inputs()
        blob_builder.run([str(dump),str(shards_root),
                   '--expander-root',str(expander),'--start-page',str(first),
                   '--limit-pages',str(indexed_pages-first),
                   '--index-byte-offset',str(index['offsets'][first]),
                   '--shard-pages',str(interval),
                   '--workers',str(expansion_workers),'--now-unix',str(now_unix),*timeout_args,*reviewed_args,*writer_input_args],
                  edition,date,'continuous_shard_build',start_page=first,pages=indexed_pages-first)
        check_shard_inputs()
        for start in missing_starts:
            shard=shards_root/f'{start:08d}'
            limit=min(interval,indexed_pages-start)
            validate_page_coverage(shard,start,limit,index,index['offsets'][start])
            verifier.run([str(shard)],
                      edition,date,'shard_verify',start_page=start,pages=limit)
            (shard/'.verified').write_text('verified\n')
            check_shard_inputs()
        shard_paths=prefix+[shards_root/f'{start:08d}' for start in missing_starts]
        continuous_handled=True
    failed_shards=[]
    if not continuous_handled:
        # The contiguous prefix is already verified and in shard_paths.
        for start in missing_starts:
            limit=min(interval,indexed_pages-start)
            offset=index['offsets'][start]
            check_shard_inputs()
            shard=shards_root/f'{start:08d}'
            marker=shard/'.verified'
            if shard.exists():
                try:
                    validate_page_coverage(shard,start,limit,index,offset)
                except ValueError:
                    print(f'Rebuilding shard with invalid coverage {items[0]["wiki"]} start={start}',flush=True)
                    remove_artifact_tree(shard)
                else:
                    verifier.run([str(shard)],
                              edition,date,'resume_shard_verify',start_page=start,pages=limit)
                    check_shard_inputs()
                    if not marker.is_file(): marker.write_text('verified\n')
                    if compress_shards:
                        with build_phase(edition,date,'shard_compress',start_page=start,pages=limit):
                            compress_verified_shard(shard)
                    shard_paths.append(shard);continue
            native_args=[str(dump),str(shard),
                     '--expander-root',str(expander),'--start-page',str(start),'--limit-pages',str(limit),
                     '--index-byte-offset',str(offset),
                     '--workers',str(expansion_workers),'--now-unix',str(now_unix),*timeout_args,*reviewed_args,*writer_input_args]
            evidence_root=workspace.with_name(workspace.name+'.failures')
            try:
                attempt=build_shard_with_retries(blob_builder,native_args,shard,evidence_root,edition,date,start,limit,
                    lambda:check_shard_inputs(),
                    lambda:validate_page_coverage(shard,start,limit,index,offset))
            except (DeterministicPresentationFailure, DeterministicBuildInputFailure) as failure:
                if presentation_audit_pages is not None and failure.presentation_continuation_safe and failure.error_name in (
                        'UncompiledPresentation','UncompiledTemplate','InvalidPreContext','InvalidHeadingProjection',
                        'InterfaceMessageSnapshotMissing','FileMetadataSnapshotMissing'):
                    def check_audit_inputs():
                        if generation is not None:generation.require_unchanged()
                        check_shard_inputs()
                    # Earlier in-flight pages can remain unconsumed when a later
                    # worker fails. Start at the shard lower bound, never ordinal+1.
                    failure.presentation_audit=lambda receipt=failure.failure_receipt:audit_failed_shard(blob_builder,dump,expander,
                        evidence_root,edition,date,start,indexed_pages,presentation_audit_pages,
                        expansion_workers,now_unix,timeout_args,[*reviewed_args,*writer_input_args],check_audit_inputs,receipt)
                    if continue_failed_shards:
                        # Never extend a failed shard's audit into another shard.
                        # Only this typed, source-bound rejection permits continuation.
                        try:
                            summary=audit_failed_shard(blob_builder,dump,expander,evidence_root,
                                edition,date,start,indexed_pages,min(presentation_audit_pages,limit),
                                expansion_workers,now_unix,timeout_args,[*reviewed_args,*writer_input_args],
                                check_audit_inputs,failure.failure_receipt)
                        except Exception as audit_error:
                            failure.presentation_audit=None
                            failure.add_note('Presentation continuation incomplete: '+str(audit_error))
                            phase_event(edition,date,'presentation_diagnostic_continuation','incomplete',
                                error_type=type(audit_error).__name__,error=str(audit_error),
                                original_failure_receipt=failure.failure_receipt)
                            raise failure from audit_error
                        failure.presentation_audit=None
                        failed_shards.append(failure)
                        failure.presentation_audit_summary=summary
                        phase_event(edition,date,'failed_shard_retained','end',start_page=start,pages=limit,
                            original_failure_receipt=failure.failure_receipt,audit_complete=True,
                            shard_verified=False,publication_created=False)
                        continue
                raise
            # Preserve a completed shard if verification fails because of
            # a transient tool/resource error. The next run revalidates it.
            verifier.run([str(shard)],
                      edition,date,'shard_verify',start_page=start,pages=limit,attempt=attempt)
            check_shard_inputs()
            marker.write_text('verified\n')
            if compress_shards:
                with build_phase(edition,date,'shard_compress',start_page=start,pages=limit):
                    compress_verified_shard(shard)
            shard_paths.append(shard)

    if failed_shards:
        # Incomplete shard sets never enter coverage, merge or publication. Every
        # successful shard keeps its ordinary coverage and verifier marker.
        first=failed_shards[0]
        first.failed_shards=tuple(failed_shards)
        first.add_note('Failed shard receipts: '+', '.join(f.failure_receipt for f in failed_shards))
        phase_event(edition,date,'shard_continuation','failed',failed_shards=len(failed_shards),
                    verified_shards=len(shard_paths),expected_shards=len(shard_starts),
                    original_failure_receipts=[f.failure_receipt for f in failed_shards],
                    coverage_complete=False,publication_created=False)
        raise first
    check_shard_inputs()
    actual_pages=sum(validate_page_coverage(path,start,min(interval,indexed_pages-start),index,index['offsets'][start])['pages_seen']
                     for path,start in zip(shard_paths,range(0,indexed_pages,interval)))
    if actual_pages!=indexed_pages: raise ValueError('Incomplete total shard page coverage')
    coverage=dict(version=1,start_page=0,requested_limit=None,index_byte_offset=0,pages_seen=actual_pages,
                  expected_input_pages=indexed_pages,page_index_identity=index['identity'],page_index_sha256=index['sha256'],page_index_rows=indexed_pages)
    metadata_texts=[json.dumps(coverage,sort_keys=True)+'\n',json.dumps(now_unix)+'\n',VERIFIED_CONTENT]
    if interwiki_snapshot is not None:metadata_texts.append(interwiki_sha+'\n')
    if auxiliary_hashes:metadata_texts.append(json.dumps(auxiliary_hashes,sort_keys=True)+'\n')
    if build_identity is not None:metadata_texts.append(json.dumps(build_identity,sort_keys=True)+'\n')
    if staging.exists(): remove_artifact_tree(staging)
    admission=require_merge_disk_space(shard_paths,staging,BUILD_DISK_RESERVE_BYTES,
        metadata_paths=(expander_build/'compile-plan.tsv',),metadata_texts=metadata_texts,
        **({'reviewed_manifest_path':reviewed_path} if reviewed_path is not None else {}),
        **({'allow_compressed':True,'compressed_output':True} if compress_shards else {}))
    phase_event(edition,date,'merge_disk_admission','admitted',**admission)
    merger.run([*(['--compress-output'] if compress_shards else []),*reviewed_args,str(staging),*[str(path) for path in shard_paths]],
              edition,date,'merge',shards=len(shard_paths))
    verifier.run([str(staging)],
              edition,date,'merged_verify',shards=len(shard_paths))
    (staging/'page-coverage.json').write_text(json.dumps(coverage,sort_keys=True)+'\n')
    if reviewed_path is not None:
        nonlexical.require(nonlexical.read_bytes(reviewed_path)==nonlexical.read_bytes(staging/nonlexical.NAME), 'Native merge execution manifest differs')
        nonlexical.check_coverage(staging,build_identity)
    plan=expander_build/'compile-plan.tsv'
    if plan.is_file(): shutil.copyfile(plan,staging/'compile-plan.tsv')
    if interwiki_snapshot is not None:
        if sha256_file(interwiki_snapshot)!=interwiki_sha:
            raise ValueError('Interwiki map snapshot changed during build')
        (staging/INTERWIKI_SHA_NAME).write_text(interwiki_sha+'\n')
    if auxiliary_hashes or build_identity is not None:
        final_hashes,final_captures=_validated_auxiliary_state(auxiliary_snapshots)
        if auxiliary_hashes:
            if final_hashes!=auxiliary_hashes:
                raise ValueError('Auxiliary snapshot changed during build')
            (staging/AUXILIARY_SHA_NAME).write_text(json.dumps(auxiliary_hashes,sort_keys=True)+'\n')
        if build_identity is not None:
            manifests,artifacts=_project_auxiliary_capture_identities(final_captures)
            if (manifests!=build_identity.get('auxiliary_capture_sha256',{}) or
                    artifacts!=build_identity.get('auxiliary_capture_artifact_sha256',{})):
                raise ValueError('Auxiliary capture changed during build')
    if page_links_snapshot is not None and sha256_file(page_links_snapshot)!=page_links_sha:
        raise ValueError('Derived page links changed during sharded build')
    if page_redirects_snapshot is not None and sha256_file(page_redirects_snapshot)!=page_redirects_sha:
        raise ValueError('Derived page redirects changed during sharded build')
    (staging/NOW_UNIX_NAME).write_text(json.dumps(now_unix)+'\n')
    persist_build_identity(staging,build_identity)
    if _staged_input_guard is not None:_staged_input_guard()
    seal_verified_publication_inventory(staging,**({'fresh_compressed':True} if compress_shards else {}))
    (staging/VERIFIED_MARKER).write_text(VERIFIED_CONTENT)
    if generation is not None:
        request=getattr(_PREPARED_SOURCE,'request',None)
        if request is None:raise ValueError('Missing parent-bound prepared request at finalization')
        with build_phase(edition,date,'prepared_source_finalization'):
            request.finalize(generation,staging)
    # The merged staging tree is now the sole verified publication source.
    # Drop raw shards and the transient expander before XZ publication so peak
    # disk usage is not shards + merged raw + compressed output simultaneously.
    if retained_roles is not None:retained_roles.release_staged_provider_inputs()
    cleanup_shard_workspace(workspace)


def build(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, raw_shard_root=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None, presentation_audit_pages=None, retained_roles=None, continue_failed_shards=False, shard_pages=None):
    selected_shard_pages(shard_pages)
    validate_presentation_audit_pages(presentation_audit_pages, continue_failed_shards)
    selected_staged_input_root(items,staged_input_root,output,raw_shard_root,extraction_cache_root)
    validate_llvm_workers(llvm_workers)
    artifact_path(output)
    if raw_shard_root is not None: artifact_path(raw_shard_root)
    validate_now_unix(now_unix)
    timeout_args=expansion_deadline_args(expansion_timeout_ms)
    for item in items:
        validate_item(item)
    edition, date = items[0]['wiki'], items[0]['date']
    with ExitStack() as owned:
        prepared_request=os.environ.get('WIKIDICT_PREPARED_SOURCE_ATTEMPT')
        if prepared_request is not None:
            owned.enter_context(prepared_source_request(json.loads(prepared_request)))
        try:
            with build_phase(edition,date,'edition_build') as result:
                parent = output / edition
                parent.mkdir(parents=True, exist_ok=True)
                # Keep the inode: deleting lock files permits two independent locks.
                lock=owned.enter_context((parent / (date + '.lock')).open('a'))
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise ValueError(f'Build already running: {parent / date}') from None
                initial_reference = getattr(retained_roles, 'initial_sealed_generation', None) if retained_roles is not None else None
                if initial_reference is not None or getattr(retained_roles,'closed_whole_execution',None) is not None:
                    root=(initial_sealed_generation(initial_reference,retained_roles)[3]/'expander'/'.bundle-expander'
                          if initial_reference is not None else retained_roles._closed_native_context[0])
                    owned.enter_context(acquire_build_resource_lock(root/'.compiler-inputs.lock'))
                # An existing publication is verification-only even when input or
                # publication checks fail before build_locked can return its mode.
                # Legitimate producers share this edition lock; success still overrides.
                if (parent / date / 'complete.json').exists():
                    result['execution_mode']='existing_output'
                mode=build_locked(items, downloads, output, zig, compression_workers, expansion_workers, interwiki_snapshot, auxiliary_snapshots, **({'expansion_timeout_ms':expansion_timeout_ms} if expansion_timeout_ms is not None else {}), **({'now_unix':now_unix} if now_unix is not None else {}), **({'raw_shard_root':raw_shard_root} if raw_shard_root is not None else {}), **({'compress_shards':True} if compress_shards else {}), **({'extraction_cache_root':extraction_cache_root} if extraction_cache_root is not None else {}), reviewed_nonlexical_review=reviewed_nonlexical_review, **({'llvm_workers':llvm_workers} if llvm_workers is not None else {}), **({'staged_input_root':staged_input_root} if staged_input_root is not None else {}), **({'presentation_audit_pages':presentation_audit_pages} if presentation_audit_pages is not None else {}), **({'continue_failed_shards':True} if continue_failed_shards else {}), **({'retained_roles':retained_roles} if retained_roles is not None else {}), **shard_page_options(shard_pages))
                result['execution_mode']=mode
                return mode
        except (DeterministicPresentationFailure, DeterministicBuildInputFailure) as failure:
            if failure.presentation_audit is not None:
                try:
                    failure.presentation_audit()
                except Exception as audit_error:
                    # The typed failure remains the final edition result. An
                    # incomplete audit is explicit, including resource/I/O/input
                    # errors; both exceptions and original capture are retained.
                    failure.add_note('Presentation continuation incomplete: '+str(audit_error))
                    phase_event(edition,date,'presentation_diagnostic_continuation','incomplete',
                                error_type=type(audit_error).__name__,error=str(audit_error),
                                original_failure_receipt=failure.failure_receipt)
                    raise failure from audit_error
            raise


FALLBACK_REPORT_NAME = 'fallback-pages.jsonl'
FALLBACK_GZIP_NAME = FALLBACK_REPORT_NAME + '.gz'
FALLBACK_GZIP_MIN_BYTES = 1024 * 1024


def published_fallback_report(metadata):
    name = metadata.get('fallback_report')
    decoded = metadata.get('fallback_report_decoded')
    if name == FALLBACK_REPORT_NAME and 'fallback_report_decoded' not in metadata:
        return name, None
    if (name == FALLBACK_GZIP_NAME and isinstance(decoded, dict) and set(decoded) == {'size', 'sha256'}
            and type(decoded['size']) is int and decoded['size'] > 0
            and isinstance(decoded['sha256'], str) and re.fullmatch('[0-9a-f]{64}', decoded['sha256'])):
        return name, decoded
    raise ValueError('Invalid publication fallback report declaration')


def open_fallback_report(path, mode):
    options = {'encoding': 'utf-8'} if mode == 'rt' else {}
    if path.name == FALLBACK_GZIP_NAME:
        return gzip.open(path, mode, **options)
    return path.open(mode, **options)


def require_decoded_fallback_report(path, expected):
    before = index_identity(path.stat())
    digest = hashlib.sha256()
    size = 0
    try:
        with gzip.open(path, 'rb') as stream:
            while block := stream.read(min(1024 * 1024, expected['size'] - size + 1)):
                size += len(block)
                if size > expected['size']:
                    raise ValueError('Decoded fallback report exceeds its sealed size')
                digest.update(block)
    except (OSError, EOFError, zlib.error) as error:
        raise ValueError('Invalid gzip fallback report') from error
    if (size != expected['size'] or digest.hexdigest() != expected['sha256']
            or index_identity(path.stat()) != before):
        raise ValueError('Decoded fallback report differs from its sealed bytes')


def compress_publication_fallback(root, expected):
    raw = artifact_path(root / FALLBACK_REPORT_NAME)
    target = artifact_path(root / FALLBACK_GZIP_NAME)
    part = artifact_path(root / (FALLBACK_GZIP_NAME + '.part'))
    before = index_identity(raw.stat())
    with part.open('xb') as output:
        try:
            with raw.open('rb') as source, gzip.GzipFile(filename='', mode='wb', fileobj=output, compresslevel=1, mtime=0) as archive:
                shutil.copyfileobj(source, archive, length=1024 * 1024)
            output.flush()
            os.fsync(output.fileno())
            require_decoded_fallback_report(part, expected)
            if index_identity(raw.stat()) != before:
                raise ValueError('Plain fallback report changed during compression')
            record = {'size': part.stat().st_size, 'sha256': sha256_file(part)}
            if record['size'] >= expected['size']:
                return None
            os.replace(part, target)
            sync_shard_directory(root)
            return record
        finally:
            unlink_artifact(part, missing_ok=True)


def validate_fallback_report(path, namespace_counts=None, reason_counts=None):
    if not path.is_file():
        raise ValueError(f'Missing fallback report: {path}')
    reasons_seen = {}
    titles_by_namespace = defaultdict(set)
    with open_fallback_report(path, 'rt') as lines:
        for line_number, line in enumerate(lines, 1):
            if not line.strip():
                raise ValueError(f'Blank fallback report record at {path}:{line_number}')
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f'Invalid fallback report JSON at {path}:{line_number}: {error.msg}') from None
            namespace = record.get('namespace') if isinstance(record, dict) else None
            title = record.get('title') if isinstance(record, dict) else None
            reasons = record.get('reasons') if isinstance(record, dict) else None
            if type(namespace) is not int or namespace < 0 or not isinstance(title, str):
                raise ValueError(f'Invalid fallback page identity at {path}:{line_number}')
            if not isinstance(reasons, list) or not reasons or any(not isinstance(reason, str) or not reason for reason in reasons):
                raise ValueError(f'Invalid fallback reasons at {path}:{line_number}')
            if len(set(reasons)) != len(reasons):
                raise ValueError(f'Duplicate fallback reason at {path}:{line_number}')
            for reason in reasons:
                if not reason.startswith('expansion_error:'):
                    continue
                parts = reason.split(':')
                if len(parts) in (2, 3) and parts[-1] in ('Timeout', 'OutOfMemory'):
                    kind = 'timeout' if parts[-1] == 'Timeout' else 'out of memory'
                    raise ValueError(f'Operational expansion {kind} at {path}:{line_number}; rebuild this output')
                if len(parts) == 3 and parts[1] != 'expand':
                    raise ValueError(f'Infrastructure expansion failure at {path}:{line_number}; rebuild this output')
            titles = titles_by_namespace[namespace]
            if title in titles:
                raise ValueError(f'Duplicate fallback page at {path}:{line_number}: {namespace}:{title}')
            titles.add(title)
            for reason in reasons:
                reasons_seen[reason] = reasons_seen.get(reason, 0) + 1
    if namespace_counts is not None:
        # Commit the output only after the complete report is valid.
        namespace_counts.clear()
        namespace_counts.update((ns, len(titles)) for ns, titles in titles_by_namespace.items())
    if reason_counts is not None:
        # Reasons overlap across pages; these counts are not an acceptance verdict.
        reason_counts.clear()
        reason_counts.update(reasons_seen)
    return sum(map(len, titles_by_namespace.values()))

BUILD_IDENTITY_NAME = '.build-inputs.json'
VERIFIED_MARKER = '.verified-blobs'
VERIFIED_INVENTORY_NAME = '.verified-publication-inventory.json'
INTERWIKI_SHA_NAME = '.interwiki-map.sha256'
AUXILIARY_SHA_NAME = '.auxiliary-snapshots.sha256.json'
NOW_UNIX_NAME = '.build-now-unix.json'
# Bump this when page framing, member encoding or index semantics change; the
# input cache identity and published artifacts both include this contract.
DUMP_STAGING_VERSION = 'page-aligned-zstd-parallel-v2'
VERIFIED_CONTENT = f'dump-staging-version={DUMP_STAGING_VERSION}\n'

def require_current_staging_version(path, version):
    if version != DUMP_STAGING_VERSION:
        raise ValueError(f'Outdated dump staging at {path}; rebuild in a new output directory (existing output preserved)')

def publication_inventory(root, *, allow_raw=False, allow_fallback_pair=False):
    """Pin verified data bytes so resume cannot bless missing or changed output."""
    required={'languages.tsv','page-coverage.json','namespace-coverage.json'}
    fallback_names={FALLBACK_REPORT_NAME,FALLBACK_GZIP_NAME}
    metadata=required|fallback_names|{nonlexical.NAME,'compile-plan.tsv','module-compile-plan.tsv',BUILD_IDENTITY_NAME,
                       INTERWIKI_SHA_NAME,AUXILIARY_SHA_NAME,NOW_UNIX_NAME,NATIVE_ROLE_DETAILS_NAME}
    if root.is_symlink() or not root.is_dir():raise ValueError('Unsafe publication directory')
    pending=[root];files=[]
    while pending:
        for path in pending.pop().iterdir():
            name=path.relative_to(root).as_posix()
            if path.is_symlink():raise ValueError('Unsafe publication artifact: '+name)
            if path.is_dir():
                # Reader indexes live beside root feature blobs or language blobs.
                if name in ('.dict-cache','languages/.dict-cache'):continue
                if path.name=='.bundle-expander':raise ValueError('Transient compiler tree in publication')
                pending.append(path)
            else:files.append(path)
    inventory={}
    for path in sorted(files):
        name=path.relative_to(root).as_posix()
        if path.is_symlink():raise ValueError('Unsafe publication artifact: '+name)
        if name in ('complete.json',VERIFIED_MARKER,VERIFIED_INVENTORY_NAME):continue
        if not path.is_file() or (name not in metadata and not name.endswith('.wikblb.xz') and
                                  not (allow_raw and name.endswith('.wikblb'))):
            raise ValueError('Unexpected publication artifact: '+name)
        before=index_identity(path.stat())
        digest=sha256_file(path)
        if index_identity(path.stat())!=before:raise ValueError('Publication artifact changed while reading: '+name)
        inventory[name]={'size':before['size'],'sha256':digest}
    if NATIVE_ROLE_DETAILS_NAME in inventory:
        identity = read_small_json(root/BUILD_IDENTITY_NAME, BUILD_ENVELOPE_MAX_BYTES)
        reference = identity.get(NATIVE_ROLE_DETAILS_KEY) if isinstance(identity, dict) else None
        restore_publication_build_identity(root, identity)
        if (not isinstance(reference, dict) or inventory[NATIVE_ROLE_DETAILS_NAME] != {
                'size': reference['size'], 'sha256': reference['sha256']}):
            raise ValueError('Unbound native role detail publication member')
    elif (root/BUILD_IDENTITY_NAME).is_file():
        read_build_envelope(root/BUILD_IDENTITY_NAME)
    fallback_members=fallback_names.intersection(inventory)
    if not required.issubset(inventory) or not fallback_members:
        raise ValueError('Missing required publication report or language manifest')
    if len(fallback_members) != 1 and not allow_fallback_pair:
        raise ValueError('Multiple published fallback reports')
    return inventory

def seal_verified_publication_inventory(staging, *, fresh_compressed=False):
    """Seal native-verified logical bytes before compression can remove raw twins."""
    files=publication_inventory(staging,allow_raw=True)
    if FALLBACK_REPORT_NAME not in files:
        raise ValueError('Initial verified inventory requires a plain fallback report')
    if type(fresh_compressed) is not bool:raise ValueError('Invalid fresh compressed seal mode')
    if not fresh_compressed and any(name.endswith('.wikblb.xz') for name in files):
        raise ValueError('Cannot establish verified inventory from compressed leftovers')
    if fresh_compressed:
        # Only the fresh merge path calls this, immediately after ordinary deep
        # verification. Resume continues to require the existing sealed inventory.
        if any((staging/name).exists() for name in (VERIFIED_MARKER,VERIFIED_INVENTORY_NAME,'complete.json')):
            raise ValueError('Cannot reseal existing publication as fresh compressed output')
        kinds={name+'.wikblb':kind for kind,name in enumerate(
            ('thesaurus','citations','reconstruction','rhymes','sign-gloss','supplemental','aliases'),2)}
        with (staging/'languages.tsv').open('rb') as source:manifest=source.read(16*1024*1024+1)
        lines=manifest.splitlines()
        if len(manifest)>16*1024*1024 or not lines or lines[0]!=b'heading' or any(not line for line in lines[1:]) or len(set(lines[1:]))!=len(lines[1:]):
            raise ValueError('Invalid fresh compressed language manifest')
        expected={'languages/'+hashlib.sha256(heading).hexdigest()+'.wikblb':1 for heading in lines[1:]}
        expected.update({name:kind for name,kind in kinds.items() if name+'.xz' in files})
        blobs={name for name in files if name.endswith(('.wikblb','.wikblb.xz'))}
        if blobs!={name+'.xz' for name in expected}:
            raise ValueError('Unexpected or missing fresh compressed payload')
        logical={name:record for name,record in files.items() if name not in blobs}
        for name,kind in expected.items():
            target=artifact_path(staging/(name+'.xz'));before=index_identity(target.stat())
            size=compressed_blob_size(target,kind)
            decoded=verified_xz_record(target,size)
            if decoded['size']!=size or index_identity(target.stat())!=before:
                raise ValueError('Fresh compressed payload changed while reading: '+name)
            logical[name]=decoded
        if publication_inventory(staging,allow_raw=True)!=files:
            raise ValueError('Fresh compressed publication changed while sealing')
        files=logical
    raw=json.dumps({'version':1,'files':files},sort_keys=True).encode()+b'\n'
    if len(raw)>8*1024*1024:raise ValueError('Verified publication inventory exceeds bound')
    path=artifact_path(staging/VERIFIED_INVENTORY_NAME)
    with path.open('xb') as out:
        out.write(raw);out.flush();os.fsync(out.fileno())
    if fresh_compressed:sync_shard_directory(staging)


def verified_xz_record(path, expected_size):
    """Reuse strict XZ decoding, with bounded logical output and diagnostics."""
    child=subprocess.Popen(['xz','--format=xz','--decompress','--stdout','--threads=1',
                            '--memlimit-decompress=64MiB','--',str(path)],
                           stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    errors=bytearray();stderr_overflow=threading.Event()
    def capture_errors():
        while block:=child.stderr.read(4096):
            if len(errors)+len(block)>64*1024:
                stderr_overflow.set()
                try:child.terminate()
                except ProcessLookupError:pass
                return
            errors.extend(block)
    reader=threading.Thread(target=capture_errors,daemon=True)
    size=0;digest=hashlib.sha256()
    try:
        reader.start()
        while block:=child.stdout.read(min(1024*1024,expected_size-size+1)):
            size+=len(block)
            if size>expected_size:raise ValueError('Verified decoded payload exceeds sealed size: '+str(path))
            digest.update(block)
        status=child.wait();reader.join(timeout=5)
        if reader.is_alive():raise ValueError('Verified XZ diagnostic reader did not close')
        if stderr_overflow.is_set():raise ValueError('Verified XZ decoder stderr exceeds bound')
        if status!=0:raise ValueError('Invalid verified compressed payload: '+str(path)+'; '+errors.decode('utf-8','replace'))
        return {'size':size,'sha256':digest.hexdigest()}
    finally:
        if child.poll() is None:
            child.terminate()
            try:child.wait(timeout=5)
            except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
        if reader.ident is not None:reader.join(timeout=5)
        child.stdout.close();child.stderr.close()


def validate_verified_publication_inventory(staging, verified_compressed=None):
    expected, checked, _ = _verified_publication_inventories(staging, verified_compressed, allow_raw=True)
    return expected, checked


def _verified_publication_inventories(staging, verified_compressed, *, allow_raw):
    """Return the logical seal, checked XZ members and the physical inventory checked against them."""
    path=artifact_path(staging/VERIFIED_INVENTORY_NAME)
    if not path.is_file() or path.is_symlink():
        raise ValueError('Verified staging lacks its sealed inventory; preserve and rebuild separately')
    before=index_identity(path.stat());saved=read_small_json(path,8*1024*1024)
    if index_identity(path.stat())!=before:raise ValueError('Verified inventory changed while reading')
    if not isinstance(saved,dict) or set(saved)!={'version','files'} or type(saved['version']) is not int or saved['version']!=1 or not isinstance(saved['files'],dict):
        raise ValueError('Invalid verified publication inventory')
    expected=saved['files'];actual=publication_inventory(staging,allow_raw=allow_raw,allow_fallback_pair=True);allowed=set()
    verified_compressed=verified_compressed or {};checked={}
    for name,record in expected.items():
        relative=Path(name)
        if (not isinstance(name,str) or relative.is_absolute() or '..' in relative.parts or
                relative.as_posix()!=name or not isinstance(record,dict) or set(record)!={'size','sha256'} or
                type(record['size']) is not int or record['size']<0 or not isinstance(record['sha256'],str) or
                not re.fullmatch('[0-9a-f]{64}',record['sha256']) or name.endswith('.wikblb.xz')):
            raise ValueError('Invalid verified publication member')
        allowed.add(name)
        if name == FALLBACK_REPORT_NAME and FALLBACK_GZIP_NAME in actual:
            allowed.add(FALLBACK_GZIP_NAME)
            if actual[FALLBACK_GZIP_NAME]['size'] >= record['size']:
                raise ValueError('Gzip fallback report is not smaller than the sealed plain report')
            if name in actual and actual[name] != record:
                raise ValueError('Verified plain fallback report changed')
            require_decoded_fallback_report(staging / FALLBACK_GZIP_NAME, record)
            continue
        if not name.endswith('.wikblb'):
            if actual.get(name)!=record:raise ValueError('Verified publication metadata changed: '+name)
            continue
        compressed=name+'.xz';allowed.add(compressed)
        if name not in actual and compressed not in actual:raise ValueError('Missing verified payload: '+name)
        if name in actual and actual[name]!=record:raise ValueError('Verified raw payload changed: '+name)
        if compressed in actual:
            if actual[compressed]!=verified_compressed.get(compressed):
                target=artifact_path(staging/compressed);before=index_identity(target.stat())
                decoded=verified_xz_record(target,record['size'])
                if index_identity(target.stat())!=before:raise ValueError('Verified compressed payload changed while reading')
                if decoded!=record:
                    raise ValueError('Verified decoded payload changed: '+name)
            checked[compressed]=actual[compressed]
    if set(actual)-allowed:raise ValueError('Unexpected member in verified staging')
    required={'languages.tsv','page-coverage.json','namespace-coverage.json','fallback-pages.jsonl'}
    if not required.issubset(expected):raise ValueError('Verified inventory misses publication metadata')
    return expected, checked, actual


def validate_namespace_coverage(root, expected_rows, namespace_snapshot=None, fallback_counts=None, site_info_snapshot=None):
    if type(expected_rows) is not int or expected_rows<0:raise ValueError('Missing expected namespace row count')
    path=root/'namespace-coverage.json'
    try:report=read_small_json(path,8*1024*1024)
    except (OSError,ValueError,json.JSONDecodeError) as error:raise ValueError('Missing or invalid namespace coverage') from error
    if not isinstance(report,dict) or report.get('version') not in (1,2) or not isinstance(report.get('namespaces'),list):raise ValueError('Invalid namespace coverage')
    expected_routes=None
    if namespace_snapshot is not None:
        expected_hash=sha256_file(Path(namespace_snapshot))
        if report.get('registry_sha256')!=expected_hash:raise ValueError('Namespace coverage registry mismatch')
        expected_routes={}
        for line in Path(namespace_snapshot).read_text(encoding='utf-8').splitlines():
            if not line or line.startswith('#'):continue
            columns=line.split('\t')
            if len(columns)<10:raise ValueError('Invalid namespace registry row')
            ns=int(columns[0]);role=columns[8]
            kind={'main':'language','compile_only':None,'supplemental':'supplemental','rhymes':'rhymes','thesaurus':'thesaurus','citations':'citations','sign_gloss':'sign_gloss','reconstruction':'reconstruction'}.get(role,'INVALID')
            if ns in expected_routes or kind=='INVALID':raise ValueError('Invalid namespace registry routing')
            expected_routes[ns]=(columns[1],kind)
    counters=('input_rows','compile_only_rows','source_unavailable_rows','dispatched_rows','expanded_pages','fallback_pages','duplicate_rows')
    if report['version']==2:counters+=('reviewed_nonlexical_rows',)
    alias_fields=['alias_pages' in row for row in report['namespaces'] if isinstance(row,dict)]
    if alias_fields and any(alias_fields)!=all(alias_fields):raise ValueError('Mixed alias coverage schema')
    if alias_fields and all(alias_fields):counters+=('alias_pages',)
    metadata_fields=['site_metadata_rows' in row for row in report['namespaces'] if isinstance(row,dict)]
    if metadata_fields and any(metadata_fields)!=all(metadata_fields):raise ValueError('Mixed site metadata coverage schema')
    if metadata_fields and all(metadata_fields):counters+=('site_metadata_rows',)
    metadata_rows=sum(row.get('site_metadata_rows',0) for row in report['namespaces'] if isinstance(row,dict) and type(row.get('site_metadata_rows',0)) is int)
    if metadata_rows:
        if site_info_snapshot is None:raise ValueError('Site metadata coverage requires pinned site info')
        site=read_small_json(Path(site_info_snapshot),1024*1024)
        general=site.get('query',{}).get('general',{})
        if (site.get('schema')!='wikidict.site-info.v2' or
                not isinstance(general.get('mainpage'),str) or not general['mainpage'] or
                general.get('wikiid')!=site.get('wiki') or
                site.get('namespace_registry_sha256')!=report.get('registry_sha256') or
                sha256_file(Path(site_info_snapshot))!=report.get('site_info_sha256')):
            raise ValueError('Site metadata coverage authority differs')
    elif report.get('site_info_sha256') is not None:raise ValueError('Unused site metadata authority')
    totals={key:0 for key in counters};seen=set()
    for row in report['namespaces']:
        if not isinstance(row,dict):raise ValueError('Invalid namespace coverage row')
        ns=row.get('id');name=row.get('name');kind=row.get('kind')
        if type(ns) is not int or not 0<=ns<2**32 or ns in seen or not isinstance(name,str):raise ValueError('Invalid namespace coverage identity')
        if kind not in (None,'language','thesaurus','citations','reconstruction','rhymes','sign_gloss','supplemental'):raise ValueError('Invalid namespace coverage routing')
        if expected_routes is not None and expected_routes.get(ns)!=(name,kind):raise ValueError('Namespace coverage routing differs from registry')
        seen.add(ns)
        for key in counters:
            value=row.get(key)
            if type(value) is not int or not 0<=value<2**64:raise ValueError('Invalid namespace coverage counter')
            totals[key]+=value
        if row['input_rows']!=row['compile_only_rows']+row['source_unavailable_rows']+row.get('site_metadata_rows',0)+row.get('reviewed_nonlexical_rows',0)+row['dispatched_rows'] or row['dispatched_rows']!=row['expanded_pages']+row['fallback_pages']+row['duplicate_rows']:raise ValueError('Incomplete namespace coverage')
        if row.get('site_metadata_rows',0) and (ns!=0 or kind!='language'):raise ValueError('Invalid site metadata coverage disposition')
        if row.get('alias_pages',0)>row['expanded_pages']+row['fallback_pages'] or (kind is None and row.get('alias_pages',0)):raise ValueError('Invalid alias coverage subset')
        if (kind is None and row['input_rows']!=row['compile_only_rows']) or (kind is not None and row['compile_only_rows']!=0):raise ValueError('Invalid namespace coverage disposition')
        if (kind=='language')!=(ns==0) or (ns==0)!=(name==''):raise ValueError('Invalid main namespace coverage')
        if fallback_counts is not None and row['fallback_pages']!=fallback_counts.get(ns,0):
            raise ValueError(f'Namespace fallback counts differ from fallback report: {ns}')
    if fallback_counts is not None and set(fallback_counts)-seen:
        raise ValueError('Fallback report names namespace absent from coverage')
    if totals['input_rows']!=expected_rows:raise ValueError('Namespace coverage does not match selected rows')
    return totals


def _publish_verified_staging(staging, target, edition, date, compression_workers=None, interwiki_sha=None, auxiliary_hashes=None, build_identity=None, namespace_snapshot=None, site_info_snapshot=None, _staged_input_guard=None):
    marker = staging / VERIFIED_MARKER
    if not marker.is_file():
        raise ValueError(f'Unverified staging directory: {staging}')
    if marker.read_text() != VERIFIED_CONTENT:
        require_current_staging_version(staging, None)
    if build_identity is not None:
        require_build_identity(read_build_envelope(staging/BUILD_IDENTITY_NAME) if (staging/BUILD_IDENTITY_NAME).is_file() else None,build_identity)
        require_build_source(build_identity)
    recorded=read_snapshot_sha(staging/INTERWIKI_SHA_NAME) if (staging/INTERWIKI_SHA_NAME).is_file() else None
    if recorded!=interwiki_sha:
        raise ValueError('Verified staging uses a different interwiki map snapshot')
    auxiliary_record=read_small_json(staging/AUXILIARY_SHA_NAME) if (staging/AUXILIARY_SHA_NAME).is_file() else {}
    if auxiliary_record!=(auxiliary_hashes or {}):
        raise ValueError('Verified staging uses different auxiliary snapshots')
    recorded_now=read_small_json(staging/NOW_UNIX_NAME) if (staging/NOW_UNIX_NAME).is_file() else None
    validate_now_unix(recorded_now)
    coverage=validate_page_coverage(staging,require_total=True)
    fallback_raw = staging / FALLBACK_REPORT_NAME
    fallback_gzip = staging / FALLBACK_GZIP_NAME
    def checked_inventory():
        fallback_part = staging / (FALLBACK_GZIP_NAME + '.part')
        if os.path.lexists(fallback_part):
            if (fallback_part.is_symlink() or not fallback_part.is_file()
                    or fallback_raw.is_symlink() or not fallback_raw.is_file()):
                raise ValueError('Unresolved fallback compression partial')
            unlink_artifact(fallback_part)
        for part in staging.rglob('*.xz.part'):
            unlink_artifact(part)
        return validate_verified_publication_inventory(staging)
    # On gzip-only resume, authenticate and bound decoded bytes before reading
    # report records. Plain staging keeps the original validation order.
    fallback_path = fallback_gzip if not fallback_raw.exists() and fallback_gzip.is_file() else fallback_raw
    authenticated = checked_inventory() if fallback_path == fallback_gzip else None
    fallback_counts = {}
    fallback_reasons = {}
    fallback_pages = validate_fallback_report(fallback_path, fallback_counts, fallback_reasons)
    namespace_totals=validate_namespace_coverage(staging,coverage['pages_seen'],namespace_snapshot,fallback_counts,site_info_snapshot)
    nonlexical.check_coverage(staging,build_identity)
    if namespace_snapshot is not None and namespace_totals['fallback_pages']!=fallback_pages:raise ValueError('Namespace fallback totals differ from fallback report')
    sealed,checked_compressed=authenticated if authenticated is not None else checked_inventory()
    if _staged_input_guard is not None:_staged_input_guard()
    if build_identity is not None:
        # Only authenticated merged bytes may replace the owned shard recovery copies.
        # Retire them before XZ, including a resume after earlier cleanup failed.
        cleanup_shard_workspace(target.with_name(date+'.shards'))
    raw = sorted(staging.rglob('*.wikblb'))
    logical = {name + '.xz' for name in sealed if name.endswith('.wikblb')}
    pending = []
    for blob in raw:
        compressed_path = Path(str(blob) + '.xz')
        if compressed_path.exists():
            verify_round_trip(blob, compressed_path)
            unlink_artifact(blob)
        else:
            pending.append(blob)
    if pending:
        workers = compression_workers or default_build_threads()
        compress_many(pending, 1024*1024, workers)
    # Record the same physical bytes whose decoded contents passed the logical seal.
    _, compressed, inventory = _verified_publication_inventories(staging, checked_compressed, allow_raw=False)
    # Reader index directories are excluded from the manifest. A misplaced blob
    # there must still prevent staging from becoming a finished dictionary.
    for cache in (staging/'.dict-cache', staging/'languages'/'.dict-cache'):
        if cache.is_dir() and any(member.name.endswith(('.wikblb', '.wikblb.xz', '.xz.part'))
                                  for member in cache.rglob('*')):
            raise ValueError(f'Unexpected publication payload in reader indexes: {cache}')
    if compressed.keys() != logical:
        raise ValueError(f'Incomplete compressed publication: {staging}')
    fallback_decoded = sealed[FALLBACK_REPORT_NAME]
    if FALLBACK_GZIP_NAME not in inventory and fallback_decoded['size'] >= FALLBACK_GZIP_MIN_BYTES:
        gzip_member = compress_publication_fallback(staging, fallback_decoded)
        if gzip_member is not None: inventory[FALLBACK_GZIP_NAME] = gzip_member
    fallback_name = FALLBACK_REPORT_NAME
    if FALLBACK_GZIP_NAME in inventory:
        fallback_name = FALLBACK_GZIP_NAME
        if FALLBACK_REPORT_NAME in inventory:
            fd = os.open(fallback_gzip, os.O_RDONLY | os.O_NOFOLLOW)
            try: os.fsync(fd)
            finally: os.close(fd)
            # On resume the archive rename may not have reached the directory
            # yet. Make it durable before retiring the plain recovery copy.
            sync_shard_directory(staging)
            unlink_artifact(fallback_raw)
            sync_shard_directory(staging)
            del inventory[FALLBACK_REPORT_NAME]
    metadata = {'edition':edition,'date':date,'dump_staging_version':DUMP_STAGING_VERSION,
        'dump_codec':'zstd','dump_stream_kind':'multistream-zstd',
        'status':'built' if compressed else 'empty', 'fallback_pages':fallback_pages,
        'fallback_reason_counts':fallback_reasons,
        'fallback_report':fallback_name, 'compression':'xz -0; 1 MiB blocks','blobs':len(compressed),
        'input_pages':coverage['pages_seen'],'page_coverage_report':'page-coverage.json',
        'namespace_coverage_report':'namespace-coverage.json','namespace_coverage_totals':namespace_totals,
        'publication_files':inventory}
    if fallback_name == FALLBACK_GZIP_NAME: metadata['fallback_report_decoded'] = fallback_decoded
    if build_identity is not None:metadata['build_inputs']=publication_build_identity(staging, build_identity)
    if recorded_now is not None: metadata['now_unix']=recorded_now
    if interwiki_sha is not None: metadata['interwiki_map_sha256']=interwiki_sha
    if auxiliary_hashes: metadata['auxiliary_snapshot_sha256']=auxiliary_hashes
    if _staged_input_guard is not None:_staged_input_guard()
    (staging / 'complete.json').write_text(json.dumps(metadata)+'\n')
    os.rename(staging, target)
    unlink_artifact(target/VERIFIED_MARKER)
    unlink_artifact(target/VERIFIED_INVENTORY_NAME)
    print(f'Published: {target}', flush=True)
    return len(compressed),fallback_pages


def publish_verified_staging(staging, target, edition, date, compression_workers=None, interwiki_sha=None, auxiliary_hashes=None, build_identity=None, namespace_snapshot=None, site_info_snapshot=None, _staged_input_guard=None):
    with build_phase(edition,date,'publish') as result:
        blobs,fallback_pages=_publish_verified_staging(staging,target,edition,date,compression_workers,interwiki_sha,auxiliary_hashes,build_identity,namespace_snapshot,site_info_snapshot,**({'_staged_input_guard':_staged_input_guard} if _staged_input_guard is not None else {}))
        result.update(blobs=blobs,fallback_pages=fallback_pages)

def build_locked(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, raw_shard_root=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None, presentation_audit_pages=None, retained_roles=None, continue_failed_shards=False, shard_pages=None):
    selected_shard_pages(shard_pages)
    if retained_roles is not None and not isinstance(retained_roles,RetainedNativeToolRoles):
        raise ValueError('Invalid retained native input guards')
    validate_presentation_audit_pages(presentation_audit_pages, continue_failed_shards)
    with borrowed_staged_input(items,staged_input_root,output,raw_shard_root,extraction_cache_root) as (borrowed,check):
        def input_guard():
            if check is not None:check()
            if retained_roles is not None:
                if retained_runtime_scope(retained_roles) is not None:
                    retained_roles.require_unchanged()
                else:
                    retained_roles.require_inputs_unchanged()
        try:
            return _build_locked(items,downloads,output,zig,compression_workers,expansion_workers,
            interwiki_snapshot,auxiliary_snapshots,expansion_timeout_ms,now_unix,raw_shard_root,
            compress_shards,extraction_cache_root,reviewed_nonlexical_review,llvm_workers,borrowed,input_guard,
            **({'presentation_audit_pages':presentation_audit_pages} if presentation_audit_pages is not None else {}), **({'continue_failed_shards':True} if continue_failed_shards else {}), **({'retained_roles':retained_roles} if retained_roles is not None else {}), **shard_page_options(shard_pages))

        finally:
            input_guard()


def _build_locked(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, raw_shard_root=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None, _staged_input_guard=None, presentation_audit_pages=None, retained_roles=None, continue_failed_shards=False, shard_pages=None):
    interval=selected_shard_pages(shard_pages)
    if retained_roles is not None and (not compress_shards or not isinstance(retained_roles, RetainedNativeToolRoles)):
        raise ValueError('Retained roles require ordinary compressed sharded execution')
    if (retained_roles is not None and (getattr(_PREPARED_SOURCE,'request',None) is not None
            or getattr(_PREPARED_SOURCE,'value',None) is not None)
            and retained_roles.initial_sealed_generation is None and retained_roles.closed_whole_execution is None):
        raise ValueError('Prepared retained custody requires explicit closed execution selection')
    validate_presentation_audit_pages(presentation_audit_pages, continue_failed_shards)
    validate_llvm_workers(llvm_workers)
    validate_now_unix(now_unix)
    if extraction_cache_root is not None:
        if not Path(extraction_cache_root).is_dir():raise ValueError('Explicit extraction cache root must exist')
        extraction_cache_args(extraction_cache_root,{'dump_sha256':'','index_sha256':''})
    for item in items:validate_item(item)
    timeout_args=expansion_deadline_args(expansion_timeout_ms)
    phase_edition,phase_date=phase_identity(items)
    with build_phase(phase_edition,phase_date,'auxiliary_validation'):
        auxiliary_snapshots=dict(auxiliary_snapshots or {})
        require_figure_inputs(auxiliary_snapshots)
        registry=Path(auxiliary_snapshots.get('language-registry',downloads/phase_edition/phase_date/'language-registry.tsv'))
        namespace=Path(auxiliary_snapshots.get('namespace-registry',downloads/phase_edition/phase_date/'namespace-registry.tsv'))
        if not registry.is_file():raise ValueError('Missing pinned language registry')
        if not namespace.is_file():raise ValueError('Missing namespace registry')
        auxiliary_snapshots.update({'language-registry':registry,'namespace-registry':namespace})
        auxiliary_hashes=verified_auxiliary_hashes(auxiliary_snapshots,phase_edition,phase_date)
    with build_phase(phase_edition,phase_date,'verify_downloads',files=len(items)) as result:
        verified_bytes=0
        for item in items:
            validate_item(item)
            source = downloads / item['wiki'] / item['date'] / item['name']
            if not source.is_file() or source.stat().st_size != item['size'] or digest(source) != item['sha1']:
                raise ValueError(f'Missing or unverified download: {source}')
            verified_bytes+=item['size']
        result['verified_bytes']=verified_bytes
    xml = [x for x in items if '-pages-meta-current' in x['name'] and re.search(r'\.xml(?:-p[0-9]+p[0-9]+)?\.bz2$', x['name'])]
    if not xml:
        raise ValueError('No full-namespace current XML in snapshot')
    edition,date=items[0]['wiki'],items[0]['date']
    with build_phase(phase_edition,phase_date,'input_identity'):
        if interwiki_snapshot is not None:
            interwiki_snapshot=Path(interwiki_snapshot).resolve(strict=True)
            if not interwiki_snapshot.is_file(): raise ValueError('Interwiki map snapshot is not a file')
            interwiki_sha=sha256_file(interwiki_snapshot)
            validate_interwiki_provenance(interwiki_snapshot,edition,interwiki_sha)
        else:
            interwiki_sha=None
        reviewed = nonlexical.load_review(reviewed_nonlexical_review,items,namespace)
        build_identity=build_input_identity(items,zig,None,interwiki_sha,expansion_timeout_ms,auxiliary_snapshots,downloads,reviewed,validate_auxiliary=True, **({'native_roles':retained_roles} if retained_roles is not None else {}), **shard_page_options(shard_pages))
        generation=getattr(_PREPARED_SOURCE,'value',None)
        if generation is not None:generation.require_identity(build_identity)
        auxiliary_hashes=build_identity['auxiliary_snapshot_sha256']
    target = output / edition / date
    initial_generation = getattr(retained_roles, 'initial_sealed_generation', None) if retained_roles is not None else None
    initial_workspace = initial_sealed_generation(initial_generation, retained_roles)[3] if initial_generation is not None else None
    closed_whole=getattr(retained_roles,'closed_whole_execution',None) if retained_roles is not None else None
    if closed_whole is not None:initial_workspace=retained_roles._closed_native_context[0].parent.parent
    if initial_workspace is not None:
        if not (target.with_name(date+'.shards')/'state.json').exists() and any(os.path.lexists(p) for p in (target, target.with_name(date + '.building'))):
            raise ValueError('Initial sealed adoption refuses existing ordinary output')
        for published in (target, target.with_name(date + '.building')):
            if published.is_relative_to(initial_workspace) or initial_workspace.is_relative_to(published):
                raise ValueError('Initial sealed workspace overlaps ordinary output')
    if retained_roles is not None and retained_roles.sealed_expander_recovery is not None:
        recovery=prepared_metadata(retained_roles.sealed_expander_recovery)
        recovery_workspace=target.with_name(date+'.shards')
        if not sealed_recovery_adopted(recovery_workspace,recovery,build_identity):
            for existing_output in (target,target.with_name(date+'.building')):
                if os.path.lexists(existing_output):
                    raise ValueError('Sealed recovery refuses existing partial or published output')
    writer_transition = getattr(retained_roles, 'writer_figure_transition', None) if retained_roles is not None else None
    if writer_transition is not None and os.path.lexists(target):
        raise ValueError('Writer Figure transition refuses existing publication')
    if (target / 'complete.json').exists():
        try:
            metadata=read_small_json(target/'complete.json',8*1024*1024)
        except (OSError,json.JSONDecodeError):
            metadata={}
        if not isinstance(metadata,dict): metadata={}
        metadata=restore_publication_metadata(target,metadata)
        require_current_staging_version(target,metadata.get('dump_staging_version'))
        if metadata.get('edition')!=edition or metadata.get('date')!=date:
            raise ValueError('Existing output identifies a different edition or date')
        if now_unix is not None and metadata.get('now_unix')!=now_unix:
            raise ValueError('Existing output uses a different or unrecorded build time; choose a new output directory')
        if metadata.get('interwiki_map_sha256')!=interwiki_sha:
            raise ValueError('Existing output uses a different interwiki map snapshot; choose a new output directory')
        if metadata.get('auxiliary_snapshot_sha256',{})!=auxiliary_hashes:
            raise ValueError('Existing output uses different auxiliary snapshots; choose a new output directory')
        nonlexical.bind_identity(target,build_identity,reviewed)
        require_build_identity(metadata.get('build_inputs'),build_identity)
        coverage=validate_page_coverage(target,require_total=True)
        if type(metadata.get('input_pages')) is not int or metadata['input_pages']!=coverage['pages_seen']:
            raise ValueError('Existing output page total differs from coverage')
        fallback_counts = {}
        fallback_reasons = {}
        fallback_name,fallback_decoded=published_fallback_report(metadata)
        if fallback_decoded is not None:
            require_decoded_fallback_report(target/fallback_name, fallback_decoded)
        fallback_pages=validate_fallback_report(target/fallback_name, fallback_counts, fallback_reasons)
        namespace_totals=validate_namespace_coverage(target,metadata['input_pages'],namespace,fallback_counts,auxiliary_snapshots.get('site-info'))
        nonlexical.check_coverage(target,build_identity)
        if (type(metadata.get('fallback_pages')) is not int or metadata['fallback_pages']!=fallback_pages or
                namespace_totals['fallback_pages']!=fallback_pages or
                metadata.get('namespace_coverage_totals')!=namespace_totals):
            raise ValueError('Existing output namespace or fallback totals differ from reports')
        if 'fallback_reason_counts' in metadata:
            recorded_reasons = metadata['fallback_reason_counts']
            if (not isinstance(recorded_reasons, dict) or
                    any(not isinstance(reason, str) or not reason or type(count) is not int or count <= 0
                        for reason, count in recorded_reasons.items()) or
                    recorded_reasons != fallback_reasons):
                raise ValueError('Existing output fallback reason counts differ from report')
        for field,name in (('page_coverage_report','page-coverage.json'),
                           ('namespace_coverage_report','namespace-coverage.json')):
            if metadata.get(field)!=name:raise ValueError('Existing output identifies a different coverage report')
        inventory=publication_inventory(target)
        recorded=metadata.get('publication_files')
        if (not isinstance(recorded,dict) or any(not isinstance(value,dict) or
                type(value.get('size')) is not int for value in recorded.values()) or recorded!=inventory):
            raise ValueError('Existing output publication inventory is missing or changed')
        blobs=sum(name.endswith('.wikblb.xz') for name in inventory)
        if (type(metadata.get('blobs')) is not int or metadata['blobs']!=blobs or
                metadata.get('status')!=('built' if blobs else 'empty')):
            raise ValueError('Existing output blob inventory differs from completion metadata')
        workspace=target.with_name(date+'.shards')
        if workspace.exists():
            cleanup_shard_workspace(workspace)
        unlink_artifact(target/VERIFIED_MARKER, missing_ok=True)
        unlink_artifact(target/VERIFIED_INVENTORY_NAME, missing_ok=True)
        print(f'Already built: {target}', flush=True)
        return 'existing_output'
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.with_name(date + '.building')
    if staging.exists() and writer_transition is None:
        if not staging.is_dir() or staging.is_symlink():
            raise ValueError(f'Unsafe incomplete build path: {staging}')
        if (staging / VERIFIED_MARKER).is_file():
            nonlexical.bind_identity(staging,build_identity,reviewed)
            recorded_now=read_small_json(staging/NOW_UNIX_NAME) if (staging/NOW_UNIX_NAME).is_file() else None
            if now_unix is not None and recorded_now!=now_unix:
                raise ValueError('Verified staging uses a different or unrecorded build time')
            print(f'Resuming verified publication: {staging}', flush=True)
            publish_verified_staging(staging, target, edition, date, compression_workers, interwiki_sha, auxiliary_hashes, build_identity=build_identity, namespace_snapshot=namespace, site_info_snapshot=auxiliary_snapshots.get('site-info'), **({'_staged_input_guard':_staged_input_guard} if _staged_input_guard is not None else {}))
            return 'resumed_publication'
        print(f'Retrying incomplete build: {staging}', flush=True)
        remove_artifact_tree(staging)
    workers = min(compression_workers or default_build_threads(),MAX_PIPELINE_WORKERS)
    llvm_explicit=llvm_workers is not None
    llvm_workers=workers if llvm_workers is None else llvm_workers
    provider_update={}
    with build_phase(phase_edition,phase_date,'workspace_setup'):
        workspace=target.with_name(date+'.shards')
        expected=shard_state(items,registry,interwiki_snapshot=interwiki_snapshot,auxiliary_snapshots=auxiliary_snapshots,reviewed_nonlexical=reviewed,**({'build_identity':build_identity} if 'retained_runtime_source' in build_identity else {}), **shard_page_options(shard_pages))
        raw_shards_path=(Path(raw_shard_root).absolute()/edition/(date+'.raw-shards')) if raw_shard_root is not None else None
        update_args={}
        if (getattr(_PREPARED_SOURCE,'value',None) is None and getattr(_PREPARED_SOURCE,'request',None) is None
                and WIKIBASE_PROVIDER_ROLES <= set(auxiliary_hashes)):
            update_dump=(staged_input_root if staged_input_root is not None else workspace/'input')/'pages.xml.zst'
            update_args=dict(provider_update=provider_update,build_identity=build_identity,dump=update_dump)
        if retained_roles is not None and retained_roles.sealed_expander_recovery is not None:
            update_args.update(sealed_recovery=retained_roles.sealed_expander_recovery, native_roles=retained_roles,
                               build_identity=build_identity, dump=(staged_input_root if staged_input_root is not None else workspace/'input')/'pages.xml.zst')
        if writer_transition is not None:
            update_args=dict(writer_figure_transition=writer_transition, native_roles=retained_roles,
                             build_identity=build_identity, dump=(staged_input_root if staged_input_root is not None else workspace/'input')/'pages.xml.zst')
        if initial_generation is not None or closed_whole is not None:
            update_args=dict(native_roles=retained_roles,auxiliary_snapshots=auxiliary_snapshots,
                             build_identity=build_identity,dump=(staged_input_root if staged_input_root is not None else workspace/'input')/'pages.xml.zst')
            update_args['closed_whole_execution' if closed_whole is not None else 'initial_generation']=closed_whole if closed_whole is not None else initial_generation
        now_unix=prepare_shard_workspace(workspace,expected,now_unix,**({'raw_shards_path':raw_shards_path} if raw_shards_path is not None else {}),**update_args)
        if reviewed is not None:nonlexical.pin_review(reviewed,workspace/'reviewed-nonlexical-source.json')
    dump=(staged_input_root/'pages.xml.zst') if staged_input_root is not None else cached_shard_dump(xml,downloads,workspace)
    source_metadata=read_small_json((staged_input_root if staged_input_root is not None else workspace/'input')/'.complete.json')
    if not isinstance(source_metadata,dict) or type(source_metadata.get('source_pages')) is not int or source_metadata['source_pages']<0:
        raise ValueError('Staged dump lacks a verified source page count')
    source_pages=source_metadata['source_pages']
    with build_phase(phase_edition,phase_date,'snapshot_staging') as snapshot_outcome:
        pinned=copy_verified_snapshot(interwiki_snapshot,workspace/'interwiki-map.tsv',interwiki_sha) if interwiki_snapshot else None
        if writer_transition is None and closed_whole is None:
            aux_pinned=pinned_auxiliary_snapshots(auxiliary_snapshots,auxiliary_hashes,workspace,
                build_identity.get('auxiliary_capture_sha256',{}),build_identity.get('auxiliary_capture_artifact_sha256',{}),
                phase_outcome=snapshot_outcome,
                **({'borrower':retained_roles,'owned_roots':(output,raw_shard_root,extraction_cache_root)} if retained_roles is not None else {}))
            if retained_roles is not None:snapshot_outcome.update(retained_roles.last_capture_borrow)
        else:
            aux_pinned={}
            staged_providers={}
            for figure in (False,True):
                selected={name:path for name,path in auxiliary_snapshots.items() if (name in WRITER_FIGURE_ROLES)==figure}
                subset=lambda field:{name:value for name,value in build_identity.get(field,{}).items() if name in selected}
                outcome={}
                destination=workspace/'writer-observations' if figure else workspace
                aux_pinned.update(pinned_auxiliary_snapshots(selected,{name:auxiliary_hashes[name] for name in selected},destination,
                    subset('auxiliary_capture_sha256'),subset('auxiliary_capture_artifact_sha256'),
                    borrower=retained_roles,owned_roots=(output,raw_shard_root,extraction_cache_root),phase_outcome=outcome))
                staged_providers.update(retained_roles.staged_provider_inputs)
                outcome.update(retained_roles.last_capture_borrow)
                snapshot_outcome['writer_observations' if figure else 'worker_snapshots']=outcome
            retained_roles.staged_provider_inputs=staged_providers
    from prepare_wikibase_page_links import prepare_from_dumps
    with build_phase(edition,date,'wikibase_page_links') as result:
        page_links_snapshot=prepare_from_dumps(items,downloads,namespace,workspace,aux_pinned.get('wikibase-page-links'))
        page_links_sha=sha256_file(page_links_snapshot) if page_links_snapshot is not None else None
        result.update(provider_installed=page_links_snapshot is not None,sha256=page_links_sha)
    from prepare_page_redirects import prepare_from_dumps as prepare_redirects
    with build_phase(edition,date,'page_redirects') as result:
        page_redirects_snapshot=prepare_redirects(items,downloads,workspace,build_identity.get('derived_page_redirects'))
        page_redirects_sha=sha256_file(page_redirects_snapshot) if page_redirects_snapshot is not None else None
        result.update(provider_installed=page_redirects_snapshot is not None,sha256=page_redirects_sha)
    # XML compression ratio does not bound the writer's whole-bucket sort.
    # Reuse the verified repack for either path, retaining it after failures.
    if (source_pages>interval or reviewed is not None or presentation_audit_pages is not None
            or retained_roles is not None or getattr(_PREPARED_SOURCE,'request',None) is not None):
        print(f'Sharding {edition}: {source_pages:,} verified source pages in {interval:,}-page chunks',flush=True)
        build_sharded(dump,staging,workspace,registry,zig,workers,items,now_unix,expansion_workers,pinned,interwiki_sha,aux_pinned,auxiliary_hashes, build_identity=build_identity, **({'page_links_snapshot':page_links_snapshot} if page_links_snapshot is not None else {}), **({'page_redirects_snapshot':page_redirects_snapshot} if page_redirects_snapshot is not None else {}), **({'expansion_timeout_ms':expansion_timeout_ms} if expansion_timeout_ms is not None else {}), **({'raw_shards_path':raw_shards_path} if raw_shards_path is not None else {}), **({'compress_shards':True} if compress_shards else {}), **({'extraction_cache_root':extraction_cache_root} if extraction_cache_root is not None else {}), reviewed_nonlexical=reviewed, **({'llvm_workers':llvm_workers} if llvm_explicit else {}), **({'staged_input_root':staged_input_root} if staged_input_root is not None else {}), **({'_staged_input_guard':_staged_input_guard} if _staged_input_guard is not None else {}), **({'presentation_audit_pages':presentation_audit_pages} if presentation_audit_pages is not None else {}), **({'continue_failed_shards':True} if continue_failed_shards else {}), **({'retained_roles':retained_roles} if retained_roles is not None else {}),**({'provider_update':provider_update} if provider_update else {}), **shard_page_options(shard_pages))
    else:
        if getattr(_PREPARED_SOURCE,'value',None) is not None:
            raise ValueError('Nonsharded builds cannot consume a released native source lease')
        extraction_cache=Path(extraction_cache_root) if extraction_cache_root is not None else workspace/'input'/'extraction-cache'
        timed_run([zig,'build','-j1','-Doptimize=fast','--summary','all','build-dictionary','--',str(dump),str(staging),
                     *(['--interwiki-map-snapshot',str(pinned)] if pinned else []),
                     *pipeline_snapshot_args(registry,aux_pinned,page_links_snapshot,page_redirects_snapshot),
                     '--llvm-workers',str(llvm_workers),'--parse-workers',str(min(workers,64)),
                     '--page-workers',str(expansion_workers if expansion_workers is not None else min(workers,16)),'--now-unix',str(now_unix),*timeout_args,
                     *extraction_cache_args(extraction_cache,source_metadata)],edition,date,'dictionary_build')
        with build_phase(edition,date,'page_coverage'):
            coverage=validate_page_coverage(staging,source_pages=source_pages)
            coverage['expected_input_pages']=source_pages
            (staging/'page-coverage.json').write_text(json.dumps(coverage,sort_keys=True)+'\n')
        timed_run([zig,'build','-j1','-Doptimize=fast','verify-blobs','--',str(staging)],
                  edition,date,'dictionary_verify')
        with build_phase(edition,date,'publication_seal'):
            if interwiki_sha is not None:
                if sha256_file(pinned)!=interwiki_sha: raise ValueError('Interwiki map snapshot changed during build')
                (staging/INTERWIKI_SHA_NAME).write_text(interwiki_sha+'\n')
            if auxiliary_hashes or build_identity is not None:
                final_hashes,final_captures=_validated_auxiliary_state(aux_pinned)
                if auxiliary_hashes:
                    if final_hashes!=auxiliary_hashes:
                        raise ValueError('Auxiliary snapshot changed during build')
                    (staging/AUXILIARY_SHA_NAME).write_text(json.dumps(auxiliary_hashes,sort_keys=True)+'\n')
                if build_identity is not None:
                    manifests,artifacts=_project_auxiliary_capture_identities(final_captures)
                    if (manifests!=build_identity.get('auxiliary_capture_sha256',{}) or
                            artifacts!=build_identity.get('auxiliary_capture_artifact_sha256',{})):
                        raise ValueError('Auxiliary capture changed during build')
            if page_links_snapshot is not None and sha256_file(page_links_snapshot)!=page_links_sha:
                raise ValueError('Derived page links changed during build')
            if page_redirects_snapshot is not None and sha256_file(page_redirects_snapshot)!=page_redirects_sha:
                raise ValueError('Derived page redirects changed during build')
            (staging/NOW_UNIX_NAME).write_text(json.dumps(now_unix)+'\n')
            persist_build_identity(staging,build_identity)
            if _staged_input_guard is not None:_staged_input_guard()
            seal_verified_publication_inventory(staging)
            (staging / VERIFIED_MARKER).write_text(VERIFIED_CONTENT)
            # Verified staging can now resume publication without the input cache.
            cleanup_shard_workspace(workspace)
    (staging/NOW_UNIX_NAME).write_text(json.dumps(now_unix)+'\n')
    publish_verified_staging(staging, target, edition, date, compression_workers, interwiki_sha, auxiliary_hashes, build_identity=build_identity, namespace_snapshot=namespace, site_info_snapshot=auxiliary_snapshots.get('site-info'), **({'_staged_input_guard':_staged_input_guard} if _staged_input_guard is not None else {}))
    cleanup_shard_workspace(workspace)
    return 'pipeline_run_may_reuse_verified_inputs_or_shards'

def smallest_first_group_key(entry):
    """Order validated compressed XML bytes, then edition/date; never probe files."""
    key, group = entry
    try:
        for item in group:
            validate_item(item)
        xml = [item for item in group if '.xml' in item['name']]
        if not xml:
            raise ValueError('No XML input')
        size = sum(item['size'] for item in xml)
    except (KeyError, TypeError, ValueError):
        # main rejects malformed manifests before scheduling. Direct callers
        # retain build's original per-edition rejection/continuation behavior;
        # unknown sizes must not be treated as zero or displace valid work.
        size = float('inf')
    return size, key


def build_groups(groups, downloads, output, zig, threads, jobs, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, edition_options=None, admission_wait_seconds=RESOURCE_ADMISSION_WAIT_SECONDS, cpu_admission='load', raw_shard_root=None, adaptive_workers=False, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None, presentation_audit_pages=None, continue_failed_shards=False, shard_pages=None):
    selected_shard_pages(shard_pages)
    validate_presentation_audit_pages(presentation_audit_pages, continue_failed_shards)
    if staged_input_root is not None and len(groups)!=1:raise ValueError('Borrowed staged inputs require exactly one edition')
    from build_resource_limits import MAX_WATCHDOG_WALL_SECONDS
    validate_now_unix(now_unix)
    timeout_args=expansion_deadline_args(expansion_timeout_ms)
    if type(admission_wait_seconds) is not int or not 1 <= admission_wait_seconds <= MAX_WATCHDOG_WALL_SECONDS:
        raise ValueError('Resource admission wait must be a positive finite number of seconds, up to seven days')
    if cpu_admission not in ('load','affinity'):raise ValueError('Unknown CPU admission policy')
    validate_llvm_workers(llvm_workers)
    if type(adaptive_workers) is not bool or (adaptive_workers and (cpu_admission!='load' or expansion_workers is not None or llvm_workers is not None)):
        raise ValueError('Automatic worker reduction requires load admission and implicit expansion workers')
    if cpu_admission=='affinity':validate_affinity_workers(threads,jobs,expansion_workers,llvm_workers)
    pending=sorted(groups.items(), key=smallest_first_group_key)
    failures=[]
    admission_workers=threads if expansion_workers is None or expansion_workers>MAX_PIPELINE_WORKERS else max(threads,expansion_workers)
    admission_workers=max(admission_workers,llvm_workers or threads)
    admission_deadline=None
    admission_report_at=0
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        active={}
        while pending or active:
            while pending and len(active)<jobs:
                active_workers=len(active)*admission_workers
                live_budget=safe_worker_budget(active_workers) if cpu_admission=='load' else safe_worker_budget(cpu_admission='affinity')
                if adaptive_workers and not active and live_budget < admission_workers:
                    reduced=reduced_automatic_workers(threads,live_budget)
                    if reduced < threads:
                        print(f'Reducing automatic workers from {threads} to {reduced} within resource budget {live_budget}',flush=True)
                        threads=admission_workers=reduced
                if live_budget < active_workers+admission_workers:
                    break
                if admission_deadline is not None and time.monotonic() >= admission_deadline:
                    break
                key,group=pending.pop(0)
                options={}
                options.update(shard_page_options(shard_pages))
                if reviewed_nonlexical_review is not None:options['reviewed_nonlexical_review']=reviewed_nonlexical_review
                if expansion_workers is not None: options['expansion_workers']=expansion_workers
                if llvm_workers is not None: options['llvm_workers']=llvm_workers
                if expansion_timeout_ms is not None: options['expansion_timeout_ms']=expansion_timeout_ms
                if now_unix is not None: options['now_unix']=now_unix
                if raw_shard_root is not None: options['raw_shard_root']=raw_shard_root
                if compress_shards: options['compress_shards']=True
                if extraction_cache_root is not None: options['extraction_cache_root']=extraction_cache_root
                if staged_input_root is not None: options['staged_input_root']=staged_input_root
                if presentation_audit_pages is not None: options['presentation_audit_pages']=presentation_audit_pages
                if continue_failed_shards: options['continue_failed_shards']=True
                if interwiki_snapshot is not None: options['interwiki_snapshot']=interwiki_snapshot
                if auxiliary_snapshots: options['auxiliary_snapshots']=auxiliary_snapshots
                if edition_options is not None:
                    if key not in edition_options:raise ValueError(f'Missing edition inputs: {key}')
                    options.update(edition_options[key])
                if options.get('llvm_workers',llvm_workers)!=llvm_workers:
                    raise ValueError('Edition inputs cannot override LLVM worker admission')
                if cpu_admission=='affinity':validate_affinity_workers(threads,jobs,options.get('expansion_workers'),options.get('llvm_workers'))
                future=pool.submit(build,group,downloads,output,zig,threads,**options)
                active[future]=key
                admission_deadline=None
                admission_report_at=0
            if not active:
                if pending:
                    now=time.monotonic()
                    if admission_deadline is None:
                        admission_deadline=now+admission_wait_seconds
                    remaining=admission_deadline-now
                    if remaining <= 0:
                        print(f'STOPPED before {pending[0][0][0]}: resource admission deadline expired after {admission_wait_seconds} seconds; budget {live_budget}, need {admission_workers}',flush=True)
                        failures.extend(key for key,_ in pending)
                        break
                    if now >= admission_report_at:
                        print(f'WAITING before {pending[0][0][0]}: resource pressure allows {live_budget} workers, need {admission_workers}; admission deadline in {remaining:.0f} seconds',flush=True)
                        admission_report_at=now+30
                    time.sleep(min(RESOURCE_ADMISSION_POLL_SECONDS,remaining))
                    continue
                break
            # Recheck admission only while another edition could start. With all
            # slots occupied or the queue empty, completion is the next event.
            timeout = 1 if pending and len(active) < jobs else None
            done,_=concurrent.futures.wait(active,timeout=timeout,return_when=concurrent.futures.FIRST_COMPLETED)
            if not done:continue
            for future in done:
                key=active.pop(future)
                try:future.result()
                except Exception as e:
                    failures.append(key);print(f'FAILED {key}: {e}',flush=True)
    return failures



def watchdog_memory_limit_bytes(limit_mib, resource_mode):
    if limit_mib is None:
        return None
    if resource_mode != 'watchdog' or type(limit_mib) is not int or not 1 <= limit_mib <= 8192:
        raise ValueError('Explicit watchdog memory limit requires watchdog mode and 1 through 8192 MiB')
    return limit_mib * 1024**2


def parse_retained_native_roles(value, zig, *, sharded, edition_count, jobs, reference=None):
    if value is not None and reference is not None:
        raise ValueError('Select one retained native role argument')
    if value is None and reference is None:return None
    if not sharded or edition_count != 1 or jobs != 1:
        raise ValueError('Retained native roles require one ordinary compressed edition')
    roles = prepared_metadata(json.loads(reference)) if reference is not None else json.loads(value)
    if not isinstance(roles,dict):raise ValueError('Invalid retained native roles')
    prepared=os.environ.get('WIKIDICT_PREPARED_SOURCE_ATTEMPT')
    selected=_prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')=='1'
    if prepared is not None or selected:
        if prepared is None or not selected:
            raise ValueError('Retained native roles require one ordinary compressed edition with the bound prepared bootstrap')
        start=prepared_metadata(json.loads(prepared)); control=start['prepared_source_control']
        cfg=control['configuration']
        if cfg.get('prepared_source_custody') is not True or cfg.get('retained_native_roles')!=roles:
            raise ValueError('Prepared retained roles differ from attempt')
        resume=control.get('resume')
        if resume is not None:
            old_start=prepared_metadata(resume['start'])
            generation=prepared_authorized_generation(cfg,old_start,resume['authorization'])
            if generation.retained_roles is None:
                raise ValueError('Prepared retry has no retained dispatch binding')
            return generation.retained_roles
        if not {'initial_sealed_generation','closed_whole_execution'} & set(roles.get('dict-bundle-build',{})):
            raise ValueError('Prepared retained custody requires explicit closed execution selection')
    compiler=shutil.which(zig)
    if compiler is None:raise ValueError('Zig compiler executable is unavailable')
    return RetainedNativeToolRoles(roles,zig_sha256=sha256_file(Path(compiler).resolve(strict=True)))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--workspace-root-spec',help='Bound workspace directory identity for a retained producer source')
    p.add_argument('--execution-root-spec',help='Bound private single-edition state, output, raw and cache directories')
    p.add_argument('--downloads','--in',type=Path,metavar='DIR')
    p.add_argument('--output','--out',type=Path,metavar='DIR')
    p.add_argument('--continue-failed-shards',action='store_true',help='With an audit bound, continue only authenticated presentation rejections; retain verified shards and refuse merge/publication if any shard fails')
    p.add_argument('--presentation-audit-pages',type=int,metavar='N',help='After a bound presentation failure, audit at most N rows from the failed shard start using the same worker; edition remains failed and unpublished, original deadline applies')
    p.add_argument('--shard-pages',type=int,metavar='N',help='Positive verified shard checkpoint interval; default 100000 pages. Smaller shards increase verification/compression/merge overhead.')
    p.add_argument('--compress-shards',action='store_true',help='Verify and compress each temporary shard, then merge directly to compressed output')
    p.add_argument('--staged-input-root',type=Path,metavar='DIR',help='Read-only completed repack input directory for exactly one edition; validates existing marker and bytes, never copies or retires it')
    p.add_argument('--extraction-cache-root',type=Path,metavar='DIR',help='Existing verified native extraction/object cache for one edition; cache identities are checked against fresh build inputs')
    p.add_argument('--raw-shard-root',type=Path,metavar='DIR',help='Optional raw shard volume; input/native caches and merged publication remain under --output')
    p.add_argument('--zig',default=shutil.which('zig') or 'zig')
    p.add_argument('--python-tooling-json',help='Explicit source-bound Python script/helper selection; native source root remains separately bound')
    role_args = p.add_mutually_exclusive_group()
    role_args.add_argument('--retained-native-roles-ref', help='Path, byte count and SHA-256 descriptor of a retained native roles JSON file')
    role_args.add_argument('--retained-native-roles-json',help='Explicit source-bound retained native role selection for one compressed edition; original producer provenance is retained')
    p.add_argument('--resource-mode',choices=('cgroup','watchdog'),default='cgroup',
                   help='Resource supervisor: strict cgroup (default), or explicit best-effort 8 GiB process-tree watchdog with a two-hour deadline')
    p.add_argument('--watchdog-address-space',choices=('default','unlimited'),default='default',
                   help='Watchdog virtual address-space policy; unlimited retains the 8 GiB aggregate resident-memory cap')
    p.add_argument('--watchdog-memory-limit-mib',type=int,help='Explicit aggregate watchdog resident limit, 1 through 8192 MiB; omitted retains the existing 8 GiB default')
    p.add_argument('--build-timeout-seconds',type=int,help='Explicit watchdog build deadline, up to seven days; default two hours')
    p.add_argument('--artifact-root-spec', help='Explicit private artifact-root identity JSON for output and raw shards')
    p.add_argument('--cpu-admission',choices=('load','affinity'),default='load',
                   help='CPU admission: load headroom (default), or fixed affinity sharing within a verified watchdog and one edition job')
    p.add_argument('--threads',type=int,help='Workers per edition (up to 4 within CPU load and fixed 8 GiB aggregate cap)')
    p.add_argument('--llvm-workers',type=int,help='Native LLVM batch workers, 1 through 4; default follows --threads; parse/page workers stay unchanged')
    p.add_argument('--jobs',type=int,help='Concurrent editions (up to two within CPU load and capped aggregate worker budget)')
    p.add_argument('--expansion-workers',type=int,help='Workers per sharded page expansion; default follows --threads, opt-in 5-8 requires watchdog and one edition job')
    p.add_argument('--expansion-timeout-ms',type=int,help='Explicit per-page wall deadline, 1 through 3600000 ms; default 60000. Timeouts fail the build rather than publish empty pages.')
    p.add_argument('--wikis',nargs='+',help='Build only these edition IDs')
    p.add_argument('--input-manifest',type=Path,help='Explicit immutable input manifest; downloads remain in --downloads')
    p.add_argument('--input-manifest-sha256',help='Required SHA256 for --input-manifest')
    p.add_argument('--metadata-network',choices=('offline','allow'),default='offline',
                   help='Reuse verified metadata by default; allow explicitly prepares missing shared Figure inputs from selected official sources')
    p.add_argument('--exact-snapshot-selection',action='store_true',
                   help='Require the fully validated snapshot roles and paths to equal the explicit selection')
    p.add_argument('--figure-reuse-batch',type=Path,action='append',default=[],
                   help='Reuse an authenticated Figure batch record; repeat for multiple records (network policy remains explicit)')
    p.add_argument('--now-unix',type=int,help='Pin build-time MediaWiki time for repeatable complete builds')
    p.add_argument('--interwiki-map-snapshot',type=Path,
                   help='Current siteinfo interwiki-map.tsv; its SHA-256 is part of the shard identity')
    p.add_argument('--reviewed-nonlexical-review',type=Path,help='Exact source-bound reviewed nonlexical page dispositions for one edition')
    for name in AUXILIARY_SNAPSHOT_NAMES:
        p.add_argument('--'+name+'-snapshot',type=Path,
                       help='Optional '+name+' snapshot; its SHA-256 is part of the shard identity')
    a=p.parse_args()
    try:selected_shard_pages(a.shard_pages)
    except ValueError as error:p.error(str(error))
    try: workspace=workspace_root(json.loads(a.workspace_root_spec) if a.workspace_root_spec is not None else None)
    except (ValueError,OSError) as error: p.error(str(error))
    if a.downloads is None:a.downloads=workspace/'data/dumps'
    if a.output is None:a.output=workspace/'data/dictionaries'
    try: selected_execution_paths(a,workspace)
    except (ValueError,OSError) as error: p.error(str(error))
    try: watchdog_memory_limit_bytes(a.watchdog_memory_limit_mib,a.resource_mode)
    except ValueError as error: p.error(str(error))
    configure_artifact_root(json.loads(a.artifact_root_spec) if a.artifact_root_spec is not None else None, a.output, a.raw_shard_root)
    if a.watchdog_address_space!='default' and a.resource_mode!='watchdog':
        p.error('Unlimited address space requires explicit watchdog mode')
    try:
        validate_presentation_audit_pages(a.presentation_audit_pages, a.continue_failed_shards)
        expansion_deadline_args(a.expansion_timeout_ms)
        validate_now_unix(a.now_unix)
    except ValueError as error: p.error(str(error))
    if a.build_timeout_seconds is not None:
        from build_resource_limits import MAX_WATCHDOG_WALL_SECONDS
        if a.resource_mode!='watchdog' or not 0<a.build_timeout_seconds<=MAX_WATCHDOG_WALL_SECONDS:
            p.error('Explicit build deadline requires watchdog mode and must be 1 through '+str(MAX_WATCHDOG_WALL_SECONDS)+' seconds')
    if a.cpu_admission=='affinity' and a.resource_mode!='watchdog':
        p.error('Affinity admission requires explicit watchdog mode')
    adaptive_workers=a.cpu_admission=='load' and a.threads is None and a.expansion_workers is None and a.llvm_workers is None
    if a.threads is None and a.cpu_admission=='load':a.threads=default_build_threads()
    try:budget=safe_worker_budget() if a.cpu_admission=='load' else safe_worker_budget(cpu_admission='affinity')
    except ValueError as error:p.error(str(error))
    if a.threads is None:
        a.threads=max(1,min(MAX_PIPELINE_WORKERS,budget))
    if budget < 1:p.error('No worker budget within the selected CPU admission policy and build memory limit (at most 8 GiB)')
    worker_limit=min(budget,MAX_PIPELINE_WORKERS)
    if adaptive_workers and a.threads > worker_limit:
        a.threads=reduced_automatic_workers(a.threads,worker_limit)
    if not 1 <= a.threads <= worker_limit:p.error(f'Threads must be 1 through {worker_limit} on this host')
    llvm_workers=a.threads if a.llvm_workers is None else a.llvm_workers
    try:validate_llvm_workers(llvm_workers)
    except ValueError as error:p.error(str(error))
    expansion_workers=a.threads if a.expansion_workers is None else a.expansion_workers
    if not 1 <= expansion_workers <= MAX_PAGE_EXPANSION_WORKERS:
        p.error(f'Expansion workers must be 1 through {MAX_PAGE_EXPANSION_WORKERS}')
    if a.cpu_admission=='affinity' and expansion_workers>MAX_PIPELINE_WORKERS:
        p.error('Affinity admission allows at most four expansion workers')
    if expansion_workers>MAX_PIPELINE_WORKERS:
        if a.resource_mode!='watchdog':p.error('More than four expansion workers requires explicit watchdog mode')
        if expansion_workers>len(os.sched_getaffinity(0)):
            p.error('Expansion workers exceed the watchdog CPU affinity')
    admission_workers=a.threads if expansion_workers>MAX_PIPELINE_WORKERS else max(a.threads,expansion_workers)
    admission_workers=max(admission_workers,llvm_workers)
    if a.jobs is None:a.jobs=1 if a.cpu_admission=='affinity' or expansion_workers>MAX_PIPELINE_WORKERS else min(2,max(1,budget//admission_workers))
    if a.cpu_admission=='affinity':
        try:validate_affinity_workers(a.threads,a.jobs,expansion_workers,llvm_workers)
        except ValueError as error:p.error(str(error))
    if expansion_workers>MAX_PIPELINE_WORKERS and a.jobs!=1:
        p.error('More than four expansion workers requires exactly one edition job')
    if not 1 <= a.jobs <= 16:p.error('Jobs must be 1 through 16')
    if a.jobs*admission_workers > budget:p.error(f'jobs × workers must not exceed safe host budget {budget}')
    try:
        if bool(a.input_manifest)!=bool(a.input_manifest_sha256):raise ValueError('Explicit input manifest requires exact SHA256')
        manifest=(load_input_manifest(a.input_manifest.absolute(),a.input_manifest_sha256,a.downloads.resolve())
                  if a.input_manifest is not None else json.loads((a.downloads/'manifest.json').read_text()))
        items=select_manifest_files(manifest,a.wikis)
    except ValueError as error: p.error(str(error))
    groups={}
    for item in items:
        validate_item(item)
        groups.setdefault((item['wiki'],item['date']),[]).append(item)
    if a.wikis:
        missing=set(a.wikis)-{key[0] for key in groups}
        if missing:p.error(f'Unknown editions: {", ".join(sorted(missing))}')
        groups={key:group for key,group in groups.items() if key[0] in a.wikis}
    auxiliary={name:getattr(a,name.replace('-','_')+'_snapshot').resolve()
               for name in AUXILIARY_SNAPSHOT_NAMES
               if getattr(a,name.replace('-','_')+'_snapshot') is not None}
    if (a.interwiki_map_snapshot is not None or auxiliary) and len(groups)!=1:
        p.error('Auxiliary snapshots require exactly one edition')
    if a.staged_input_root is not None and len(groups)!=1:
        p.error('Borrowed staged inputs require exactly one edition')
    if a.extraction_cache_root is not None and len(groups)!=1:
        p.error('An explicit extraction cache requires exactly one edition')
    if a.reviewed_nonlexical_review is not None and len(groups)!=1:
        p.error('A reviewed nonlexical source manifest requires exactly one edition')
    try:
        require_auxiliary_tooling(auxiliary)
        retained_roles=parse_retained_native_roles(a.retained_native_roles_json,a.zig, reference=a.retained_native_roles_ref,
            sharded=a.compress_shards,edition_count=len(groups),jobs=a.jobs)
    except (ValueError,OSError,KeyError,TypeError) as error:p.error(str(error))
    print(f'Building {len(groups)} editions with up to {a.jobs} concurrent jobs and {a.threads} workers per edition',flush=True)
    options={}
    if a.reviewed_nonlexical_review is not None:options['reviewed_nonlexical_review']=a.reviewed_nonlexical_review.resolve(strict=True)
    if a.cpu_admission!='load':options['cpu_admission']=a.cpu_admission
    if adaptive_workers:options['adaptive_workers']=True
    if a.resource_mode=='watchdog':
        from build_resource_limits import WATCHDOG_WALL_SECONDS
        # The outer watchdog still enforces its original global wall deadline,
        # including time already spent building or waiting for worker admission.
        options['admission_wait_seconds']=a.build_timeout_seconds or WATCHDOG_WALL_SECONDS
    if a.expansion_timeout_ms is not None: options['expansion_timeout_ms']=a.expansion_timeout_ms
    if a.now_unix is not None: options['now_unix']=a.now_unix
    if a.llvm_workers is not None: options['llvm_workers']=llvm_workers
    if a.raw_shard_root is not None: options['raw_shard_root']=a.raw_shard_root.absolute()
    if a.compress_shards: options['compress_shards']=True
    if a.presentation_audit_pages is not None: options['presentation_audit_pages']=a.presentation_audit_pages
    if a.continue_failed_shards: options['continue_failed_shards']=True
    if a.staged_input_root is not None: options['staged_input_root']=a.staged_input_root.absolute()
    if a.extraction_cache_root is not None: options['extraction_cache_root']=a.extraction_cache_root.absolute()
    if a.interwiki_map_snapshot: options['interwiki_snapshot']=a.interwiki_map_snapshot.resolve()
    try: options['edition_options']=resolve_edition_snapshot_options(manifest,groups,a.downloads.resolve(),auxiliary,workspace=workspace,metadata_network=a.metadata_network,figure_reuse_batches=tuple(a.figure_reuse_batch))
    except (ValueError,OSError) as error:p.error(str(error))
    if retained_roles is not None:
        for value in options['edition_options'].values():value['retained_roles']=retained_roles
    if a.interwiki_map_snapshot:
        for value in options['edition_options'].values():value['interwiki_snapshot']=a.interwiki_map_snapshot.resolve()
    if a.exact_snapshot_selection:
        try: require_exact_snapshot_selection(options['edition_options'],groups,auxiliary,
                                             a.interwiki_map_snapshot.resolve() if a.interwiki_map_snapshot else None)
        except (ValueError,OSError) as error:p.error(str(error))
    failures=build_groups(groups,a.downloads.resolve(),a.output.resolve(),a.zig,a.threads,a.jobs,
                          None if a.expansion_workers is None else expansion_workers,**options,**shard_page_options(a.shard_pages))
    if failures:raise SystemExit(f'{len(failures)} editions failed or were not started; no incomplete editions were published')
def cli():
    from build_resource_limits import ContainmentUnavailable, inside_envelope, inside_watchdog, supervise, supervise_watchdog
    try:
        route=argparse.ArgumentParser(add_help=False)
        route.add_argument('--resource-mode',choices=('cgroup','watchdog'),default='cgroup')
        route.add_argument('--watchdog-address-space',choices=('default','unlimited'),default='default')
        route.add_argument('--watchdog-memory-limit-mib',type=int)
        route.add_argument('--cpu-admission',choices=('load','affinity'),default='load')
        route.add_argument('--artifact-root-spec')
        route.add_argument('--workspace-root-spec')
        route.add_argument('--execution-root-spec')
        route.add_argument('--downloads','--in',type=Path)
        route.add_argument('--input-manifest',type=Path)
        route.add_argument('--input-manifest-sha256')
        role_args = route.add_mutually_exclusive_group()
        role_args.add_argument('--retained-native-roles-json')
        role_args.add_argument('--retained-native-roles-ref')
        route.add_argument('--python-tooling-json')
        route.add_argument('--wikis',nargs='+')
        route.add_argument('--threads',type=int)
        route.add_argument('--llvm-workers',type=int)
        route.add_argument('--jobs',type=int)
        route.add_argument('--expansion-workers',type=int)
        route.add_argument('--build-timeout-seconds',type=int)
        route.add_argument('--output','--out',type=Path)
        route.add_argument('--raw-shard-root',type=Path)
        route.add_argument('--extraction-cache-root',type=Path)
        routing=route.parse_known_args()[0]
        try: workspace=workspace_root(json.loads(routing.workspace_root_spec) if routing.workspace_root_spec is not None else None)
        except (ValueError,OSError) as error: raise ContainmentUnavailable(str(error)) from error
        if routing.output is None:routing.output=workspace/'data/dictionaries'
        try: execution=selected_execution_paths(routing,workspace)
        except (ValueError,OSError) as error: raise ContainmentUnavailable(str(error)) from error
        configure_artifact_root(json.loads(routing.artifact_root_spec) if routing.artifact_root_spec is not None else None, routing.output, routing.raw_shard_root)
        mode=routing.resource_mode
        try: requested_memory=watchdog_memory_limit_bytes(routing.watchdog_memory_limit_mib,mode)
        except ValueError as error: raise ContainmentUnavailable(str(error)) from error
        if routing.watchdog_address_space!='default' and mode!='watchdog':
            raise ContainmentUnavailable('Unlimited address space requires explicit watchdog mode')
        if routing.cpu_admission=='affinity':
            if mode!='watchdog':raise ContainmentUnavailable('Affinity admission requires explicit watchdog mode')
            if routing.jobs not in (None,1):raise ContainmentUnavailable('Affinity admission requires exactly one edition job')
            if any(n is not None and not 1 <= n <= MAX_PIPELINE_WORKERS for n in (routing.threads,routing.expansion_workers,routing.llvm_workers)):
                raise ContainmentUnavailable('Affinity admission allows one through four compiler and expansion workers')
        if routing.build_timeout_seconds is not None:
            from build_resource_limits import MAX_WATCHDOG_WALL_SECONDS
            if mode!='watchdog' or not 0<routing.build_timeout_seconds<=MAX_WATCHDOG_WALL_SECONDS:
                raise ContainmentUnavailable('Explicit build deadline requires watchdog mode and a finite bound up to seven days')
        if '-h' in sys.argv[1:] or '--help' in sys.argv[1:]:
            main()
        else:
            watchdog_child=inside_watchdog()
            if watchdog_child and mode!='watchdog':
                raise ContainmentUnavailable('Watchdog child requires explicit --resource-mode=watchdog')
            if mode=='watchdog':
                if watchdog_child:
                    if execution is not None:require_execution_parent_lock(execution)
                    if requested_memory is not None and routing.watchdog_address_space=='unlimited':
                        from build_resource_limits import watchdog_physical_memory_limit_bytes
                        if watchdog_physical_memory_limit_bytes()!=requested_memory:
                            raise ContainmentUnavailable('Authenticated watchdog memory budget differs from requested limit')
                    try:
                        main()
                    finally:
                        if execution is not None:selected_execution_paths(routing,workspace)
                else:
                    with selected_build_resource_lock(routing,workspace,execution):
                        options={'wall_seconds':routing.build_timeout_seconds if routing.build_timeout_seconds is not None else 7200,
                                 'disk_paths':(workspace/'.tmp', routing.output),
                                 'child_nice':max(0,os.getpriority(os.PRIO_PROCESS,0))}
                        if requested_memory is not None: options['memory_limit_bytes']=requested_memory
                        if routing.watchdog_address_space=='unlimited': options['address_space_limit_bytes']='unlimited'
                        if routing.raw_shard_root is not None: options['disk_paths']+=(routing.raw_shard_root,)
                        if routing.extraction_cache_root is not None: options['disk_paths']+=(routing.extraction_cache_root,)
                        if routing.expansion_workers is not None and routing.expansion_workers>MAX_PIPELINE_WORKERS:
                            options['max_cpus']=8
                        raise SystemExit(supervise_watchdog(**prepared_watchdog_options(options)))
            elif inside_envelope():
                main()
            else:
                with selected_build_resource_lock(routing,workspace,execution):
                    raise SystemExit(supervise())
    except ContainmentUnavailable as error:
        raise SystemExit(str(error)) from error
    except KeyboardInterrupt:
        raise SystemExit('Build interrupted; private build process tree stopped') from None

if __name__=='__main__':cli()
