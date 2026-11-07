#!/usr/bin/env python3
"""Build every fully downloaded snapshot; publish verified extreme-XZ blobs."""
import argparse
import bz2
try:
    from compression import zstd
except ImportError:
    zstd = None
import concurrent.futures
from collections import deque
from contextlib import contextmanager
import fcntl
import hashlib
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
from compress_blobs import compress, compress_many, default_workers, verify_round_trip
from build_disk_limits import BUILD_DISK_RESERVE_BYTES, require_merge_disk_space, compressed_blob_size
from build_artifact_root import configure_artifact_root, artifact_path, remove_artifact_tree, unlink_artifact
from download_wiktionaries import digest, language_registry_snapshot, validate_item, write_language_registry, select_manifest_files, derived_registry_paths, load_input_manifest
import reviewed_nonlexical as nonlexical

PROJECT = Path(__file__).resolve().parent.parent
SHARD_PAGES = 100_000
SHARD_RETRIES = 3
SHARD_STATE_VERSION = 3
AUXILIARY_SNAPSHOT_NAMES = (
    'stylesheet-imports', 'site-info', 'site-statistics-format', 'category-statistics-format', 'commons-data', 'category-stats', 'interface-messages', 'category-tree',
    'wikibase-sitelinks', 'wikibase-entity-text', 'wikibase-entities',
    'wikibase-entity-terms', 'wikibase-page-links', 'language-fallbacks', 'language-names', 'date-numbering', 'file-metadata',
    'transclusion-redirects', 'namespace-registry', 'language-registry', 'magic-words', 'behavior-switches', 'image-options',
)
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
    if (PROJECT!=Path(__file__).resolve().parent.parent
            or PROJECT==root or not PROJECT.is_relative_to(root/'.tmp')):
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


def sha256_file(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


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
    if name=='stylesheet-imports':return 'stylesheet-imports.json'
    if name=='site-statistics-format':return 'site-statistics-format.json'
    if name=='category-statistics-format':return 'category-statistics-format.json'
    return 'namespace-siteinfo.raw.json' if name=='site-info' else name+'.tsv'


def auxiliary_manifest_filename(name, path=None):
    if name=='site-info' and path is not None:
        modern=Path(path).with_name('site-info.manifest.json')
        if modern.exists() or modern.is_symlink():return modern.name
    return 'namespace-registry.manifest.json' if name=='site-info' else name+'.manifest.json'


def auxiliary_capture_helper(name, path):
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
        if schema=='wikidict.file-metadata-capture.v2':
            import prepare_file_metadata_v2
            return prepare_file_metadata_v2
        if schema=='wikidict.file-metadata-union.v1':
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
    if isinstance(record,dict) and record.get('schema')=='wikidict.language-messages-union.v1':
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


def validated_auxiliary_capture(name, path, edition=None, date=None):
    helper=auxiliary_capture_helper(name,path)
    if helper is None:return None
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
            'prepare_site_info','prepare_language_names_translate'):
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
    for name,source in sorted((snapshots or {}).items()):
        capture=validated_auxiliary_capture(name,Path(source),edition,date)
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


def _validated_auxiliary_state(snapshots, edition=None, date=None, *, captured_selection=None):
    hashes={};namespace_inputs={};captures={}
    for name, source in sorted((snapshots or {}).items()):
        if name not in AUXILIARY_SNAPSHOT_NAMES:
            raise ValueError(f'Unknown auxiliary snapshot: {name}')
        path=Path(source)
        capture=validated_auxiliary_capture(name,path,edition,date)
        if captured_selection is not None and name!='language-registry':
            selected_capture,selected_sources,capture_root=captured_selection
            # Share only this freshly validated result with the adjacent source
            # binding check. Nothing escapes this call or skips later rechecks.
            _validate_captured_snapshot_context(name,path,selected_capture,
                selected_sources,capture_root,capture)
        if capture is not None and name in ('stylesheet-imports','language-fallbacks','interface-messages','commons-data','language-names','date-numbering','site-info','site-statistics-format','category-statistics-format','wikibase-page-links','file-metadata','behavior-switches','image-options'):
            namespace_inputs[name]=capture[0]['namespace_registry_sha256']
        path=path.resolve(strict=True)
        if not path.is_file(): raise ValueError(f'Auxiliary snapshot is not a file: {path}')
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
    needs_capture=(name in ('stylesheet-imports','behavior-switches','image-options','wikibase-page-links','site-info') or
        (capture_root is not None and name in ('wikibase-entities','wikibase-entity-terms',
            'language-fallbacks','interface-messages','commons-data','language-names','date-numbering','file-metadata')))
    bound=validated_auxiliary_capture(name,path,capture.get('wiki'),capture.get('date')) if needs_capture else None
    return _validate_captured_snapshot_context(name,path,capture,selected,capture_root,bound)


