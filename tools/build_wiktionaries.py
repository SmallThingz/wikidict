#!/usr/bin/env python3
"""Build every fully downloaded snapshot; publish verified extreme-XZ blobs."""
import argparse
import bz2
import concurrent.futures
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
MAX_TOTAL_BUILD_WORKERS = 8
MEMORY_PER_BUILD_WORKER = 1536 * 1024 * 1024
MEMORY_RESERVE_BYTES = 2 * 1024 * 1024 * 1024
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

def available_memory_bytes():
    try:
        values={}
        for line in Path('/proc/meminfo').read_text().splitlines():
            if ':' not in line:continue
            key,value=line.split(':',1);fields=value.split()
            if fields:values[key]=int(fields[0])*1024
        return values.get('MemAvailable')
    except (OSError,ValueError,IndexError):
        return None

def safe_worker_budget(owned_workers=0):
    cpu=max(1,os.cpu_count() or 1)
    load=load_average()
    if load is None:
        cpu_workers=cpu
    else:
        external_load=max(0.0,load-owned_workers)
        cpu_workers=max(0,int(cpu*CPU_UTILIZATION_TARGET-external_load))
    memory=available_memory_bytes()
    if memory is None:
        return 0
    usable=max(0,memory-MEMORY_RESERVE_BYTES)
    memory_workers=usable//MEMORY_PER_BUILD_WORKER
    from build_resource_limits import CHILD_CGROUP, SUPERVISOR_CHILD_RESERVE, child_memory_limit_bytes
    if CHILD_CGROUP in os.environ:
        try:
            group_limit = child_memory_limit_bytes()
        except (OSError, ValueError):
            return 0
        if group_limit is None:
            return 0
        memory_workers=min(memory_workers,max(0,group_limit-SUPERVISOR_CHILD_RESERVE)//MEMORY_PER_BUILD_WORKER)
    return min(MAX_TOTAL_BUILD_WORKERS,cpu_workers,memory_workers)

def default_build_threads():
    return max(1,min(4,safe_worker_budget()))

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
    target_bytes=4*1024*1024
    max_member_bytes=64*1024*1024  # Strictly below the native reader's 128 MiB cap.
    open_tag=b'<page>'
    close_tag=b'</page>'
    started=time.monotonic()
    pages=members=xml_bytes=0
    dump_hash=hashlib.sha256()
    pending=bytearray()
    batch=bytearray()
    with dump.open('wb',buffering=0) as out, bz2.open(index,'wb',compresslevel=1) as offsets:
        def flush():
            nonlocal members
            if not batch: return
            offsets.write(f'{out.tell()}:{members+1}:member{members}\n'.encode())
            member=bz2.compress(batch,compresslevel=1)
            if out.write(member)!=len(member): raise OSError('Short staged dump write')
            dump_hash.update(member)
            members+=1
            batch.clear()

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
        if members==0:
            offsets.write(b'0:1:member0\n')
            member=bz2.compress(b'',compresslevel=1)
            if out.write(member)!=len(member): raise OSError('Short staged dump write')
            dump_hash.update(member)
            members=1
    if metadata is not None:
        metadata.update({'dump_size':dump.stat().st_size,'dump_sha256':dump_hash.hexdigest(),
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
    count=0
    with path.open('rb') as source:
        for line in source:
            if line.strip() and not line.startswith(b'#'): count+=1
    return count


def shard_state(items, registry, now_unix=None):
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


def build_sharded(dump, staging, workspace, registry, zig, workers, items, now_unix):
    edition,date=items[0]['wiki'],items[0]['date']
    expander_build=workspace/'expander'
    if not expander_ready(expander_build):
        if expander_build.exists(): shutil.rmtree(expander_build)
        timed_run([zig,'build','-Doptimize=ReleaseFast','build-dictionary','--',str(dump),str(expander_build),
                     '--language-registry-snapshot',str(registry),'--llvm-workers',str(workers),
                     '--parse-workers',str(min(workers,64)),'--page-workers',str(min(workers,16)),'--expander-only'],
                  edition,date,'expander_build')
    expander=expander_build/'.bundle-expander'
    with build_phase(edition,date,'page_index_count') as result:
        indexed_pages=count_page_index_rows(expander/'page-index.tsv')
        result['pages']=indexed_pages

    shards_root=workspace/'shards';shards_root.mkdir(exist_ok=True)
    shard_paths=[]
    for start in range(0,indexed_pages,SHARD_PAGES):
        limit=min(SHARD_PAGES,indexed_pages-start)
        shard=shards_root/f'{start:08d}'
        marker=shard/'.verified'
        if marker.is_file():
            try:
                timed_run([zig,'build','-Doptimize=ReleaseFast','verify-blobs','--',str(shard)],
                          edition,date,'resume_shard_verify',start_page=start,pages=limit)
            except subprocess.CalledProcessError:
                print(f'Rebuilding invalid resumed shard {items[0]["wiki"]} start={start}',flush=True)
                shutil.rmtree(shard)
            else:
                shard_paths.append(shard);continue
        last_error=None
        for attempt in range(1,SHARD_RETRIES+1):
            if shard.exists(): shutil.rmtree(shard)
            try:
                timed_run([zig,'build','-Doptimize=ReleaseFast','build-blobs','--',str(dump),str(shard),
                             '--expander-root',str(expander),'--start-page',str(start),'--limit-pages',str(limit),
                             '--workers',str(min(workers,16)),'--now-unix',str(now_unix)],
                          edition,date,'shard_build',start_page=start,pages=limit,attempt=attempt)
                timed_run([zig,'build','-Doptimize=ReleaseFast','verify-blobs','--',str(shard)],
                          edition,date,'shard_verify',start_page=start,pages=limit,attempt=attempt)
            except subprocess.CalledProcessError as error:
                last_error=error
                print(f'Retrying shard {items[0]["wiki"]} start={start} attempt={attempt}/{SHARD_RETRIES}',flush=True)
                continue
            marker.write_text('verified\n')
            last_error=None
            break
        if last_error is not None: raise last_error
        shard_paths.append(shard)

    if staging.exists(): shutil.rmtree(staging)
    timed_run([zig,'build','-Doptimize=ReleaseFast','merge-blobs','--',str(staging),*[str(path) for path in shard_paths]],
              edition,date,'merge',shards=len(shard_paths))
    timed_run([zig,'build','-Doptimize=ReleaseFast','verify-blobs','--',str(staging)],
              edition,date,'merged_verify',shards=len(shard_paths))
    (staging/VERIFIED_MARKER).write_text(VERIFIED_CONTENT)
    # The merged staging tree is now the sole verified publication source.
    # Drop raw shards and the transient expander before XZ publication so peak
    # disk usage is not shards + merged raw + compressed output simultaneously.
    if workspace.exists(): shutil.rmtree(workspace)


def build(items, downloads, output, zig, compression_workers=None):
    for item in items:
        validate_item(item)
    edition, date = items[0]['wiki'], items[0]['date']
    with build_phase(edition,date,'edition_build'):
        parent = output / edition
        parent.mkdir(parents=True, exist_ok=True)
        # Keep the inode: deleting lock files permits two independent locks.
        with (parent / (date + '.lock')).open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError(f'Build already running: {parent / date}') from None
            return build_locked(items, downloads, output, zig, compression_workers)


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
# Bump this when page framing, member encoding or index semantics change; the
# input cache identity and published artifacts both include this contract.
DUMP_STAGING_VERSION = 'page-aligned-bz2-v1'
VERIFIED_CONTENT = f'dump-staging-version={DUMP_STAGING_VERSION}\n'

def require_current_staging_version(path, version):
    if version != DUMP_STAGING_VERSION:
        raise ValueError(f'Outdated dump staging at {path}; rebuild in a new output directory (existing output preserved)')

def _publish_verified_staging(staging, target, edition, date, compression_workers=None):
    marker = staging / VERIFIED_MARKER
    if not marker.is_file():
        raise ValueError(f'Unverified staging directory: {staging}')
    if marker.read_text() != VERIFIED_CONTENT:
        require_current_staging_version(staging, None)
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
        'fallback_report':'fallback-pages.jsonl', 'compression':'xz -6; 1 MiB blocks','blobs':len(compressed)}
    (staging / 'complete.json').write_text(json.dumps(metadata)+'\n')
    os.rename(staging, target)
    print(f'Published: {target}', flush=True)
    return len(compressed),fallback_pages


def publish_verified_staging(staging, target, edition, date, compression_workers=None):
    with build_phase(edition,date,'publish') as result:
        blobs,fallback_pages=_publish_verified_staging(staging,target,edition,date,compression_workers)
        result.update(blobs=blobs,fallback_pages=fallback_pages)

def build_locked(items, downloads, output, zig, compression_workers=None):
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
    target = output / edition / date
    if (target / 'complete.json').exists():
        try:
            metadata=json.loads((target/'complete.json').read_text())
        except (OSError,json.JSONDecodeError):
            metadata={}
        require_current_staging_version(target,metadata.get('dump_staging_version') if isinstance(metadata,dict) else None)
        workspace=target.with_name(date+'.shards')
        if workspace.exists():
            if not workspace.is_dir() or workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
            shutil.rmtree(workspace)
        print(f'Already built: {target}', flush=True)
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.with_name(date + '.building')
    if staging.exists():
        if not staging.is_dir() or staging.is_symlink():
            raise ValueError(f'Unsafe incomplete build path: {staging}')
        if (staging / VERIFIED_MARKER).is_file():
            print(f'Resuming verified publication: {staging}', flush=True)
            publish_verified_staging(staging, target, edition, date, compression_workers)
            return
        print(f'Retrying incomplete build: {staging}', flush=True)
        shutil.rmtree(staging)
    registry = ensure_language_registry(downloads, output, edition, date)
    workers = compression_workers or default_build_threads()
    workspace=target.with_name(date+'.shards')
    compressed_bytes=sum(item['size'] for item in xml)
    if compressed_bytes>=SHARD_THRESHOLD_COMPRESSED_BYTES:
        print(f'Sharding {edition}: {compressed_bytes:,} compressed bytes in {SHARD_PAGES:,}-page chunks',flush=True)
        expected=shard_state(items,registry)
        now_unix=prepare_shard_workspace(workspace,expected)
        dump=cached_shard_dump(xml,downloads,workspace)
        build_sharded(dump,staging,workspace,registry,zig,workers,items,now_unix)
    else:
        (PROJECT / '.tmp').mkdir(exist_ok=True)
        scratch = Path(tempfile.mkdtemp(prefix=f'build-{edition}-{date}-', dir=PROJECT / '.tmp'))
        try:
            dump = stage_seekable_dump(xml,downloads,scratch)
            timed_run([zig,'build','-Doptimize=ReleaseFast','build-dictionary','--',str(dump),str(staging),
                         '--language-registry-snapshot',str(registry),
                         '--llvm-workers',str(workers),'--parse-workers',str(min(workers,64)),
                         '--page-workers',str(min(workers,16))],edition,date,'dictionary_build')
            timed_run([zig,'build','-Doptimize=ReleaseFast','verify-blobs','--',str(staging)],
                      edition,date,'dictionary_verify')
            (staging / VERIFIED_MARKER).write_text(VERIFIED_CONTENT)
        finally:
            shutil.rmtree(scratch)
    publish_verified_staging(staging, target, edition, date, compression_workers)
    if workspace.exists(): shutil.rmtree(workspace)

def build_groups(groups, downloads, output, zig, threads, jobs):
    pending=list(sorted(groups.items()))
    failures=[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        active={}
        while pending or active:
            while pending and len(active)<jobs:
                active_workers=len(active)*threads
                live_budget=safe_worker_budget(active_workers)
                if live_budget < active_workers+threads:
                    break
                key,group=pending.pop(0)
                future=pool.submit(build,group,downloads,output,zig,threads)
                active[future]=key
            if not active:
                if pending:
                    live_budget=safe_worker_budget(0)
                    print(f'STOPPED before {pending[0][0][0]}: resource pressure allows {live_budget} workers, need {threads}',flush=True)
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
    p.add_argument('--threads',type=int,default=default_build_threads(),help='Compiler/expansion workers per edition (default: up to 4 within CPU/RAM budget)')
    p.add_argument('--jobs',type=int,help='Concurrent editions (default: up to two within aggregate CPU/RAM budget)')
    p.add_argument('--wikis',nargs='+',help='Build only these edition IDs')
    a=p.parse_args()
    budget=safe_worker_budget()
    if budget < 1:p.error('Not enough available memory to start a build safely')
    if not 1 <= a.threads <= budget:p.error(f'Threads must be 1 through {budget} on this host')
    if a.jobs is None:a.jobs=min(2,max(1,budget//a.threads))
    if not 1 <= a.jobs <= 16:p.error('Jobs must be 1 through 16')
    if a.jobs*a.threads > budget:p.error(f'jobs × threads must not exceed safe host budget {budget}')
    items=json.loads((a.downloads/'manifest.json').read_text())['files']
    groups={}
    for item in items:
        validate_item(item)
        groups.setdefault((item['wiki'],item['date']),[]).append(item)
    if a.wikis:
        missing=set(a.wikis)-{key[0] for key in groups}
        if missing:p.error(f'Unknown editions: {", ".join(sorted(missing))}')
        groups={key:group for key,group in groups.items() if key[0] in a.wikis}
    print(f'Building {len(groups)} editions with up to {a.jobs} concurrent jobs and {a.threads} workers per edition',flush=True)
    failures=build_groups(groups,a.downloads.resolve(),a.output.resolve(),a.zig,a.threads,a.jobs)
    if failures:raise SystemExit(f'{len(failures)} editions failed or were not started; no incomplete editions were published')
def cli():
    from build_resource_limits import ContainmentUnavailable, inside_envelope, supervise
    try:
        if '-h' in sys.argv[1:] or '--help' in sys.argv[1:]:
            main()
        elif inside_envelope():
            main()
        else:
            with acquire_build_resource_lock(PROJECT/'.tmp'/'build-resources.lock'):
                if safe_worker_budget() < 1:
                    raise SystemExit('Not enough available resources to start a build safely')
                else:
                    memory = available_memory_bytes()
                    if memory is None:
                        raise ContainmentUnavailable('Cannot determine available memory for a contained build')
                    raise SystemExit(supervise(memory))
    except ContainmentUnavailable as error:
        raise SystemExit(str(error)) from error
    except KeyboardInterrupt:
        raise SystemExit('Build interrupted; private build process tree stopped') from None

if __name__=='__main__':cli()
