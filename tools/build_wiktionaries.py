#!/usr/bin/env python3
"""Build every fully downloaded snapshot; publish verified extreme-XZ blobs."""
import argparse
import bz2
import concurrent.futures
from collections import deque
from contextlib import contextmanager
import fcntl
import hashlib
import tempfile
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import time
from compress_blobs import compress, compress_many, default_workers, verify_round_trip
from download_wiktionaries import digest, language_registry_snapshot, validate_item, write_language_registry

PROJECT = Path(__file__).resolve().parent.parent
SHARD_THRESHOLD_COMPRESSED_BYTES = 512 * 1024 * 1024
SHARD_PAGES = 100_000
SHARD_RETRIES = 3
SHARD_STATE_VERSION = 2
AUXILIARY_SNAPSHOT_NAMES = (
    'commons-data', 'category-stats', 'interface-messages', 'category-tree',
    'wikibase-sitelinks', 'wikibase-entity-text', 'file-metadata',
    'transclusion-redirects',
)
MAX_TOTAL_BUILD_WORKERS = 8
MAX_PIPELINE_WORKERS = 4
MAX_PAGE_EXPANSION_WORKERS = 8
MAX_PAGE_INDEX_LINE_BYTES = 1024 * 1024
MAX_PAGE_COVERAGE_BYTES = 64 * 1024
MEMORY_PER_BUILD_WORKER = 1536 * 1024 * 1024
CPU_UTILIZATION_TARGET = 0.75

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

def safe_worker_budget(owned_workers=0):
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
        temporary.unlink(missing_ok=True)
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


def verified_auxiliary_hashes(snapshots, edition=None, date=None):
    hashes={}
    for name, source in sorted((snapshots or {}).items()):
        if name not in AUXILIARY_SNAPSHOT_NAMES:
            raise ValueError(f'Unknown auxiliary snapshot: {name}')
        path=Path(source).resolve(strict=True)
        if not path.is_file(): raise ValueError(f'Auxiliary snapshot is not a file: {path}')
        sha=sha256_file(path)
        manifest=path.with_name(name+'.manifest.json')
        if manifest.is_file():
            record=read_small_json(manifest)
            if (not isinstance(record,dict) or
                    record.get('output_sha256',record.get('tsv_sha256'))!=sha or
                    ('tsv_sha256' in record and record['tsv_sha256']!=sha) or
                    (edition is not None and record.get('wiki')!=edition) or
                    (date is not None and record.get('date')!=date)):
                raise ValueError(f'Auxiliary snapshot differs from provenance: {path}')
        hashes[name]=sha
    return hashes


def pinned_auxiliary_snapshots(snapshots, hashes, destination):
    return {name:copy_verified_snapshot(Path(source),destination/(name+'.tsv'),hashes[name])
            for name,source in sorted((snapshots or {}).items())}


def auxiliary_snapshot_args(snapshots):
    return [piece for name,path in sorted((snapshots or {}).items())
            for piece in ('--'+name+'-snapshot',str(path))]


def source_fingerprint():
    """Hash build-relevant source so resumed shards never cross code revisions."""
    checksum=hashlib.sha256()
    files=[]
    for name in ('build.zig','build.zig.zon'):
        path=PROJECT/name
        if path.is_file(): files.append(path)
    for folder in ('src','tools'):
        root=PROJECT/folder
        if not root.is_dir(): continue
        files.extend(path for path in root.rglob('*') if path.is_file() and path.suffix in ('.zig','.py','.c','.h','.zon'))
    for path in sorted(files,key=lambda x:x.relative_to(PROJECT).as_posix()):
        checksum.update(path.relative_to(PROJECT).as_posix().encode())
        checksum.update(b'\0')
        with path.open('rb') as source:
            while chunk:=source.read(1024*1024): checksum.update(chunk)
        checksum.update(b'\0')
    return checksum.hexdigest()


@contextmanager
def _remove_partial_stage_on_error(*paths):
    try:
        yield
    except BaseException:
        for path in paths:
            try: path.unlink(missing_ok=True)
            except OSError: pass
        raise


STAGE_TARGET_BYTES=4*1024*1024
STAGE_MAX_MEMBER_BYTES=64*1024*1024
STAGE_PARALLEL_MAX_BYTES=8*1024*1024