def _validate_captured_snapshot_context(name,path,capture,selected,capture_root,bound):
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
    if directory=='language-names-autonyms-v1' and helper.__name__!='prepare_language_names_autonyms':
        raise ValueError('Preferred autonym names require their versioned capture profile')
    if directory=='language-messages-loop-v1':
        import prepare_language_messages_v2 as messages
        import prepare_language_messages_union as message_union
        if helper not in (messages,message_union):
            raise ValueError('Preferred loop messages require the current v2 capture profile')
    for path in snapshots.values():
        record=helper.validate_snapshot(path,edition,date)
        if directory=='language-messages-loop-v1':
            if helper is message_union:
                message_union.require_preferred_loop(record)
                continue
            messages.require_preferred_loop(record)
    return snapshots


def resolve_edition_snapshot_options(manifest, groups, downloads, overrides=None, *, workspace=None):
    """Resolve each edition independently; never reuse another edition's captures."""
    workspace=PROJECT if workspace is None else workspace
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
            preferred.update(discover(root,'site-statistics-format-v1',
                ('site-statistics-format',),edition,date))
            preferred.update(discover(root,'category-statistics-format-v1',
                ('category-statistics-format',),edition,date))
            for name in AUXILIARY_SNAPSHOT_NAMES:
                if name in preferred or name in (overrides or {}):continue
                path=root/(auxiliary_snapshot_filename(name))
                sidecar=root/(auxiliary_manifest_filename(name))
                present=[p.exists() or p.is_symlink() for p in (path,sidecar)]
                if any(present) and (not all(present) or not path.is_file() or not sidecar.is_file()):raise ValueError(f'Uncommitted auxiliary snapshot: {path}')
                if all(present):snapshots[name]=path
            snapshots.update(preferred)
            if "magic-words" not in (overrides or {}):
                from prepare_magic_words_category import selected_snapshot_root
                magic_root=selected_snapshot_root(root)
                if magic_root.exists() or magic_root.is_symlink():
                    if magic_root.is_symlink() or not magic_root.is_dir():raise ValueError('Unsafe magic-word capture root')
                    path=magic_root/'magic-words.tsv'
                    from prepare_magic_words_category import validate_snapshot
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


def pipeline_snapshot_args(registry, snapshots, page_links_snapshot=None, page_redirects_snapshot=None):
    merged=dict(snapshots or {})
    merged.setdefault('language-registry',registry)
    if page_links_snapshot is not None:merged['wikibase-page-links']=page_links_snapshot
    if page_redirects_snapshot is not None:merged['page-redirects']=page_redirects_snapshot
    return auxiliary_snapshot_args(merged)


def pinned_auxiliary_snapshots(snapshots, hashes, destination, capture_hashes=None, capture_artifact_hashes=None):
    pinned={};copies={};captures={}
    def add_copy(source,folder,filename,digest):
        key=(folder,filename)
        if key in copies and copies[key][1]!=digest:
            raise ValueError('Conflicting auxiliary capture artifact: '+filename)
        copies.setdefault(key,(source,digest))
    for name,source in sorted((snapshots or {}).items()):
        source=Path(source)
        capture=validated_auxiliary_capture(name,source)
        autonym_capture=(name=='language-names' and capture is not None and
                         capture[0].get('schema')=='wikidict.language-names-autonym-capture.v1')
        # Keep complete directory-provenance captures separate from other
        # snapshots so strict replay sees only their own recorded payloads.
        folder=destination/name if name in ('stylesheet-imports','commons-data','date-numbering','site-statistics-format','category-statistics-format') or autonym_capture else (
            destination/'site-info' if name=='site-info' and
            auxiliary_manifest_filename(name,source)=='site-info.manifest.json' else destination)
        if folder.is_symlink():raise ValueError('Unsafe auxiliary capture directory: '+str(folder))
        pinned[name]=folder/(auxiliary_snapshot_filename(name))
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
        for filename,digest in inventory.items():add_copy(source.with_name(filename),folder,filename,digest)
    # Validate every source and detect conflicting paired captures before
    # copying. Shared payloads are copied once and revalidated as a whole.
    for (folder,filename),(source,digest) in sorted(copies.items()):
        copy_verified_snapshot(source,folder/filename,digest)
    for name,inventory in captures.items():
        capture=validated_auxiliary_capture(name,pinned[name])
        if capture is None or capture[1]!=inventory:
            raise ValueError('Auxiliary capture changed while pinning: '+name)
    return pinned


