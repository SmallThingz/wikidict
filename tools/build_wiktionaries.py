#!/usr/bin/env python3
"""Build every fully downloaded snapshot; publish verified extreme-XZ blobs."""
import sys as _prepared_bootstrap_sys
if _prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')=='1':
    _prepared_bootstrap_sys.path=[_prepared_bootstrap_sys._stdlib_dir,
                                  _prepared_bootstrap_sys._stdlib_dir+'/lib-dynload']
import argparse
import bz2
try:
    from compression import zstd
except ImportError:
    zstd = None
import concurrent.futures
from collections import deque
from contextlib import contextmanager, ExitStack
import fcntl
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
import threading
import time
import uuid
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
    def __init__(self, record, *, source, build_identity, now_unix, context):
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
        if (self.root != self.workspace / 'expander' / '.bundle-expander'
                or not self.workspace.is_absolute()
                or any(p.is_symlink() for p in (self.workspace, *self.workspace.parents))):
            raise ValueError('Prepared generation workspace differs')
        self.tools = {}
        if set(record['tools']) != set(BLOB_TOOL_NAMES):
            raise ValueError('Incomplete prepared native tool inventory')
        for name, expected in record['tools'].items():
            path = self.workspace / 'native-blob-tools' / 'bin' / name
            if expected['path'] != str(path):
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
            self.tools[name] = tool
        self.require_unchanged()

    def require_python(self, *, force=False):
        if not hasattr(self,'_python_stamps'):self._python_stamps={}
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
        seal = (self.cache.frozen_runtime_context(self.root, self.dump, self.record['seal_sha256'])
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
        if read_small_json(self.workspace / 'state.json') != self.record['workspace_state']:
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
                or read_small_json(staging / BUILD_IDENTITY_NAME) != self.identity):
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
        if source_fingerprint() != identity['source']:
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
    PROJECT=Path(__file__).resolve().parent.parent
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
    guard.require_python(force=True)
    _PREPARED_BOOTSTRAP_PYTHON_GUARD=guard
    # Stdlib stays ahead of tools, including for future lazy imports. No cwd,
    # PYTHONPATH or site-packages search path is silently restored.
    sys.path.append(str(PROJECT/'tools'))


def prepared_watchdog_options(options):
    if _PYTHON_TOOLING is not None:
        _PYTHON_TOOLING.require_unchanged()
        if (not sys.flags.isolated or not sys.flags.no_site or not sys.dont_write_bytecode
                or not sys.pycache_prefix or not Path(sys.pycache_prefix).is_absolute()
                or os.path.lexists(sys.pycache_prefix)):
            raise ValueError('Selected Python watchdog requires its original isolated absent-prefix startup')
        return dict(options,argv=['-I','-S','-B','-X','pycache_prefix='+sys.pycache_prefix,*sys.argv])
    if _prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')!='1':return options
    return dict(options,argv=['-I','-S','-B','-X','wikidict_prepared_source=1',
                              '-X','pycache_prefix='+sys.pycache_prefix,*sys.argv])


def prepared_metadata_ref(path):
    path=Path(path)
    before=path.stat()
    value=dict(path=str(path.absolute()),bytes=before.st_size,sha256=sha256_file(path))
    prepared_metadata(value)
    return value


def write_prepared_metadata(path,value):
    # New names only. The existing owner replaces launch.json, never the child.
    with Path(path).open('x') as stream:
        json.dump(value,stream,sort_keys=True)
        stream.write('\n')
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
            or original.get('apps_acceptance') is not False):
        raise ValueError('Parent original source observation differs')
    record=prepared_metadata(authorization['generation'])
    if (record['source']!=configuration['source'] or record['context']!=start['context']
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
        while time.monotonic()<deadline:
            if not launch_path.exists():
                time.sleep(.1)
                continue
            launch_ref=prepared_metadata_ref(launch_path)
            launch=prepared_metadata(launch_ref)
            auth=launch.get('prepared_source_authorization')
            if auth is not None:
                if auth.get('generation')!=reference:
                    raise ValueError('Parent authorized another prepared generation')
                return prepared_authorized_generation(self.configuration,self.start,launch_ref)
            time.sleep(.1)
        raise ValueError('Prepared source parent authorization did not complete')

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
        root=workspace/'expander'/'.bundle-expander'
        marker=root/COMPLETED_EXPANDER_PROOF
        if not marker.is_file():return None
        seal_reference=prepared_metadata_ref(marker)
        seal=cache.frozen_runtime_context(root,dump,seal_reference['sha256'])
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
            workspace_state=read_small_json(workspace/'state.json'),python=python,tools=bound_tools,
            seal_sha256=seal_reference['sha256'],seal_archive=archive_ref,
            prepared_by_start=self.reference,
            tracked_process=prepared_metadata(prepared_metadata_ref(self.folder/'launch.json'))['identity'])
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
    if _prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source')=='1':
        raise ValueError('Selected Python tooling is distinct from prepared source custody')
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
            'prepare_language_messages_v2','prepare_date_numbering',
            'prepare_site_info','prepare_language_names_translate','prepare_parser_function_facts'):
        # These helpers replay the complete capture inside capture_artifacts.
        # Bind that one replay to exact preread bytes, rather than replaying the
        # inventory twice at this boundary. Other boundaries still replay.
        manifest_name=auxiliary_manifest_filename(name,path)
        manifest_path=Path(path).with_name(manifest_name)
        if helper.__name__=='prepare_wikibase_entities':
            manifest_raw=helper.regular(manifest_path,helper.MAX_PROOF_BYTES)
            record=helper.parse_json(manifest_raw)
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


def figure_tuple_guard(helper, root, *, authenticated=None):
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
        if authenticated is None:
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
    guard = figure_tuple_guard(helper, roots.pop(), authenticated=None if previous is None else previous[0])
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
        after = figure_tuple_guard(helper, Path(next(iter(paths.values()))).parent, authenticated=guard)
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