def _stage_seekable_dump(items, downloads, scratch, metadata=None):
    """Repack full-namespace dumps into bounded, page-aligned bzip2 members.

    The downloaded meta-current parts are not indexed by page. A whole part can
    expand past the native reader's 128 MiB member limit, so a part boundary is
    not a safe stream boundary. Keep XML only in bounded memory while writing
    compressed members and their real offsets to scratch.
    """
    parts=[]
    for item in sorted(items,key=lambda x:x['name']):
        source=downloads/item['wiki']/item['date']/item['name']
        with source.open('rb',buffering=0) as f:
            if f.read(3)!=b'BZh': raise ValueError(f'Expected bzip2 dump part: {source}')
        parts.append(source)
    if not parts: raise ValueError('No dump parts')
    dump=scratch/'pages.xml.bz2'
    index=dump.with_name(dump.name[:-len('.xml.bz2')]+'-index.txt.bz2')
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

        def write_member(member):
            nonlocal members
            offsets.write(f'{out.tell()}:{members+1}:member{members}\n'.encode())
            if out.write(member)!=len(member): raise OSError('Short staged dump write')
            dump_hash.update(member)
            members+=1

        def finish_oldest():
            write_member(queued.popleft().result())

        def flush():
            if not batch: return
            if len(batch)>max_parallel_bytes:
                while queued: finish_oldest()
                write_member(bz2.compress(batch,compresslevel=1))
                batch.clear()
                return
            if len(queued)==max_queued_batches: finish_oldest()
            raw=bytes(batch)
            batch.clear()
            queued.append(pool.submit(bz2.compress,raw,compresslevel=1))

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
                            raise ValueError(f'XML page exceeds bounded bzip2 member: {source}')
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
            write_member(bz2.compress(b'',compresslevel=1))
    if metadata is not None:
        metadata.update({'source_pages':pages,'dump_size':dump.stat().st_size,'dump_sha256':dump_hash.hexdigest(),
                         'index_size':index.stat().st_size,'index_sha256':sha256_file(index)})
    print(f'Staged compressed dump: pages={pages} members={members} xml_bytes={xml_bytes} compressed_bytes={dump.stat().st_size} seconds={time.monotonic()-started:.1f}',flush=True)
    return dump


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


def shard_state(items, registry, now_unix=None, interwiki_snapshot=None, auxiliary_snapshots=None):
    state={
        'version':SHARD_STATE_VERSION,
        'edition':items[0]['wiki'],
        'date':items[0]['date'],
        'files':[[item['name'],item['size'],item['sha1']] for item in sorted(items,key=lambda x:x['name'])],
        'registry_sha256':sha256_file(registry),
        'source':source_fingerprint(),
        'shard_pages':SHARD_PAGES,
    }
    if now_unix is not None: state['now_unix']=now_unix
    if interwiki_snapshot is not None:
        state['interwiki_map_sha256']=sha256_file(interwiki_snapshot)
    if auxiliary_snapshots:
        state['auxiliary_snapshot_sha256']=verified_auxiliary_hashes(auxiliary_snapshots,items[0]['wiki'],items[0]['date'])
    return state