def auxiliary_snapshot_args(snapshots):
    return [piece for name,path in sorted((snapshots or {}).items())
            for piece in ('--'+name+'-snapshot',str(path))]


# These standalone orchestration/qualification tools are not imported or
# executed by the ordinary production dependency graph. Keep every other source
# file, including tests, in the conservative production cache identity.
SHARD_SOURCE_EXCLUSIONS = frozenset((
    'tools/corpus_controller.py', 'tools/test_corpus_controller.py',
    'tools/native_qualification.py', 'tools/test_native_qualification.py',
))


def _source_fingerprints(include_production=False):
    checksum=hashlib.sha256()
    production=hashlib.sha256(b'wikidict.shard-production-source.v1\0') if include_production else None
    files=[]
    for name in ('build.zig','build.zig.zon'):
        path=PROJECT/name
        if path.is_file(): files.append(path)
    for folder in ('src','tools'):
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


def build_input_identity(items, zig, auxiliary_hashes, interwiki_sha, expansion_timeout_ms, auxiliary_snapshots=None, downloads=None, reviewed_nonlexical=None, *, validate_auxiliary=False):
    if validate_auxiliary and auxiliary_hashes is not None:
        raise ValueError('Fresh auxiliary validation does not accept supplied hashes')
    executable=shutil.which(zig)
    if executable is None:raise ValueError('Zig compiler executable is unavailable')
    identity=dict(version=1, source=source_fingerprint(),
                files=sorted([[i['wiki'],i['date'],i['name'],i['size'],i['sha1']] for i in items]),
                zig_sha256=sha256_file(Path(executable)),
                auxiliary_snapshot_sha256=auxiliary_hashes or {},
                interwiki_map_sha256=interwiki_sha, expansion_timeout_ms=expansion_timeout_ms)
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
    if source_fingerprint()!=identity['source']:
        raise ValueError('Compiler source changed during build; refusing publication')
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


def shard_cache_identity(state):
    """Compare v3 production inputs while retaining its original audit source."""
    comparable={k:v for k,v in state.items() if k!='now_unix'}
    if state.get('version')==SHARD_STATE_VERSION:
        for name in ('source','production_source'):
            value=state.get(name)
            if not isinstance(value,str) or re.fullmatch(r'[0-9a-f]{64}',value) is None:
                raise ValueError('Invalid shard source identity: '+name)
        comparable.pop('source')
    return comparable


def prepare_shard_workspace(workspace, expected, now_unix=None, raw_shards_path=None):
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
    if workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
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
            if selected is not None: external_raw_shards(workspace,selected,create=True)
            return existing['now_unix']
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


def timed_run(command, edition, date, phase, **fields):
    with build_phase(edition,date,phase,**fields):
        run_checked(command)


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


class PreparedBlobTool:
    def __init__(self, path):
        self.path=path
        self.stamp=native_tool_stamp(path)
        self.sha256=sha256_file(path)
        self.require_unchanged()

    def require_unchanged(self):
        if native_tool_stamp(self.path)!=self.stamp:
            raise ValueError('Prepared native tool changed: '+str(self.path))

    def command(self, args):
        self.require_unchanged()
        return [str(self.path),*args]

    def run(self, args, edition, date, phase, **fields):
        command=self.command(args)
        try:
            timed_run(command,edition,date,phase,**fields)
        finally:
            self.require_unchanged()


def prepare_blob_tools(workspace, zig, edition, date, build_identity=None, *, expander_args=None):
    """Use the existing Zig graph once, then bind its private installed outputs."""
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
            prefix=(workspace/'native-blob-tools').absolute()
            require_native_tool_directory(prefix)
            for name in BLOB_TOOL_NAMES:
                path=prefix/'bin'/name
                if path.exists() or path.is_symlink():require_private_native_tool(path)
            command=[str(compiler),'build','-j1','-Doptimize=fast','--prefix',str(prefix),'prepare-blob-tools']
            if expander_args is not None:
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