def validated_figure_tuple(snapshots, edition=None, date=None, *, parent_snapshots=None):
    paths={name:Path(path) for name,path in (snapshots or {}).items() if name in FIGURE_SNAPSHOT_FILES}
    if not paths:return {}
    missing=set(FIGURE_SNAPSHOT_FILES)-set(paths)
    if missing:
        raise ValueError('Incomplete Figure input tuple; missing: '+', '.join(sorted(missing)))
    provider=(snapshots or {}).get('file-metadata')
    if provider is not None and Path(provider).parent in {path.parent for path in paths.values()}:
        paths['file-metadata']=Path(provider)
    import prepare_figure_metadata
    parent_paths = None if parent_snapshots is None else {
        name: Path(parent_snapshots[name]) for name in paths if name in parent_snapshots}
    return verified_figure_tuple(prepare_figure_metadata,paths,edition,date,parent_paths=parent_paths)


def _validated_auxiliary_state(snapshots, edition=None, date=None, *, captured_selection=None):
    hashes={};namespace_inputs={};captures={}
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
    with build_phase(edition,date,'auxiliary_provider_verification',provider='figure-tuple'):
        figures=validated_figure_tuple(snapshots,edition,date)
    for name, source in sorted((snapshots or {}).items()):
        with build_phase(edition,date,'auxiliary_provider_verification',provider=name):
            if name not in AUXILIARY_SNAPSHOT_NAMES:
                raise ValueError(f'Unknown auxiliary snapshot: {name}')
            path=Path(source)
            capture=figures[name] if name in figures else validated_auxiliary_capture(name,path,edition,date)
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
                path=path.resolve()
                return any(path==root or path in root.parents or root in path.parents for root in owned)
            bound_figures={}
            capture_bindings=0;reused_capture_bindings=0
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
            borrower.last_capture_borrow=dict(borrowed_roles=sorted(borrowed),borrowed_capture_files=len(avoided),
                avoided_copy_bytes=sum(copies[key][0].stat().st_size for key in avoided))
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
))


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
        files.extend(path for path in root.rglob('*') if path.is_file() and path.suffix in ('.zig','.py','.c','.h','.zon'))
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


def build_input_identity(items, zig, auxiliary_hashes, interwiki_sha, expansion_timeout_ms, auxiliary_snapshots=None, downloads=None, reviewed_nonlexical=None, *, validate_auxiliary=False, native_roles=None):
    if validate_auxiliary and auxiliary_hashes is not None:
        raise ValueError('Fresh auxiliary validation does not accept supplied hashes')
    executable=shutil.which(zig)
    if executable is None:raise ValueError('Zig compiler executable is unavailable')
    identity=dict(version=1, source=source_fingerprint(),
                files=sorted([[i['wiki'],i['date'],i['name'],i['size'],i['sha1']] for i in items]),
                zig_sha256=sha256_file(Path(executable)),
                auxiliary_snapshot_sha256=auxiliary_hashes or {},
                interwiki_map_sha256=interwiki_sha, expansion_timeout_ms=expansion_timeout_ms)
    if _PYTHON_TOOLING is not None:identity['python_tooling']=_PYTHON_TOOLING.require_unchanged()
    if native_roles is not None:
        if not isinstance(native_roles, RetainedNativeToolRoles):
            raise ValueError('Invalid retained native role selection')
        identity['native_tool_roles']=native_roles.provenance()
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
    temporary.write_text(json.dumps(identity,sort_keys=True)+'\n')
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
            if not batch: return
            if len(batch)>max_parallel_bytes:
                while queued: finish_oldest()
                raw=bytes(batch)
                write_member(zstd.compress(raw,level=1),len(raw))
                batch.clear()
                return
            if len(queued)==max_queued_batches: finish_oldest()
            raw=bytes(batch)
            batch.clear()
            queued.append((pool.submit(zstd.compress,raw,level=1),len(raw)))

        for source in parts:
            with bz2.open(source,'rb') as inp:
                while chunk:=inp.read(1024*1024):
                    xml_bytes+=len(chunk)
                    pending.extend(chunk)
                    consumed=0
                    while (end:=pending.find(close_tag,consumed))>=0:
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
                self.condition.wait(timeout=0.1)
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
                self.condition.wait(timeout=0.1)
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
                raw=bytes(batch)
                frame=zstd.compress(raw,level=1)
                info=zstd.get_frame_info(frame)
                if info.decompressed_size!=len(raw) or zstd.get_frame_size(frame)!=len(frame):
                    raise ValueError('Staged Zstandard member is not one known-size frame')
                output.put_frame(frame)
                batch.clear()

            with bz2.open(source,'rb') as inp:
                while chunk:=inp.read(1024*1024):
                    xml_bytes+=len(chunk)
                    pending.extend(chunk)
                    consumed=0
                    while (end:=pending.find(close_tag,consumed))>=0:
                        start=pending.find(open_tag,consumed)
                        if start<0 or start>end: raise _SplitPageAcrossParts(source)
                        cut=end+len(close_tag)
                        page_bytes=cut-consumed
                        if page_bytes>STAGE_MAX_MEMBER_BYTES:
                            raise ValueError(f'XML page exceeds bounded Zstandard member: {source}')
                        if len(batch)+page_bytes>STAGE_MAX_MEMBER_BYTES: flush()
                        batch.extend(memoryview(pending)[consumed:cut])
                        consumed=cut
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


def inspect_page_index(path):
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
                if count % SHARD_PAGES == 0: offsets[count]=0 if count==0 else offset
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


def shard_state(items, registry, now_unix=None, interwiki_snapshot=None, auxiliary_snapshots=None, reviewed_nonlexical=None):
    source,production_source=_source_fingerprints(include_production=True)
    state={
        'version':SHARD_STATE_VERSION,
        'edition':items[0]['wiki'],
        'date':items[0]['date'],
        'files':[[item['name'],item['size'],item['sha1']] for item in sorted(items,key=lambda x:x['name'])],
        'registry_sha256':sha256_file(registry),
        'source':source,
        'production_source':production_source,
        'shard_pages':SHARD_PAGES,
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
    state=json.loads(state_path.read_text()) if state_path.is_file() else {}
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
    state = read_small_json(state_path)
    state['native_generation'] = dict(seal_sha256=digest, dump=str(dump),
                                    build_inputs=json.loads(json.dumps(build_identity)))
    # The existing state publication is the last authority before readiness.
    temporary = state_path.with_suffix('.part')
    if os.path.lexists(temporary):
        raise ValueError('Unexpected native generation state transaction')
    try:
        with temporary.open('x') as output:
            output.write(json.dumps(state, sort_keys=True) + '\n')
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
            and not state_path.is_symlink() and read_small_json(state_path) == expected)


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
            read_small_json(state_path) != original or proof['workspace'] != str(workspace) or
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
            json.dump(state, stream, sort_keys=True);stream.write('\n')
        os.replace(temporary, state_path)
    finally:
        if created:temporary.unlink(missing_ok=True)
    return state['now_unix']