def dump_input_fingerprint(items):
    """The repack depends on XML input bytes and its staging format only."""
    if not items: raise ValueError('No dump parts')
    files=[]
    for item in sorted(items,key=lambda x:x['name']):
        files.append([item['wiki'],item['date'],item['name'],item['size'],item['sha1']])
    state={'version':DUMP_STAGING_VERSION,'files':files}
    return hashlib.sha256(json.dumps(state,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def prepare_shard_workspace(workspace, expected):
    if workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
    state_path=workspace/'state.json'
    if state_path.is_file():
        try: existing=json.loads(state_path.read_text())
        except (OSError,json.JSONDecodeError): existing=None
        comparable={k:v for k,v in existing.items() if k!='now_unix'} if isinstance(existing,dict) else None
        if comparable==expected and type(existing.get('now_unix')) is int and existing['now_unix']>0:
            return existing['now_unix']
    if workspace.exists():
        if not workspace.is_dir() or workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
        cache=workspace/'input'
        if cache.is_symlink(): raise ValueError(f'Unsafe cached dump path: {cache}')
        # Compiler/registry changes invalidate the expander and shards, but
        # the verified compressed XML repack has independent inputs.
        for child in workspace.iterdir():
            if child.name=='input' and child.is_dir(): continue
            if child.is_dir() and not child.is_symlink(): shutil.rmtree(child)
            else: child.unlink()
    else:
        workspace.mkdir(parents=True)
    now_unix=int(time.time())
    state=dict(expected,now_unix=now_unix)
    temp=state_path.with_suffix('.part')
    temp.write_text(json.dumps(state,sort_keys=True)+'\n')
    os.replace(temp,state_path)
    return now_unix


def cached_shard_dump(items, downloads, workspace):
    """Reuse only a completed, content-verified repack for these XML inputs."""
    edition,date=phase_identity(items)
    cache=workspace/'input'
    dump=cache/'pages.xml.bz2'
    index=cache/'pages-index.txt.bz2'
    marker=cache/'.complete.json'
    with build_phase(edition,date,'cache_verification') as result:
        if cache.is_symlink(): raise ValueError(f'Unsafe cached dump path: {cache}')
        input_hash=dump_input_fingerprint(items)
        if cache.is_dir() and not any(path.is_symlink() for path in (dump,index,marker)):
            try:
                record=json.loads(marker.read_text())
                valid=isinstance(record,dict) and record.get('version')==DUMP_STAGING_VERSION and record.get('input_sha256')==input_hash
                valid=valid and type(record.get('source_pages')) is int and record['source_pages']>=0
                for label,path in (('dump',dump),('index',index)):
                    valid=valid and path.is_file() and type(record.get(label+'_size')) is int and record[label+'_size']>0
                    valid=valid and path.stat().st_size==record[label+'_size']
                    valid=valid and sha256_file(path)==record.get(label+'_sha256')
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
        shutil.rmtree(cache)
    cache.mkdir()
    metadata={}
    stage_seekable_dump(items,downloads,cache,metadata)
    record=dict(metadata,version=DUMP_STAGING_VERSION,input_sha256=input_hash)
    temp=marker.with_suffix('.part')
    temp.write_text(json.dumps(record,sort_keys=True)+'\n')
    os.replace(temp,marker)
    return dump


def expander_ready(root):
    marker=root/'.incomplete'
    expander=root/'.bundle-expander'
    try: ready=marker.read_text()=='expander ready'
    except OSError: return False
    return ready and not (expander/'.incomplete').exists() and (expander/'page-index.tsv').is_file() and (expander/'dict-bundle-expander').is_file()


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


def build_sharded(dump, staging, workspace, registry, zig, workers, items, now_unix, expansion_workers=None, interwiki_snapshot=None, interwiki_sha=None, auxiliary_snapshots=None, auxiliary_hashes=None):
    edition,date=items[0]['wiki'],items[0]['date']
    workers=min(workers,MAX_PIPELINE_WORKERS)
    expansion_workers=workers if expansion_workers is None else expansion_workers
    if type(expansion_workers) is not int or not 1 <= expansion_workers <= MAX_PAGE_EXPANSION_WORKERS:
        raise ValueError('Invalid page expansion worker count')
    expander_build=workspace/'expander'
    if not expander_ready(expander_build):
        if expander_build.exists(): shutil.rmtree(expander_build)
        staged=json.loads((workspace/'input/.complete.json').read_text())
        extraction_cache=workspace/'input'/'extraction-cache'
        timed_run([zig,'build','-j1','-Doptimize=ReleaseFast','build-dictionary','--',str(dump),str(expander_build),
                     '--language-registry-snapshot',str(registry),
                     *(['--interwiki-map-snapshot',str(interwiki_snapshot)] if interwiki_snapshot else []),
                     *auxiliary_snapshot_args(auxiliary_snapshots),
                     '--llvm-workers',str(workers),
                     '--parse-workers',str(min(workers,64)),'--page-workers',str(min(workers,16)),'--expander-only',
                     '--extraction-cache-root',str(extraction_cache),
                     '--verified-dump-sha256',staged['dump_sha256'],
                     '--verified-index-sha256',staged['index_sha256']],
                  edition,date,'expander_build')
    expander=expander_build/'.bundle-expander'
    with build_phase(edition,date,'page_index_count') as result:
        index_path=expander/'page-index.tsv'
        index=inspect_page_index(index_path)
        indexed_pages=index['rows']
        result['pages']=indexed_pages
        result['sha256']=index['sha256']
    cache_record=json.loads((workspace/'input/.complete.json').read_text())
    if type(cache_record.get('source_pages')) is not int or cache_record['source_pages']<0:
        raise ValueError('Staged dump lacks a verified source page count')
    if indexed_pages!=cache_record['source_pages']:
        raise ValueError('Page index count differs from staged source pages')

    shards_root=workspace/'shards';shards_root.mkdir(exist_ok=True)
    shard_paths=[]
    for start in range(0,indexed_pages,SHARD_PAGES):
        limit=min(SHARD_PAGES,indexed_pages-start)
        offset=index['offsets'][start]
        require_index_identity(index_path,index)
        shard=shards_root/f'{start:08d}'
        marker=shard/'.verified'
        if marker.is_file():
            try:
                validate_page_coverage(shard,start,limit,index,offset)
                timed_run([zig,'build','-j1','-Doptimize=ReleaseFast','verify-blobs','--',str(shard)],
                          edition,date,'resume_shard_verify',start_page=start,pages=limit)
            except (subprocess.CalledProcessError,ValueError):
                print(f'Rebuilding invalid resumed shard {items[0]["wiki"]} start={start}',flush=True)
                shutil.rmtree(shard)
            else:
                require_index_identity(index_path,index)
                shard_paths.append(shard);continue
        last_error=None
        for attempt in range(1,SHARD_RETRIES+1):
            if shard.exists(): shutil.rmtree(shard)
            try:
                timed_run([zig,'build','-j1','-Doptimize=ReleaseFast','build-blobs','--',str(dump),str(shard),
                             '--expander-root',str(expander),'--start-page',str(start),'--limit-pages',str(limit),
                             '--index-byte-offset',str(offset),
                             '--workers',str(expansion_workers),'--now-unix',str(now_unix)],
                          edition,date,'shard_build',start_page=start,pages=limit,attempt=attempt)
                require_index_identity(index_path,index)
                validate_page_coverage(shard,start,limit,index,offset)
                timed_run([zig,'build','-j1','-Doptimize=ReleaseFast','verify-blobs','--',str(shard)],
                          edition,date,'shard_verify',start_page=start,pages=limit,attempt=attempt)
            except (subprocess.CalledProcessError,ValueError) as error:
                last_error=error
                print(f'Retrying shard {items[0]["wiki"]} start={start} attempt={attempt}/{SHARD_RETRIES}',flush=True)
                continue
            marker.write_text('verified\n')
            last_error=None
            break
        if last_error is not None: raise last_error
        shard_paths.append(shard)

    require_index_identity(index_path,index)
    actual_pages=sum(validate_page_coverage(path,start,min(SHARD_PAGES,indexed_pages-start),index,index['offsets'][start])['pages_seen']
                     for path,start in zip(shard_paths,range(0,indexed_pages,SHARD_PAGES)))
    if actual_pages!=indexed_pages: raise ValueError('Incomplete total shard page coverage')
    if staging.exists(): shutil.rmtree(staging)
    timed_run([zig,'build','-j1','-Doptimize=ReleaseFast','merge-blobs','--',str(staging),*[str(path) for path in shard_paths]],
              edition,date,'merge',shards=len(shard_paths))
    timed_run([zig,'build','-j1','-Doptimize=ReleaseFast','verify-blobs','--',str(staging)],
              edition,date,'merged_verify',shards=len(shard_paths))
    coverage=dict(version=1,start_page=0,requested_limit=None,index_byte_offset=0,pages_seen=actual_pages,
                  expected_input_pages=indexed_pages,page_index_identity=index['identity'],page_index_sha256=index['sha256'],page_index_rows=indexed_pages)
    (staging/'page-coverage.json').write_text(json.dumps(coverage,sort_keys=True)+'\n')
    plan=expander_build/'compile-plan.tsv'
    if plan.is_file(): shutil.copyfile(plan,staging/'compile-plan.tsv')
    if interwiki_snapshot is not None:
        if sha256_file(interwiki_snapshot)!=interwiki_sha:
            raise ValueError('Interwiki map snapshot changed during build')
        (staging/INTERWIKI_SHA_NAME).write_text(interwiki_sha+'\n')
    if auxiliary_hashes:
        if verified_auxiliary_hashes(auxiliary_snapshots)!=auxiliary_hashes:
            raise ValueError('Auxiliary snapshot changed during build')
        (staging/AUXILIARY_SHA_NAME).write_text(json.dumps(auxiliary_hashes,sort_keys=True)+'\n')
    (staging/VERIFIED_MARKER).write_text(VERIFIED_CONTENT)
    # The merged staging tree is now the sole verified publication source.
    # Drop raw shards and the transient expander before XZ publication so peak
    # disk usage is not shards + merged raw + compressed output simultaneously.
    if workspace.exists(): shutil.rmtree(workspace)


def build(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None):
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
            mode=build_locked(items, downloads, output, zig, compression_workers, expansion_workers, interwiki_snapshot, auxiliary_snapshots)
            result['execution_mode']=mode
            return mode


def validate_fallback_report(path):
    if not path.is_file():
        raise ValueError(f'Missing fallback report: {path}')
    count = 0
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
            key = (namespace, title)
            if key in seen:
                raise ValueError(f'Duplicate fallback page at {path}:{line_number}: {namespace}:{title}')
            seen.add(key)
            count += 1
    return count

VERIFIED_MARKER = '.verified-blobs'
INTERWIKI_SHA_NAME = '.interwiki-map.sha256'
AUXILIARY_SHA_NAME = '.auxiliary-snapshots.sha256.json'
# Bump this when page framing, member encoding or index semantics change; the
# input cache identity and published artifacts both include this contract.
DUMP_STAGING_VERSION = 'page-aligned-bz2-v1'
VERIFIED_CONTENT = f'dump-staging-version={DUMP_STAGING_VERSION}\n'

def require_current_staging_version(path, version):
    if version != DUMP_STAGING_VERSION:
        raise ValueError(f'Outdated dump staging at {path}; rebuild in a new output directory (existing output preserved)')

def _publish_verified_staging(staging, target, edition, date, compression_workers=None, interwiki_sha=None, auxiliary_hashes=None):
    marker = staging / VERIFIED_MARKER
    if not marker.is_file():
        raise ValueError(f'Unverified staging directory: {staging}')
    if marker.read_text() != VERIFIED_CONTENT:
        require_current_staging_version(staging, None)
    recorded=read_snapshot_sha(staging/INTERWIKI_SHA_NAME) if (staging/INTERWIKI_SHA_NAME).is_file() else None
    if recorded!=interwiki_sha:
        raise ValueError('Verified staging uses a different interwiki map snapshot')
    auxiliary_record=read_small_json(staging/AUXILIARY_SHA_NAME) if (staging/AUXILIARY_SHA_NAME).is_file() else {}
    if auxiliary_record!=(auxiliary_hashes or {}):
        raise ValueError('Verified staging uses different auxiliary snapshots')
    coverage=validate_page_coverage(staging,require_total=True)
    fallback_pages = validate_fallback_report(staging / 'fallback-pages.jsonl')
    for part in staging.rglob('*.xz.part'):
        part.unlink()
    raw = sorted(staging.rglob('*.wikblb'))
    compressed = sorted(staging.rglob('*.wikblb.xz'))
    logical = {str(path) for path in raw}
    logical.update(str(path)[:-3] for path in compressed)
    pending = []
    for blob in raw:
        compressed_path = Path(str(blob) + '.xz')
        if compressed_path.exists():
            verify_round_trip(blob, compressed_path)
            blob.unlink()
        else:
            pending.append(blob)
    if pending:
        workers = compression_workers or default_build_threads()
        compress_many(pending, 1024*1024, workers)
    compressed = sorted(staging.rglob('*.wikblb.xz'))
    if len(compressed) != len(logical) or list(staging.rglob('*.wikblb')) or list(staging.rglob('*.xz.part')):
        raise ValueError(f'Incomplete compressed publication: {staging}')
    marker.unlink()
    metadata = {'edition':edition,'date':date,'dump_staging_version':DUMP_STAGING_VERSION,
        'status':'built' if compressed else 'empty', 'fallback_pages':fallback_pages,
        'fallback_report':'fallback-pages.jsonl', 'compression':'xz -6; 1 MiB blocks','blobs':len(compressed),
        'input_pages':coverage['pages_seen'],'page_coverage_report':'page-coverage.json'}
    if interwiki_sha is not None: metadata['interwiki_map_sha256']=interwiki_sha
    if auxiliary_hashes: metadata['auxiliary_snapshot_sha256']=auxiliary_hashes
    (staging / 'complete.json').write_text(json.dumps(metadata)+'\n')
    os.rename(staging, target)
    print(f'Published: {target}', flush=True)
    return len(compressed),fallback_pages


def publish_verified_staging(staging, target, edition, date, compression_workers=None, interwiki_sha=None, auxiliary_hashes=None):
    with build_phase(edition,date,'publish') as result:
        blobs,fallback_pages=_publish_verified_staging(staging,target,edition,date,compression_workers,interwiki_sha,auxiliary_hashes)
        result.update(blobs=blobs,fallback_pages=fallback_pages)

def build_locked(items, downloads, output, zig, compression_workers=None, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None):
    phase_edition,phase_date=phase_identity(items)
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
    if interwiki_snapshot is not None:
        interwiki_snapshot=Path(interwiki_snapshot).resolve(strict=True)
        if not interwiki_snapshot.is_file(): raise ValueError('Interwiki map snapshot is not a file')
        interwiki_sha=sha256_file(interwiki_snapshot)
        validate_interwiki_provenance(interwiki_snapshot,edition,interwiki_sha)
    else:
        interwiki_sha=None
    auxiliary_hashes=verified_auxiliary_hashes(auxiliary_snapshots,edition,date)
    target = output / edition / date
    if (target / 'complete.json').exists():
        try:
            metadata=json.loads((target/'complete.json').read_text())
        except (OSError,json.JSONDecodeError):
            metadata={}
        if not isinstance(metadata,dict): metadata={}
        require_current_staging_version(target,metadata.get('dump_staging_version'))
        if metadata.get('interwiki_map_sha256')!=interwiki_sha:
            raise ValueError('Existing output uses a different interwiki map snapshot; choose a new output directory')
        if metadata.get('auxiliary_snapshot_sha256',{})!=auxiliary_hashes:
            raise ValueError('Existing output uses different auxiliary snapshots; choose a new output directory')
        workspace=target.with_name(date+'.shards')
        if workspace.exists():
            if not workspace.is_dir() or workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
            shutil.rmtree(workspace)
        print(f'Already built: {target}', flush=True)
        return 'existing_output'
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.with_name(date + '.building')
    if staging.exists():
        if not staging.is_dir() or staging.is_symlink():
            raise ValueError(f'Unsafe incomplete build path: {staging}')
        if (staging / VERIFIED_MARKER).is_file():
            print(f'Resuming verified publication: {staging}', flush=True)
            publish_verified_staging(staging, target, edition, date, compression_workers, interwiki_sha, auxiliary_hashes)
            return 'resumed_publication'
        print(f'Retrying incomplete build: {staging}', flush=True)
        shutil.rmtree(staging)
    registry = ensure_language_registry(downloads, output, edition, date)
    workers = min(compression_workers or default_build_threads(),MAX_PIPELINE_WORKERS)
    workspace=target.with_name(date+'.shards')
    compressed_bytes=sum(item['size'] for item in xml)
    if compressed_bytes>=SHARD_THRESHOLD_COMPRESSED_BYTES:
        print(f'Sharding {edition}: {compressed_bytes:,} compressed bytes in {SHARD_PAGES:,}-page chunks',flush=True)
        expected=shard_state(items,registry,interwiki_snapshot=interwiki_snapshot,auxiliary_snapshots=auxiliary_snapshots)
        now_unix=prepare_shard_workspace(workspace,expected)
        dump=cached_shard_dump(xml,downloads,workspace)
        pinned=copy_verified_snapshot(interwiki_snapshot,workspace/'interwiki-map.tsv',interwiki_sha) if interwiki_snapshot else None
        aux_pinned=pinned_auxiliary_snapshots(auxiliary_snapshots,auxiliary_hashes,workspace)
        build_sharded(dump,staging,workspace,registry,zig,workers,items,now_unix,expansion_workers,pinned,interwiki_sha,aux_pinned,auxiliary_hashes)
    else:
        (PROJECT / '.tmp').mkdir(exist_ok=True)
        scratch = Path(tempfile.mkdtemp(prefix=f'build-{edition}-{date}-', dir=PROJECT / '.tmp'))
        try:
            source_metadata={}
            dump = stage_seekable_dump(xml,downloads,scratch,source_metadata)
            pinned=copy_verified_snapshot(interwiki_snapshot,scratch/'interwiki-map.tsv',interwiki_sha) if interwiki_snapshot else None
            aux_pinned=pinned_auxiliary_snapshots(auxiliary_snapshots,auxiliary_hashes,scratch)
            timed_run([zig,'build','-j1','-Doptimize=ReleaseFast','build-dictionary','--',str(dump),str(staging),
                         '--language-registry-snapshot',str(registry),
                         *(['--interwiki-map-snapshot',str(pinned)] if pinned else []),
                         *auxiliary_snapshot_args(aux_pinned),
                         '--llvm-workers',str(workers),'--parse-workers',str(min(workers,64)),
                         '--page-workers',str(min(workers,16))],edition,date,'dictionary_build')
            coverage=validate_page_coverage(staging,source_pages=source_metadata['source_pages'])
            coverage['expected_input_pages']=source_metadata['source_pages']
            (staging/'page-coverage.json').write_text(json.dumps(coverage,sort_keys=True)+'\n')
            timed_run([zig,'build','-j1','-Doptimize=ReleaseFast','verify-blobs','--',str(staging)],
                      edition,date,'dictionary_verify')
            if interwiki_sha is not None:
                if sha256_file(pinned)!=interwiki_sha: raise ValueError('Interwiki map snapshot changed during build')
                (staging/INTERWIKI_SHA_NAME).write_text(interwiki_sha+'\n')
            if auxiliary_hashes:
                if verified_auxiliary_hashes(aux_pinned)!=auxiliary_hashes:
                    raise ValueError('Auxiliary snapshot changed during build')
                (staging/AUXILIARY_SHA_NAME).write_text(json.dumps(auxiliary_hashes,sort_keys=True)+'\n')
            (staging / VERIFIED_MARKER).write_text(VERIFIED_CONTENT)
        finally:
            shutil.rmtree(scratch)
    publish_verified_staging(staging, target, edition, date, compression_workers, interwiki_sha, auxiliary_hashes)
    if workspace.exists(): shutil.rmtree(workspace)
    return 'pipeline_run_may_reuse_verified_inputs_or_shards'

def build_groups(groups, downloads, output, zig, threads, jobs, expansion_workers=None, interwiki_snapshot=None, auxiliary_snapshots=None):
    pending=list(sorted(groups.items()))
    failures=[]
    admission_workers=threads if expansion_workers is None or expansion_workers>MAX_PIPELINE_WORKERS else max(threads,expansion_workers)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        active={}
        while pending or active:
            while pending and len(active)<jobs:
                active_workers=len(active)*admission_workers
                live_budget=safe_worker_budget(active_workers)
                if live_budget < active_workers+admission_workers:
                    break
                key,group=pending.pop(0)
                options={}
                if expansion_workers is not None: options['expansion_workers']=expansion_workers
                if interwiki_snapshot is not None: options['interwiki_snapshot']=interwiki_snapshot
                if auxiliary_snapshots: options['auxiliary_snapshots']=auxiliary_snapshots
                future=pool.submit(build,group,downloads,output,zig,threads,**options)
                active[future]=key
            if not active:
                if pending:
                    live_budget=safe_worker_budget(0)
                    print(f'STOPPED before {pending[0][0][0]}: resource pressure allows {live_budget} workers, need {admission_workers}',flush=True)
                    failures.extend(key for key,_ in pending)
                break
            done,_=concurrent.futures.wait(active,timeout=1,return_when=concurrent.futures.FIRST_COMPLETED)
            if not done:continue
            for future in done:
                key=active.pop(future)
                try:future.result()
                except Exception as e:
                    failures.append(key);print(f'FAILED {key}: {e}',flush=True)
    return failures


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--downloads','--in',type=Path,default=PROJECT/'data/dumps',metavar='DIR')
    p.add_argument('--output','--out',type=Path,default=PROJECT/'data/dictionaries',metavar='DIR')
    p.add_argument('--zig',default=shutil.which('zig') or 'zig')
    p.add_argument('--resource-mode',choices=('cgroup','watchdog'),default='cgroup',
                   help='Resource supervisor: strict cgroup (default), or explicit best-effort 8 GiB process-tree watchdog with a two-hour deadline')
    p.add_argument('--threads',type=int,default=default_build_threads(),help='Workers per edition (up to 4 within CPU load and fixed 8 GiB aggregate cap)')
    p.add_argument('--jobs',type=int,help='Concurrent editions (up to two within CPU load and capped aggregate worker budget)')
    p.add_argument('--expansion-workers',type=int,help='Workers per sharded page expansion; default follows --threads, opt-in 5-8 requires watchdog and one edition job')
    p.add_argument('--wikis',nargs='+',help='Build only these edition IDs')
    p.add_argument('--interwiki-map-snapshot',type=Path,
                   help='Current siteinfo interwiki-map.tsv; its SHA-256 is part of the shard identity')
    for name in AUXILIARY_SNAPSHOT_NAMES:
        p.add_argument('--'+name+'-snapshot',type=Path,
                       help='Optional '+name+' TSV; its SHA-256 is part of the shard identity')
    a=p.parse_args()
    budget=safe_worker_budget()
    if budget < 1:p.error('No worker budget within CPU load and the verified build memory cap (at most 8 GiB)')
    worker_limit=min(budget,MAX_PIPELINE_WORKERS)
    if not 1 <= a.threads <= worker_limit:p.error(f'Threads must be 1 through {worker_limit} on this host')
    expansion_workers=a.threads if a.expansion_workers is None else a.expansion_workers
    if not 1 <= expansion_workers <= MAX_PAGE_EXPANSION_WORKERS:
        p.error(f'Expansion workers must be 1 through {MAX_PAGE_EXPANSION_WORKERS}')
    if expansion_workers>MAX_PIPELINE_WORKERS:
        if a.resource_mode!='watchdog':p.error('More than four expansion workers requires explicit watchdog mode')
        if expansion_workers>len(os.sched_getaffinity(0)):
            p.error('Expansion workers exceed the watchdog CPU affinity')
    admission_workers=a.threads if expansion_workers>MAX_PIPELINE_WORKERS else max(a.threads,expansion_workers)
    if a.jobs is None:a.jobs=1 if expansion_workers>MAX_PIPELINE_WORKERS else min(2,max(1,budget//admission_workers))
    if expansion_workers>MAX_PIPELINE_WORKERS and a.jobs!=1:
        p.error('More than four expansion workers requires exactly one edition job')
    if not 1 <= a.jobs <= 16:p.error('Jobs must be 1 through 16')
    if a.jobs*admission_workers > budget:p.error(f'jobs × workers must not exceed safe host budget {budget}')
    items=json.loads((a.downloads/'manifest.json').read_text())['files']
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
    print(f'Building {len(groups)} editions with up to {a.jobs} concurrent jobs and {a.threads} workers per edition',flush=True)
    options={}
    if a.interwiki_map_snapshot: options['interwiki_snapshot']=a.interwiki_map_snapshot.resolve()
    if auxiliary: options['auxiliary_snapshots']=auxiliary
    failures=build_groups(groups,a.downloads.resolve(),a.output.resolve(),a.zig,a.threads,a.jobs,
                          None if a.expansion_workers is None else expansion_workers,**options)
    if failures:raise SystemExit(f'{len(failures)} editions failed or were not started; no incomplete editions were published')
def cli():
    from build_resource_limits import ContainmentUnavailable, inside_envelope, inside_watchdog, supervise, supervise_watchdog
    try:
        route=argparse.ArgumentParser(add_help=False)
        route.add_argument('--resource-mode',choices=('cgroup','watchdog'),default='cgroup')
        route.add_argument('--expansion-workers',type=int)
        routing=route.parse_known_args()[0]
        mode=routing.resource_mode
        if '-h' in sys.argv[1:] or '--help' in sys.argv[1:]:
            main()
        else:
            watchdog_child=inside_watchdog()
            if watchdog_child and mode!='watchdog':
                raise ContainmentUnavailable('Watchdog child requires explicit --resource-mode=watchdog')
            if mode=='watchdog':
                if watchdog_child:
                    main()
                else:
                    with acquire_build_resource_lock(PROJECT/'.tmp'/'build-resources.lock'):
                        options={'wall_seconds':7200}
                        if routing.expansion_workers is not None and routing.expansion_workers>MAX_PIPELINE_WORKERS:
                            options['max_cpus']=8
                        raise SystemExit(supervise_watchdog(**options))
            elif inside_envelope():
                main()
            else:
                with acquire_build_resource_lock(PROJECT/'.tmp'/'build-resources.lock'):
                    raise SystemExit(supervise())
    except ContainmentUnavailable as error:
        raise SystemExit(str(error)) from error
    except KeyboardInterrupt:
        raise SystemExit('Build interrupted; private build process tree stopped') from None

if __name__=='__main__':cli()