class DeterministicBuildInputFailure(subprocess.CalledProcessError):
    def __init__(self, original, receipt):
        super().__init__(original.returncode, original.cmd, output=original.output, stderr=original.stderr)
        self.failure_receipt = str(receipt)


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
        elif (row.get('failure_class'),row.get('error_name')) == ('deterministic-build-input','InterfaceMessageSnapshotMissing'):
            worker=row.get('worker');source=row.get('source')
            if (not isinstance(worker,dict) or worker.get('stage')!='expand'
                    or worker.get('error_name')!='InterfaceMessageSnapshotMissing'
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
            missing_input = deterministic and matched_failure[0] == 'InterfaceMessageSnapshotMissing'
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
                raise failure_type(error, matched_failure[1]) from error
            if not may_retry: raise error
            last_error = error
            print(f'Retrying failed shard builder {edition} start={start} attempt={attempt}/{SHARD_RETRIES}', flush=True)
            continue
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
    for raw in list(shard_blob_paths(shard)):
        if not raw.name.endswith('.wikblb'): continue
        target = Path(str(raw)+'.xz')
        if target.exists():
            if not stat.S_ISREG(target.lstat().st_mode): raise ValueError(f'Unsafe compressed shard: {target}')
            verify_round_trip(raw,target)
        else:
            compress(raw,1024*1024,workers=1)
        # Both target contents and its directory entry precede recovery deletion.
        fd = os.open(target,os.O_RDONLY|os.O_NOFOLLOW)
        try: os.fsync(fd)
        finally: os.close(fd)
        sync_shard_directory(target.parent)
        # A raw-unlink failure preserves both copies; resume rechecks equivalence.
        unlink_artifact(raw)
        sync_shard_directory(target.parent)


def extraction_cache_args(cache_root, staged):
    if cache_root is None:return []
    cache_root=Path(cache_root).absolute()
    if cache_root.is_symlink() or (cache_root.exists() and not cache_root.is_dir()):
        raise ValueError('Extraction cache root must be a regular directory')
    return ['--extraction-cache-root',str(cache_root),
            '--verified-dump-sha256',staged['dump_sha256'],
            '--verified-index-sha256',staged['index_sha256']]


def build_sharded(dump, staging, workspace, registry, zig, workers, items, now_unix, expansion_workers=None, interwiki_snapshot=None, interwiki_sha=None, auxiliary_snapshots=None, auxiliary_hashes=None, expansion_timeout_ms=None, build_identity=None, page_links_snapshot=None, page_redirects_snapshot=None, raw_shards_path=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical=None, llvm_workers=None, staged_input_root=None, _staged_input_guard=None):
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
    expander_build=workspace/'expander'
    page_links_sha=sha256_file(page_links_snapshot) if page_links_snapshot is not None else None
    page_redirects_sha=sha256_file(page_redirects_snapshot) if page_redirects_snapshot is not None else None
    tools=None
    if not expander_ready(expander_build,auxiliary_hashes,interwiki_sha,page_links_sha,page_redirects_sha):
        if expander_build.exists(): remove_artifact_tree(expander_build)
        staged=read_small_json((staged_input_root if staged_input_root is not None else workspace/'input')/'.complete.json')
        extraction_cache=Path(extraction_cache_root) if extraction_cache_root is not None else workspace/'input'/'extraction-cache'
        tools=prepare_blob_tools(workspace,zig,edition,date,build_identity,
                  expander_args=[str(dump),str(expander_build),
                     *(['--interwiki-map-snapshot',str(interwiki_snapshot)] if interwiki_snapshot else []),
                     *pipeline_snapshot_args(registry,auxiliary_snapshots,page_links_snapshot,page_redirects_snapshot),
                     '--llvm-workers',str(llvm_workers),
                     '--parse-workers',str(min(workers,64)),'--page-workers',str(min(workers,16)),'--expander-only',
                     *extraction_cache_args(extraction_cache,staged)])
    expander=expander_build/'.bundle-expander'
    with build_phase(edition,date,'page_index_count') as result:
        index_path=expander/'page-index.tsv'
        index=inspect_page_index(index_path)
        indexed_pages=index['rows']
        result['pages']=indexed_pages
        result['sha256']=index['sha256']
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

    if tools is None:
        tools=prepare_blob_tools(workspace,zig,edition,date,build_identity)
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
        require_index_identity(index_path,index)
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
        require_index_identity(index_path,index)
        marker=shard/'.verified'
        if not marker.is_file(): marker.write_text('verified\n')
        prefix.append(shard)
    missing_starts=shard_starts[len(prefix):]
    shard_paths=list(prefix)
    continuous_handled=not missing_starts
    # A noncontiguous set of completed shards can arise from older builds.
    # Preserve those outputs and use the existing single-shard fallback.
    if not compress_shards and missing_starts and all(not (shards_root/f'{start:08d}').exists() for start in missing_starts):
        first=missing_starts[0]
        require_index_identity(index_path,index)
        blob_builder.run([str(dump),str(shards_root),
                   '--expander-root',str(expander),'--start-page',str(first),
                   '--limit-pages',str(indexed_pages-first),
                   '--index-byte-offset',str(index['offsets'][first]),
                   '--shard-pages',str(SHARD_PAGES),
                   '--workers',str(expansion_workers),'--now-unix',str(now_unix),*timeout_args,*reviewed_args],
                  edition,date,'continuous_shard_build',start_page=first,pages=indexed_pages-first)
        require_index_identity(index_path,index)
        for start in missing_starts:
            shard=shards_root/f'{start:08d}'
            limit=min(SHARD_PAGES,indexed_pages-start)
            validate_page_coverage(shard,start,limit,index,index['offsets'][start])
            verifier.run([str(shard)],
                      edition,date,'shard_verify',start_page=start,pages=limit)
            (shard/'.verified').write_text('verified\n')
            require_index_identity(index_path,index)
        shard_paths=prefix+[shards_root/f'{start:08d}' for start in missing_starts]
        continuous_handled=True
    if not continuous_handled:
        shard_paths=[]
        for start in range(0,indexed_pages,SHARD_PAGES):
            limit=min(SHARD_PAGES,indexed_pages-start)
            offset=index['offsets'][start]
            require_index_identity(index_path,index)
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
                    require_index_identity(index_path,index)
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
            attempt=build_shard_with_retries(blob_builder,native_args,shard,evidence_root,edition,date,start,limit,
                lambda:require_index_identity(index_path,index),
                lambda:validate_page_coverage(shard,start,limit,index,offset))
            # Preserve a completed shard if verification fails because of
            # a transient tool/resource error. The next run revalidates it.
            verifier.run([str(shard)],
                      edition,date,'shard_verify',start_page=start,pages=limit,attempt=attempt)
            require_index_identity(index_path,index)
            if _staged_input_guard is not None:_staged_input_guard()
            marker.write_text('verified\n')
            if compress_shards:
                with build_phase(edition,date,'shard_compress',start_page=start,pages=limit):
                    compress_verified_shard(shard)
            shard_paths.append(shard)

    require_index_identity(index_path,index)
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
    # The merged staging tree is now the sole verified publication source.
    # Drop raw shards and the transient expander before XZ publication so peak
    # disk usage is not shards + merged raw + compressed output simultaneously.
    cleanup_shard_workspace(workspace)


def build(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, raw_shard_root=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None):
    selected_staged_input_root(items,staged_input_root,output,raw_shard_root,extraction_cache_root)
    validate_llvm_workers(llvm_workers)
    artifact_path(output)
    if raw_shard_root is not None: artifact_path(raw_shard_root)
    validate_now_unix(now_unix)
    timeout_args=expansion_deadline_args(expansion_timeout_ms)
    for item in items:
        validate_item(item)
    edition, date = items[0]['wiki'], items[0]['date']
    with build_phase(edition,date,'edition_build') as result:
        parent = output / edition
        parent.mkdir(parents=True, exist_ok=True)
        # Keep the inode: deleting lock files permits two independent locks.
        with (parent / (date + '.lock')).open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError(f'Build already running: {parent / date}') from None
            # An existing publication is verification-only even when input or
            # publication checks fail before build_locked can return its mode.
            # Legitimate producers share this edition lock; success still overrides.
            if (parent / date / 'complete.json').exists():
                result['execution_mode']='existing_output'
            mode=build_locked(items, downloads, output, zig, compression_workers, expansion_workers, interwiki_snapshot, auxiliary_snapshots, **({'expansion_timeout_ms':expansion_timeout_ms} if expansion_timeout_ms is not None else {}), **({'now_unix':now_unix} if now_unix is not None else {}), **({'raw_shard_root':raw_shard_root} if raw_shard_root is not None else {}), **({'compress_shards':True} if compress_shards else {}), **({'extraction_cache_root':extraction_cache_root} if extraction_cache_root is not None else {}), reviewed_nonlexical_review=reviewed_nonlexical_review, **({'llvm_workers':llvm_workers} if llvm_workers is not None else {}), **({'staged_input_root':staged_input_root} if staged_input_root is not None else {}))
            result['execution_mode']=mode
            return mode


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
        if source_fingerprint()!=build_identity['source']:raise ValueError('Compiler source changed during build; refusing publication')
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

def build_locked(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, raw_shard_root=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None):
    with borrowed_staged_input(items,staged_input_root,output,raw_shard_root,extraction_cache_root) as (borrowed,check):
        return _build_locked(items,downloads,output,zig,compression_workers,expansion_workers,
            interwiki_snapshot,auxiliary_snapshots,expansion_timeout_ms,now_unix,raw_shard_root,
            compress_shards,extraction_cache_root,reviewed_nonlexical_review,llvm_workers,borrowed,check)


def _build_locked(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, raw_shard_root=None, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None, _staged_input_guard=None):
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
        build_identity=build_input_identity(items,zig,None,interwiki_sha,expansion_timeout_ms,auxiliary_snapshots,downloads,reviewed,validate_auxiliary=True)
        auxiliary_hashes=build_identity['auxiliary_snapshot_sha256']
    target = output / edition / date
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
    if staging.exists():
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
    with build_phase(phase_edition,phase_date,'workspace_setup'):
        workspace=target.with_name(date+'.shards')
        expected=shard_state(items,registry,interwiki_snapshot=interwiki_snapshot,auxiliary_snapshots=auxiliary_snapshots,reviewed_nonlexical=reviewed)
        raw_shards_path=(Path(raw_shard_root).absolute()/edition/(date+'.raw-shards')) if raw_shard_root is not None else None
        now_unix=prepare_shard_workspace(workspace,expected,now_unix,**({'raw_shards_path':raw_shards_path} if raw_shards_path is not None else {}))
        if reviewed is not None:nonlexical.pin_review(reviewed,workspace/'reviewed-nonlexical-source.json')
    dump=(staged_input_root/'pages.xml.zst') if staged_input_root is not None else cached_shard_dump(xml,downloads,workspace)
    source_metadata=read_small_json((staged_input_root if staged_input_root is not None else workspace/'input')/'.complete.json')
    if not isinstance(source_metadata,dict) or type(source_metadata.get('source_pages')) is not int or source_metadata['source_pages']<0:
        raise ValueError('Staged dump lacks a verified source page count')
    source_pages=source_metadata['source_pages']
    with build_phase(phase_edition,phase_date,'snapshot_staging'):
        pinned=copy_verified_snapshot(interwiki_snapshot,workspace/'interwiki-map.tsv',interwiki_sha) if interwiki_snapshot else None
        aux_pinned=pinned_auxiliary_snapshots(auxiliary_snapshots,auxiliary_hashes,workspace,
            build_identity.get('auxiliary_capture_sha256',{}),build_identity.get('auxiliary_capture_artifact_sha256',{}))
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
    if source_pages>SHARD_PAGES or reviewed is not None:
        print(f'Sharding {edition}: {source_pages:,} verified source pages in {SHARD_PAGES:,}-page chunks',flush=True)
        build_sharded(dump,staging,workspace,registry,zig,workers,items,now_unix,expansion_workers,pinned,interwiki_sha,aux_pinned,auxiliary_hashes, build_identity=build_identity, **({'page_links_snapshot':page_links_snapshot} if page_links_snapshot is not None else {}), **({'page_redirects_snapshot':page_redirects_snapshot} if page_redirects_snapshot is not None else {}), **({'expansion_timeout_ms':expansion_timeout_ms} if expansion_timeout_ms is not None else {}), **({'raw_shards_path':raw_shards_path} if raw_shards_path is not None else {}), **({'compress_shards':True} if compress_shards else {}), **({'extraction_cache_root':extraction_cache_root} if extraction_cache_root is not None else {}), reviewed_nonlexical=reviewed, **({'llvm_workers':llvm_workers} if llvm_explicit else {}), **({'staged_input_root':staged_input_root} if staged_input_root is not None else {}), **({'_staged_input_guard':_staged_input_guard} if _staged_input_guard is not None else {}))
    else:
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


def build_groups(groups, downloads, output, zig, threads, jobs, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None, expansion_timeout_ms=None, now_unix=None, edition_options=None, admission_wait_seconds=RESOURCE_ADMISSION_WAIT_SECONDS, cpu_admission='load', raw_shard_root=None, adaptive_workers=False, compress_shards=False, extraction_cache_root=None, reviewed_nonlexical_review=None, llvm_workers=None, staged_input_root=None):
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


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--workspace-root-spec',help='Bound workspace directory identity for a retained producer source')
    p.add_argument('--downloads','--in',type=Path,metavar='DIR')
    p.add_argument('--output','--out',type=Path,metavar='DIR')
    p.add_argument('--compress-shards',action='store_true',help='Verify and compress each temporary shard before building the next; merged output remains raw until verified')
    p.add_argument('--staged-input-root',type=Path,metavar='DIR',help='Read-only completed repack input directory for exactly one edition; validates existing marker and bytes, never copies or retires it')
    p.add_argument('--extraction-cache-root',type=Path,metavar='DIR',help='Existing verified native extraction/object cache for one edition; cache identities are checked against fresh build inputs')
    p.add_argument('--raw-shard-root',type=Path,metavar='DIR',help='Optional raw shard volume; input/native caches and merged publication remain under --output')
    p.add_argument('--zig',default=shutil.which('zig') or 'zig')
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
    try: watchdog_memory_limit_bytes(a.watchdog_memory_limit_mib,a.resource_mode)
    except ValueError as error: p.error(str(error))
    configure_artifact_root(json.loads(a.artifact_root_spec) if a.artifact_root_spec is not None else None, a.output, a.raw_shard_root)
    if a.watchdog_address_space!='default' and a.resource_mode!='watchdog':
        p.error('Unlimited address space requires explicit watchdog mode')
    try:
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
    if a.staged_input_root is not None: options['staged_input_root']=a.staged_input_root.absolute()
    if a.extraction_cache_root is not None: options['extraction_cache_root']=a.extraction_cache_root.absolute()
    if a.interwiki_map_snapshot: options['interwiki_snapshot']=a.interwiki_map_snapshot.resolve()
    try: options['edition_options']=resolve_edition_snapshot_options(manifest,groups,a.downloads.resolve(),auxiliary,workspace=workspace)
    except (ValueError,OSError) as error:p.error(str(error))
    if a.interwiki_map_snapshot:
        for value in options['edition_options'].values():value['interwiki_snapshot']=a.interwiki_map_snapshot.resolve()
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
                    if requested_memory is not None and routing.watchdog_address_space=='unlimited':
                        from build_resource_limits import watchdog_physical_memory_limit_bytes
                        if watchdog_physical_memory_limit_bytes()!=requested_memory:
                            raise ContainmentUnavailable('Authenticated watchdog memory budget differs from requested limit')
                    main()
                else:
                    with acquire_build_resource_lock(workspace/'.tmp'/'build-resources.lock'):
                        options={'wall_seconds':routing.build_timeout_seconds if routing.build_timeout_seconds is not None else 7200,
                                 'disk_paths':(workspace/'.tmp', routing.output)}
                        if requested_memory is not None: options['memory_limit_bytes']=requested_memory
                        if routing.watchdog_address_space=='unlimited': options['address_space_limit_bytes']='unlimited'
                        if routing.raw_shard_root is not None: options['disk_paths']+=(routing.raw_shard_root,)
                        if routing.extraction_cache_root is not None: options['disk_paths']+=(routing.extraction_cache_root,)
                        if routing.expansion_workers is not None and routing.expansion_workers>MAX_PIPELINE_WORKERS:
                            options['max_cpus']=8
                        raise SystemExit(supervise_watchdog(**options))
            elif inside_envelope():
                main()
            else:
                with acquire_build_resource_lock(workspace/'.tmp'/'build-resources.lock'):
                    raise SystemExit(supervise())
    except ContainmentUnavailable as error:
        raise SystemExit(str(error)) from error
    except KeyboardInterrupt:
        raise SystemExit('Build interrupted; private build process tree stopped') from None

if __name__=='__main__':cli()