WRITER_FIGURE_ROLES = frozenset((*FIGURE_SNAPSHOT_FILES, 'file-metadata'))
WRITER_OBSERVATION_ROLES = frozenset(('figure-sizing', 'figure-sizing-raw'))


def writer_figure_worker_inputs(value, *, state=False):
    """Project only the inputs actually consumed by the sealed worker."""
    result = json.loads(json.dumps(value))
    ignored = ('source', 'production_source', 'now_unix', 'native_generation') if state else ('source', 'python_tooling', 'native_tool_roles')
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
    current = read_small_json(state_path)
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
            json.dump(desired, stream, sort_keys=True); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, state_path)
        descriptor = os.open(workspace, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(descriptor)
        finally: os.close(descriptor)
    finally:
        if created: temporary.unlink(missing_ok=True)
    return desired['now_unix']


def initial_sealed_generation(reference, native_roles):
    """Read a selected closed direct preparation, without inventing old shard state."""
    selected = prepared_metadata(reference)
    if set(selected) != {'preparation_result', 'preparation_closure'}:
        raise ValueError('Invalid initial sealed generation selection')
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
    if original_roles != native_roles.records:
        raise ValueError('Initial sealed preparation selected different native roles')
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


def adopt_initial_sealed_workspace(workspace, expected, now_unix, build_identity, dump, reference, native_roles):
    """Create genuine ordinary initial state for an explicitly selected sealed worker."""
    import extraction_cache as cache
    selected, result, plan, selected_workspace = initial_sealed_generation(reference, native_roles)
    if (workspace.is_relative_to(selected_workspace) or selected_workspace.is_relative_to(workspace)
            or dump is None or str(dump) != plan['dump']['path']
            or build_identity is None or expected.get('source') != build_identity.get('source')
            or native_roles.provenance() != build_identity.get('native_tool_roles')
            or plan['zig_sha256'] != build_identity.get('zig_sha256')
            or expected.get('auxiliary_snapshot_sha256', {}) != build_identity.get('auxiliary_snapshot_sha256', {})
            or expected.get('interwiki_map_sha256') != build_identity.get('interwiki_map_sha256')):
        raise ValueError('Initial sealed generation differs from ordinary inputs or tools')
    root = selected_workspace / 'expander' / '.bundle-expander'
    seal_reference = result['completed_expander_seal']
    seal = prepared_metadata(seal_reference)
    dependencies = native_roles.records['dict-bundle-build']['dependencies']
    graph = seal['origin_graph']
    for field, dependency in (('extractor', 'modules'), ('llvm', 'llvm'), ('runtime', 'worker_object'),
                              ('leaf', 'value_leaf_bc'), ('main_c', 'worker_main_c'), ('zig', 'zig')):
        if graph.get(field) != dependencies[dependency]['path']:
            raise ValueError('Initial sealed native graph differs from selected role')
    snapshots = {auxiliary_snapshot_filename(name): digest for name, digest in
                 build_identity.get('auxiliary_snapshot_sha256', {}).items()}
    if (plan['registry']['sha256'] != expected.get('registry_sha256')
            or plan['interwiki']['sha256'] != expected.get('interwiki_map_sha256')):
        raise ValueError('Initial sealed registry or interwiki source differs')
    snapshots.update({'interwiki-map.tsv': expected.get('interwiki_map_sha256'),
                      'wikibase-page-links.tsv': plan['page_links']['sha256'],
                      'page-redirects.tsv': plan['page_redirects']['sha256']})
    providers = seal['identity']['providers']
    if (any(value is not None and value[1] != snapshots.get(name) for name, value in providers.items())
            or any(name not in providers or providers[name] is None or providers[name][1] != value
                   for name, value in snapshots.items())
            or seal['identity']['verified_input'][0] != plan['dump']['sha256']):
        raise ValueError('Initial sealed snapshot or dump inputs differ')
    # This existing validator authenticates native mode/toolchain/ABI provenance,
    # source/index/sidecars and physical asset inventory without rehashing payloads.
    if cache.frozen_runtime_context(root, dump, seal_reference['sha256']) != seal:
        raise ValueError('Initial sealed generation is not finalized')
    observed = cache.finalize_sealed_expander(root, Path(dump), seal_reference['sha256'], graph,
        project_root=native_roles.records['dict-bundle-build']['source_root'])
    if observed != seal or cache.frozen_runtime_context(root, dump, seal_reference['sha256']) != seal:
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
    # Before the initial publication, only the two actual preparation products
    # are owned here. A partial blob/output or foreign entry cannot be adopted.
    def inventory():
        found = {}
        for path in (selected_workspace, selected_workspace / 'native-blob-tools', selected_workspace / 'native-blob-tools' / 'bin'):
            st = path.lstat()
            if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
                raise ValueError('Unsafe initial sealed preparation directory')
            found[str(path)] = (st.st_dev, st.st_ino, st.st_mode, st.st_mtime_ns, st.st_ctime_ns)
        if ({p.name for p in selected_workspace.iterdir()} != {'expander', 'native-blob-tools'}
                or {p.name for p in (selected_workspace / 'native-blob-tools').iterdir()} != {'bin'}
                or {p.name for p in (selected_workspace / 'native-blob-tools' / 'bin').iterdir()} != set(RETAINED_NATIVE_ROLE_NAMES)):
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
    before = inventory()
    if set(result['installed_tools']) != set(BLOB_TOOL_NAMES):
        raise ValueError('Initial sealed installed role inventory differs')
    for name in RETAINED_NATIVE_ROLE_NAMES:
        expected_artifact = native_roles.records[name]['artifact']
        descriptor = result['installed_tools'].get(name, dict(expected_artifact, path=str(selected_workspace / 'native-blob-tools' / 'bin' / name)))
        if (descriptor['path'] != str(selected_workspace / 'native-blob-tools' / 'bin' / name)
                or any(descriptor[k] != expected_artifact[k] for k in ('bytes', 'sha256'))):
            raise ValueError('Initial sealed installed role differs')
        actual = native_roles.bind_input(Path(descriptor['path']))
        if any(actual[k] != descriptor[k] for k in ('path', 'bytes', 'sha256')) or actual['mode'] != 0o555:
            raise ValueError('Initial sealed installed role bytes or mode changed')
    native_roles.require_unchanged()
    prepared_metadata(reference); prepared_metadata(selected['preparation_result']); prepared_metadata(selected['preparation_closure'])
    if inventory() != before or cache.frozen_runtime_context(root, dump, seal_reference['sha256']) != seal:
        raise ValueError('Initial sealed workspace changed during adoption')
    native_roles.initial_sealed_context = (root, Path(dump), seal_reference['sha256'])
    if os.path.lexists(state_path):
        state = read_small_json(state_path)
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
            json.dump(state, stream, sort_keys=True); stream.write('\n')
        # Publish without replacing a concurrent state or following a symlink.
        os.link(temporary, state_path)
    finally:
        temporary.unlink(missing_ok=True)
    return epoch


def prepare_shard_workspace(workspace, expected, now_unix=None, raw_shards_path=None, *, provider_update=None, build_identity=None, dump=None, sealed_recovery=None, native_roles=None, writer_figure_transition=None, initial_generation=None):
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
    if initial_generation is not None:
        if sealed_recovery is not None or writer_figure_transition is not None:
            raise ValueError('Initial sealed adoption cannot borrow another transition')
        return adopt_initial_sealed_workspace(workspace, expected, now_unix, build_identity, dump, initial_generation, native_roles)
    if writer_figure_transition is not None:
        if sealed_recovery is not None or generation is not None:
            raise ValueError('Writer Figure transition requires an ordinary completed worker')
        return writer_figure_adopt_workspace(workspace, expected, now_unix, build_identity, dump, writer_figure_transition, native_roles)
    existing=None
    state_path=workspace/'state.json'
    if state_path.is_symlink(): raise ValueError(f'Unsafe shard state: {state_path}')
    if state_path.is_file():
        try: existing=json.loads(state_path.read_text())
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
    temp.write_text(json.dumps(state,sort_keys=True)+'\n')
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
        recorded=read_small_json(state)
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
    phase_event(edition,date,name,'start',**fields)
    result=dict(fields)
    status='failure'
    try:
        yield result
        status='success'
    finally:
        phase_event(edition,date,name,'end',status=status,seconds=round(time.monotonic()-started,3),**result)


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
    # Keep the existing conservative native ABI equality for every role.
    ('native-runtime', RETAINED_NATIVE_ROLE_NAMES,
     tuple(name for name in RETAINED_NATIVE_ABI_PATHS if name not in (
         'src/encoder/blob_format.zig', 'src/encoder/blob_catalog.zig',
         'src/encoder/presentation_codec.zig', 'src/encoder/presentation_types.zig'))),
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
    payloads are authenticated once from retained bytes/Git; only actually read
    runtime dependencies remain in per-dispatch guards.
    """
    def __init__(self, roles, *, zig_sha256):
        import copy
        if set(roles) != set(RETAINED_NATIVE_ROLE_NAMES):
            raise ValueError('Incomplete retained native tool roles')
        self.records = copy.deepcopy(roles)
        self.initial_sealed_context = None
        self.initial_sealed_generation = self.records['dict-bundle-build'].pop('initial_sealed_generation', None)
        self.sealed_expander_recovery = self.records['dict-bundle-build'].pop('sealed_expander_recovery', None)
        self.writer_figure_transition = self.records['dict-blob-build'].pop('writer_figure_transition', None)
        if self.writer_figure_transition is not None and self.sealed_expander_recovery is not None:
            raise ValueError('Writer observation and pre-blob recovery transitions are distinct')
        if self.initial_sealed_generation is not None and (self.sealed_expander_recovery is not None or self.writer_figure_transition is not None):
            raise ValueError('Initial sealed adoption requires its own selection')
        self.tools, self.inputs, self.input_identities, self.directories = {}, {}, {}, {}
        self.zig_sha256 = zig_sha256
        self.compilation_payloads = {}
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
            fingerprint = source.get('fingerprint', row['source']['sha256'])
            if fingerprint != row['producer_source']:
                raise ValueError('Retained native tool source authority differs')
            root = Path(row['source_root'])
            if not root.is_absolute() or root.resolve() != root:
                raise ValueError('Unsafe retained native source root')
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
                identity = self.compilation_identity(row, relative)
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
            self.tools[role] = self.bind_tool(role,path) if not actual['mode'] & 0o222 else None
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
            temporary=target.with_name(target.name+'.part')
            with temporary.open('xb') as output,Path(artifact['path']).open('rb') as source:
                shutil.copyfileobj(source,output,1024*1024)
            self.require_unchanged()
            if sha256_file(temporary)!=artifact['sha256'] or temporary.stat().st_size!=artifact['bytes']:
                raise ValueError('Private native role copy differs')
            temporary.chmod(artifact['mode'] & ~0o222)
            # Atomic no-overwrite publication; discard only our temporary link.
            os.link(temporary,target);temporary.unlink()
        require_private_native_tool(target)
        self.tools[role]=self.bind_tool(role,target)
        self.require_unchanged()

    def provenance(self):
        import copy
        self.require_unchanged()
        return copy.deepcopy(self.records)

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
        for path,digest in expected.items():
            if self.bind_input(path)['sha256']!=digest:
                raise ValueError('Borrowed capture input differs from validated bytes')
        if figure_guard is not None and (figure.producer(),figure.metadata.producer(),figure.site_info.producer())!=runtime:
            raise ValueError('Borrowed Figure helper changed while binding')
        self.require_unchanged()

    def require_inputs_unchanged(self):
        context=getattr(self, 'initial_sealed_context', None)
        if context is not None:
            import extraction_cache as native_cache
            if native_cache.frozen_runtime_context(*context) is None:
                raise ValueError('Retained initial sealed input changed')
        for path,expected in getattr(self,'borrowed_capture_directories',{}).items():
            st=path.stat()
            if (any(parent.is_symlink() for parent in (path,*path.parents)) or
                    (st.st_dev,st.st_ino,st.st_mode,st.st_uid,st.st_mtime_ns,st.st_ctime_ns,tuple(sorted(path.iterdir())))!=expected):
                raise ValueError('Borrowed capture membership changed')
        for path, expected in self.directories.items():
            st=path.stat()
            if path.is_symlink() or (st.st_dev,st.st_ino,st.st_mode,st.st_uid)!=expected:
                raise ValueError('Retained native working directory changed')
        for path, stamp in self.inputs.items():
            if any(parent.is_symlink() for parent in (path, *path.parents)):
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
            # parseOptions starts at index 2; another occurrence may be a value.
            if len(args) < 3 or args[2] != '--expander-only' or args.count('--expander-only') != 1:
                raise ValueError('Retained bundle role is restricted to expander-only execution')

    def prepare(self, expander_args, edition, date, *, workspace=None, figure_inputs=None):
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
            source=source_fingerprint()
            compiler=shutil.which(zig)
            if compiler is None:raise ValueError('Zig compiler executable is unavailable')
            compiler=Path(compiler).resolve(strict=True)
            compiler_sha=sha256_file(compiler)
            if build_identity is not None and (source!=build_identity['source'] or compiler_sha!=build_identity['zig_sha256']):
                raise ValueError('Native blob tool preparation source or compiler differs from build identity')
            if retained_roles is not None:
                if (not isinstance(retained_roles, RetainedNativeToolRoles)
                        or retained_roles.zig_sha256 != compiler_sha
                        or getattr(_PREPARED_SOURCE, 'request', None) is not None
                        or build_identity is None
                        or build_identity.get('native_tool_roles') != retained_roles.provenance()):
                    raise ValueError('Retained roles do not match this ordinary preparation')
                command_started=time.monotonic()
                tools=retained_roles.prepare(expander_args, edition, date, workspace=workspace,figure_inputs=figure_inputs)
                post_started=time.monotonic()
                if source_fingerprint()!=source or sha256_file(compiler)!=compiler_sha:
                    raise ValueError('Source or compiler changed during retained role selection')
                retained_roles.require_unchanged()
                outcome.update(preparation='retained-role-selection', orchestration_source=source,
                    zig_sha256=compiler_sha, native_role_provenance=retained_roles.provenance(),
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
                shutil.copyfileobj(src,dst,1024*1024)
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
    state=read_small_json(state_path)
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
                        failure_receipt=str(receipt),returncode=error.returncode)
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


def build_sharded(dump, staging, workspace, registry, zig, workers, items, now_unix, expansion_workers=None, interwiki_snapshot=None, interwiki_sha=None, auxiliary_snapshots=None, auxiliary_hashes=None, expansion_timeout_ms=None, build_identity=None, page_links_snapshot=None, page_redirects_snapshot=None, raw_shards_path=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical=None, llvm_workers=None, staged_input_root=None, _staged_input_guard=None, presentation_audit_pages=None, retained_roles=None, continue_failed_shards=False, provider_update=None):
    if retained_roles is not None and (not compress_shards or not isinstance(retained_roles, RetainedNativeToolRoles)
            or getattr(_PREPARED_SOURCE,'request',None) is not None or getattr(_PREPARED_SOURCE,'value',None) is not None):
        raise ValueError('Retained roles require ordinary compressed sharded execution')
    validate_presentation_audit_pages(presentation_audit_pages, continue_failed_shards)
    validate_llvm_workers(llvm_workers)
    if type(compress_shards) is not bool: raise ValueError('Invalid compressed shard mode')
    timeout_args=expansion_deadline_args(expansion_timeout_ms)
    if raw_shards_path is not None:
        raw_shards_path=external_raw_shards(workspace,raw_shards_path,create=True)
        state=json.loads((workspace/'state.json').read_text())
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
    seal_for_provider_updates=(generation is None and getattr(_PREPARED_SOURCE,'request',None) is None
                               and WIKIBASE_PROVIDER_ROLES <= set(auxiliary_hashes or {}))
    if provider_update:
        if (not seal_for_provider_updates or provider_update['root']!=str(expander_build/'.bundle-expander')
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
        binding=read_small_json(state_path).get('native_generation') if state_path.is_file() else None
        if binding is not None:
            import extraction_cache as native_cache
            expected_binding_keys=({'seal_sha256','dump','build_inputs','retained_expander_root'} if initial_reference is not None else {'seal_sha256','dump','build_inputs','writer_figure_transition'} if writer_transition is not None else {'seal_sha256','dump','build_inputs'})
            if (not isinstance(binding,dict) or set(binding)!=expected_binding_keys
                    or binding['dump']!=str(dump)):
                raise ValueError('Bound ordinary native generation changed')
            if initial_reference is not None and binding['retained_expander_root']!=str(expander_build/'.bundle-expander'):
                raise ValueError('Retained initial sealed root changed')
            if writer_transition is not None:
                if binding['writer_figure_transition']!=writer_transition:
                    raise ValueError('Writer Figure transition binding changed')
                worker_auxiliary_hashes=binding['build_inputs']['auxiliary_snapshot_sha256']
            native_ready=native_cache.frozen_runtime_context(expander_build/'.bundle-expander',dump,binding['seal_sha256']) is not None
    worker_ready=native_ready and expander_ready(expander_build,worker_auxiliary_hashes,interwiki_sha,page_links_sha,page_redirects_sha) if generation is None else True
    if writer_transition is not None and not worker_ready:
        raise ValueError('Selected Writer Figure transition worker changed; existing generation preserved')
    if getattr(retained_roles, 'initial_sealed_generation', None) is not None and not worker_ready:
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
        index=inspect_page_index(index_path)
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
    if writer_transition is not None:
        roots={Path(auxiliary_snapshots[name]).parent for name in WRITER_FIGURE_ROLES}
        if len(roots)!=1:raise ValueError('Writer Figure observations require one complete pinned root')
        reviewed_args += ['--figure-input-root',str(roots.pop())]

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
    shard_paths=[]
    # A verified or complete-but-unmarked contiguous prefix is reusable after
    # a crash. The native continuous builder owns only an absent suffix, so it
    # cannot replace an existing shard directory.
    shard_starts=list(range(0,indexed_pages,SHARD_PAGES))
    prefix=[]
    for start in ([] if compress_shards else shard_starts):
        shard=shards_root/f'{start:08d}'
        if not shard.exists(): break
        limit=min(SHARD_PAGES,indexed_pages-start)
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
                   '--shard-pages',str(SHARD_PAGES),
                   '--workers',str(expansion_workers),'--now-unix',str(now_unix),*timeout_args,*reviewed_args],
                  edition,date,'continuous_shard_build',start_page=first,pages=indexed_pages-first)
        check_shard_inputs()
        for start in missing_starts:
            shard=shards_root/f'{start:08d}'
            limit=min(SHARD_PAGES,indexed_pages-start)
            validate_page_coverage(shard,start,limit,index,index['offsets'][start])
            verifier.run([str(shard)],
                      edition,date,'shard_verify',start_page=start,pages=limit)
            (shard/'.verified').write_text('verified\n')
            check_shard_inputs()
        shard_paths=prefix+[shards_root/f'{start:08d}' for start in missing_starts]
        continuous_handled=True
    failed_shards=[]
    if not continuous_handled:
        shard_paths=[]
        for start in range(0,indexed_pages,SHARD_PAGES):
            limit=min(SHARD_PAGES,indexed_pages-start)
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
                     '--workers',str(expansion_workers),'--now-unix',str(now_unix),*timeout_args,*reviewed_args]
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
                        expansion_workers,now_unix,timeout_args,reviewed_args,check_audit_inputs,receipt)
                    if continue_failed_shards:
                        # Never extend a failed shard's audit into another shard.
                        # Only this typed, source-bound rejection permits continuation.
                        try:
                            summary=audit_failed_shard(blob_builder,dump,expander,evidence_root,
                                edition,date,start,indexed_pages,min(presentation_audit_pages,limit),
                                expansion_workers,now_unix,timeout_args,reviewed_args,
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
    actual_pages=sum(validate_page_coverage(path,start,min(SHARD_PAGES,indexed_pages-start),index,index['offsets'][start])['pages_seen']
                     for path,start in zip(shard_paths,range(0,indexed_pages,SHARD_PAGES)))
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


def build(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, raw_shard_root=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None, presentation_audit_pages=None, retained_roles=None, continue_failed_shards=False):
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
                if initial_reference is not None:
                    selected_workspace = initial_sealed_generation(initial_reference, retained_roles)[3]
                    owned.enter_context(acquire_build_resource_lock(selected_workspace/'expander'/'.bundle-expander'/'.compiler-inputs.lock'))
                # An existing publication is verification-only even when input or
                # publication checks fail before build_locked can return its mode.
                # Legitimate producers share this edition lock; success still overrides.
                if (parent / date / 'complete.json').exists():
                    result['execution_mode']='existing_output'
                mode=build_locked(items, downloads, output, zig, compression_workers, expansion_workers, interwiki_snapshot, auxiliary_snapshots, **({'expansion_timeout_ms':expansion_timeout_ms} if expansion_timeout_ms is not None else {}), **({'now_unix':now_unix} if now_unix is not None else {}), **({'raw_shard_root':raw_shard_root} if raw_shard_root is not None else {}), **({'compress_shards':True} if compress_shards else {}), **({'extraction_cache_root':extraction_cache_root} if extraction_cache_root is not None else {}), reviewed_nonlexical_review=reviewed_nonlexical_review, **({'llvm_workers':llvm_workers} if llvm_workers is not None else {}), **({'staged_input_root':staged_input_root} if staged_input_root is not None else {}), **({'presentation_audit_pages':presentation_audit_pages} if presentation_audit_pages is not None else {}), **({'continue_failed_shards':True} if continue_failed_shards else {}), **({'retained_roles':retained_roles} if retained_roles is not None else {}))
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


def validate_fallback_report(path, namespace_counts=None, reason_counts=None):
    if not path.is_file():
        raise ValueError(f'Missing fallback report: {path}')
    count = 0
    counts = {}
    reasons_seen = {}
    seen = set()
    with path.open(encoding='utf-8') as lines:
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
                parts = reason.split(':')
                if len(parts) in (2, 3) and parts[0] == 'expansion_error' and parts[-1] in ('Timeout', 'OutOfMemory'):
                    kind = 'timeout' if parts[-1] == 'Timeout' else 'out of memory'
                    raise ValueError(f'Operational expansion {kind} at {path}:{line_number}; rebuild this output')
                if len(parts)==3 and parts[0]=='expansion_error' and parts[1]!='expand':
                    raise ValueError(f'Infrastructure expansion failure at {path}:{line_number}; rebuild this output')
            key = (namespace, title)
            if key in seen:
                raise ValueError(f'Duplicate fallback page at {path}:{line_number}: {namespace}:{title}')
            seen.add(key)
            count += 1
            counts[namespace] = counts.get(namespace, 0) + 1
            for reason in reasons:
                reasons_seen[reason] = reasons_seen.get(reason, 0) + 1
    if namespace_counts is not None:
        # Commit the output only after the complete report is valid.
        namespace_counts.clear()
        namespace_counts.update(counts)
    if reason_counts is not None:
        # Reasons overlap across pages; these counts are not an acceptance verdict.
        reason_counts.clear()
        reason_counts.update(reasons_seen)
    return count

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

def publication_inventory(root, *, allow_raw=False):
    """Pin verified data bytes so resume cannot bless missing or changed output."""
    required={'languages.tsv','page-coverage.json','namespace-coverage.json','fallback-pages.jsonl'}
    metadata=required|{nonlexical.NAME,'compile-plan.tsv','module-compile-plan.tsv',BUILD_IDENTITY_NAME,
                       INTERWIKI_SHA_NAME,AUXILIARY_SHA_NAME,NOW_UNIX_NAME}
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
    if not required.issubset(inventory):raise ValueError('Missing required publication report or language manifest')
    return inventory

def seal_verified_publication_inventory(staging, *, fresh_compressed=False):
    """Seal native-verified logical bytes before compression can remove raw twins."""
    files=publication_inventory(staging,allow_raw=True)
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
    """Admit only sealed members/content; never adopt surviving files on resume."""
    path=artifact_path(staging/VERIFIED_INVENTORY_NAME)
    if not path.is_file() or path.is_symlink():
        raise ValueError('Verified staging lacks its sealed inventory; preserve and rebuild separately')
    before=index_identity(path.stat());saved=read_small_json(path,8*1024*1024)
    if index_identity(path.stat())!=before:raise ValueError('Verified inventory changed while reading')
    if not isinstance(saved,dict) or set(saved)!={'version','files'} or type(saved['version']) is not int or saved['version']!=1 or not isinstance(saved['files'],dict):
        raise ValueError('Invalid verified publication inventory')
    expected=saved['files'];actual=publication_inventory(staging,allow_raw=True);allowed=set()
    verified_compressed=verified_compressed or {};checked={}
    for name,record in expected.items():
        relative=Path(name)
        if (not isinstance(name,str) or relative.is_absolute() or '..' in relative.parts or
                relative.as_posix()!=name or not isinstance(record,dict) or set(record)!={'size','sha256'} or
                type(record['size']) is not int or record['size']<0 or not isinstance(record['sha256'],str) or
                not re.fullmatch('[0-9a-f]{64}',record['sha256']) or name.endswith('.wikblb.xz')):
            raise ValueError('Invalid verified publication member')
        allowed.add(name)
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
    return expected,checked


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
        require_build_identity(read_small_json(staging/BUILD_IDENTITY_NAME) if (staging/BUILD_IDENTITY_NAME).is_file() else None,build_identity)
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
    fallback_counts = {}
    fallback_reasons = {}
    fallback_pages = validate_fallback_report(staging / 'fallback-pages.jsonl', fallback_counts, fallback_reasons)
    namespace_totals=validate_namespace_coverage(staging,coverage['pages_seen'],namespace_snapshot,fallback_counts,site_info_snapshot)
    nonlexical.check_coverage(staging,build_identity)
    if namespace_snapshot is not None and namespace_totals['fallback_pages']!=fallback_pages:raise ValueError('Namespace fallback totals differ from fallback report')
    for part in staging.rglob('*.xz.part'):
        unlink_artifact(part)
    sealed,checked_compressed=validate_verified_publication_inventory(staging)
    if _staged_input_guard is not None:_staged_input_guard()
    if build_identity is not None:
        # Only authenticated merged bytes may replace the owned shard recovery copies.
        # Retire them before XZ, including a resume after earlier cleanup failed.
        cleanup_shard_workspace(target.with_name(date+'.shards'))
    raw = sorted(staging.rglob('*.wikblb'))
    compressed = sorted(staging.rglob('*.wikblb.xz'))
    logical = {name for name in sealed if name.endswith('.wikblb')}
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
    compressed = sorted(staging.rglob('*.wikblb.xz'))
    if ({path.relative_to(staging).as_posix()[:-3] for path in compressed} != logical or
            list(staging.rglob('*.wikblb')) or list(staging.rglob('*.xz.part'))):
        raise ValueError(f'Incomplete compressed publication: {staging}')
    validate_verified_publication_inventory(staging,checked_compressed)
    inventory=publication_inventory(staging)
    metadata = {'edition':edition,'date':date,'dump_staging_version':DUMP_STAGING_VERSION,
        'dump_codec':'zstd','dump_stream_kind':'multistream-zstd',
        'status':'built' if compressed else 'empty', 'fallback_pages':fallback_pages,
        'fallback_reason_counts':fallback_reasons,
        'fallback_report':'fallback-pages.jsonl', 'compression':'xz -0; 1 MiB blocks','blobs':len(compressed),
        'input_pages':coverage['pages_seen'],'page_coverage_report':'page-coverage.json',
        'namespace_coverage_report':'namespace-coverage.json','namespace_coverage_totals':namespace_totals,
        'publication_files':inventory}
    if build_identity is not None:metadata['build_inputs']=build_identity
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

def build_locked(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, raw_shard_root=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None, presentation_audit_pages=None, retained_roles=None, continue_failed_shards=False):
    if retained_roles is not None and not isinstance(retained_roles,RetainedNativeToolRoles):
        raise ValueError('Invalid retained native input guards')
    validate_presentation_audit_pages(presentation_audit_pages, continue_failed_shards)
    with borrowed_staged_input(items,staged_input_root,output,raw_shard_root,extraction_cache_root) as (borrowed,check):
        def input_guard():
            if check is not None:check()
            if retained_roles is not None:retained_roles.require_inputs_unchanged()
        try:
            return _build_locked(items,downloads,output,zig,compression_workers,expansion_workers,
            interwiki_snapshot,auxiliary_snapshots,expansion_timeout_ms,now_unix,raw_shard_root,
            compress_shards,extraction_cache_root,reviewed_nonlexical_review,llvm_workers,borrowed,input_guard,
            **({'presentation_audit_pages':presentation_audit_pages} if presentation_audit_pages is not None else {}), **({'continue_failed_shards':True} if continue_failed_shards else {}), **({'retained_roles':retained_roles} if retained_roles is not None else {}))

        finally:
            input_guard()


def _build_locked(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, raw_shard_root=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None, _staged_input_guard=None, presentation_audit_pages=None, retained_roles=None, continue_failed_shards=False):
    if retained_roles is not None and (not compress_shards or not isinstance(retained_roles, RetainedNativeToolRoles)
            or getattr(_PREPARED_SOURCE,'request',None) is not None or getattr(_PREPARED_SOURCE,'value',None) is not None):
        raise ValueError('Retained roles require ordinary compressed sharded execution')
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
        build_identity=build_input_identity(items,zig,None,interwiki_sha,expansion_timeout_ms,auxiliary_snapshots,downloads,reviewed,validate_auxiliary=True, **({'native_roles':retained_roles} if retained_roles is not None else {}))
        generation=getattr(_PREPARED_SOURCE,'value',None)
        if generation is not None:generation.require_identity(build_identity)
        auxiliary_hashes=build_identity['auxiliary_snapshot_sha256']
    target = output / edition / date
    initial_generation = getattr(retained_roles, 'initial_sealed_generation', None) if retained_roles is not None else None
    initial_workspace = initial_sealed_generation(initial_generation, retained_roles)[3] if initial_generation is not None else None
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
        fallback_pages=validate_fallback_report(target/'fallback-pages.jsonl', fallback_counts, fallback_reasons)
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
                           ('namespace_coverage_report','namespace-coverage.json'),
                           ('fallback_report','fallback-pages.jsonl')):
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
        expected=shard_state(items,registry,interwiki_snapshot=interwiki_snapshot,auxiliary_snapshots=auxiliary_snapshots,reviewed_nonlexical=reviewed)
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
        if initial_generation is not None:
            update_args=dict(initial_generation=initial_generation, native_roles=retained_roles,
                             build_identity=build_identity, dump=(staged_input_root if staged_input_root is not None else workspace/'input')/'pages.xml.zst')
        now_unix=prepare_shard_workspace(workspace,expected,now_unix,**({'raw_shards_path':raw_shards_path} if raw_shards_path is not None else {}),**update_args)
        if reviewed is not None:nonlexical.pin_review(reviewed,workspace/'reviewed-nonlexical-source.json')
    dump=(staged_input_root/'pages.xml.zst') if staged_input_root is not None else cached_shard_dump(xml,downloads,workspace)
    source_metadata=read_small_json((staged_input_root if staged_input_root is not None else workspace/'input')/'.complete.json')
    if not isinstance(source_metadata,dict) or type(source_metadata.get('source_pages')) is not int or source_metadata['source_pages']<0:
        raise ValueError('Staged dump lacks a verified source page count')
    source_pages=source_metadata['source_pages']
    with build_phase(phase_edition,phase_date,'snapshot_staging') as snapshot_outcome:
        pinned=copy_verified_snapshot(interwiki_snapshot,workspace/'interwiki-map.tsv',interwiki_sha) if interwiki_snapshot else None
        if writer_transition is None:
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
    if (source_pages>SHARD_PAGES or reviewed is not None or presentation_audit_pages is not None
            or retained_roles is not None or getattr(_PREPARED_SOURCE,'request',None) is not None):
        print(f'Sharding {edition}: {source_pages:,} verified source pages in {SHARD_PAGES:,}-page chunks',flush=True)
        build_sharded(dump,staging,workspace,registry,zig,workers,items,now_unix,expansion_workers,pinned,interwiki_sha,aux_pinned,auxiliary_hashes, build_identity=build_identity, **({'page_links_snapshot':page_links_snapshot} if page_links_snapshot is not None else {}), **({'page_redirects_snapshot':page_redirects_snapshot} if page_redirects_snapshot is not None else {}), **({'expansion_timeout_ms':expansion_timeout_ms} if expansion_timeout_ms is not None else {}), **({'raw_shards_path':raw_shards_path} if raw_shards_path is not None else {}), **({'compress_shards':True} if compress_shards else {}), **({'extraction_cache_root':extraction_cache_root} if extraction_cache_root is not None else {}), reviewed_nonlexical=reviewed, **({'llvm_workers':llvm_workers} if llvm_explicit else {}), **({'staged_input_root':staged_input_root} if staged_input_root is not None else {}), **({'_staged_input_guard':_staged_input_guard} if _staged_input_guard is not None else {}), **({'presentation_audit_pages':presentation_audit_pages} if presentation_audit_pages is not None else {}), **({'continue_failed_shards':True} if continue_failed_shards else {}), **({'retained_roles':retained_roles} if retained_roles is not None else {}),**({'provider_update':provider_update} if provider_update else {}))
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


def build_groups(groups, downloads, output, zig, threads, jobs, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, edition_options=None, admission_wait_seconds=RESOURCE_ADMISSION_WAIT_SECONDS, cpu_admission='load', raw_shard_root=None, adaptive_workers=False, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None, presentation_audit_pages=None, continue_failed_shards=False):
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
            done,_=concurrent.futures.wait(active,timeout=1,return_when=concurrent.futures.FIRST_COMPLETED)
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


def parse_retained_native_roles(value, zig, *, sharded, edition_count, jobs):
    if value is None:return None
    if (not sharded or edition_count != 1 or jobs != 1
            or os.environ.get('WIKIDICT_PREPARED_SOURCE_ATTEMPT') is not None
            or _prepared_bootstrap_sys._xoptions.get('wikidict_prepared_source') == '1'):
        raise ValueError('Retained native roles require one ordinary compressed edition')
    roles=json.loads(value)
    if not isinstance(roles,dict):raise ValueError('Invalid retained native roles')
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
    p.add_argument('--compress-shards',action='store_true',help='Verify and compress each temporary shard before building the next; merged output remains raw until verified')
    p.add_argument('--staged-input-root',type=Path,metavar='DIR',help='Read-only completed repack input directory for exactly one edition; validates existing marker and bytes, never copies or retires it')
    p.add_argument('--extraction-cache-root',type=Path,metavar='DIR',help='Existing verified native extraction/object cache for one edition; cache identities are checked against fresh build inputs')
    p.add_argument('--raw-shard-root',type=Path,metavar='DIR',help='Optional raw shard volume; input/native caches and merged publication remain under --output')
    p.add_argument('--zig',default=shutil.which('zig') or 'zig')
    p.add_argument('--python-tooling-json',help='Explicit source-bound Python script/helper selection; native source root remains separately bound')
    p.add_argument('--retained-native-roles-json',help='Explicit source-bound retained native role selection for one compressed edition; original producer provenance is retained')
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
        retained_roles=parse_retained_native_roles(a.retained_native_roles_json,a.zig,
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
                          None if a.expansion_workers is None else expansion_workers,**options)
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
        route.add_argument('--retained-native-roles-json')
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
                                 'disk_paths':(workspace/'.tmp', routing.output)}
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
