#!/usr/bin/env python3
"""Build every fully downloaded snapshot; publish verified extreme-XZ blobs."""
import argparse
import bz2
import concurrent.futures
import fcntl
import hashlib
import tempfile
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import time
from compress_blobs import compress, compress_many, default_workers, verify_round_trip
from download_wiktionaries import digest, language_registry_snapshot, validate_item, write_language_registry

PROJECT = Path(__file__).resolve().parent.parent
SHARD_THRESHOLD_PAGES = 2_000_000
SHARD_PAGES = 100_000
SHARD_RETRIES = 3
SHARD_STATE_VERSION = 1

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


def copy_xml_with_page_count(items, downloads, dump):
    needle=b'<page>'
    tail=b''
    pages=0
    with dump.open('wb') as out:
        for item in sorted(items, key=lambda x:x['name']):
            with bz2.open(downloads/item['wiki']/item['date']/item['name'],'rb') as source:
                while True:
                    chunk=source.read(1024*1024)
                    if not chunk: break
                    combined=tail+chunk
                    pages+=combined.count(needle)
                    tail=combined[-(len(needle)-1):]
                    out.write(chunk)
    return pages


def count_lines(path):
    count=0
    with path.open('rb') as source:
        while chunk:=source.read(8*1024*1024): count+=chunk.count(b'\n')
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


def prepare_shard_workspace(workspace, expected):
    state_path=workspace/'state.json'
    if state_path.is_file():
        try: existing=json.loads(state_path.read_text())
        except (OSError,json.JSONDecodeError): existing=None
        comparable={k:v for k,v in existing.items() if k!='now_unix'} if isinstance(existing,dict) else None
        if comparable==expected and type(existing.get('now_unix')) is int and existing['now_unix']>0:
            return existing['now_unix']
    if workspace.exists():
        if not workspace.is_dir() or workspace.is_symlink(): raise ValueError(f'Unsafe shard workspace: {workspace}')
        shutil.rmtree(workspace)
    workspace.mkdir(parents=True)
    now_unix=int(time.time())
    state=dict(expected,now_unix=now_unix)
    temp=state_path.with_suffix('.part')
    temp.write_text(json.dumps(state,sort_keys=True)+'\n')
    os.replace(temp,state_path)
    return now_unix


def expander_ready(root):
    marker=root/'.incomplete'
    expander=root/'.bundle-expander'
    try: ready=marker.read_text()=='expander ready'
    except OSError: return False
    return ready and not (expander/'.incomplete').exists() and (expander/'page-index.tsv').is_file() and (expander/'dict-bundle-expander').is_file()


def run_checked(command):
    subprocess.run(command,cwd=PROJECT,check=True)


def build_sharded(dump, staging, workspace, registry, zig, workers, expected_pages, items):
    expected=shard_state(items,registry)
    now_unix=prepare_shard_workspace(workspace,expected)
    expander_build=workspace/'expander'
    if not expander_ready(expander_build):
        if expander_build.exists(): shutil.rmtree(expander_build)
        run_checked([zig,'build','-Doptimize=ReleaseFast','build-dictionary','--',str(dump),str(expander_build),
                     '--language-registry-snapshot',str(registry),'--llvm-workers',str(workers),
                     '--parse-workers',str(min(workers,64)),'--page-workers',str(min(workers,16)),'--expander-only'])
    expander=expander_build/'.bundle-expander'
    indexed_pages=count_lines(expander/'page-index.tsv')
    if indexed_pages!=expected_pages:
        raise ValueError(f'Page count mismatch for {items[0]["wiki"]}: XML={expected_pages}, index={indexed_pages}')

    shards_root=workspace/'shards';shards_root.mkdir(exist_ok=True)
    shard_paths=[]
    for start in range(0,indexed_pages,SHARD_PAGES):
        limit=min(SHARD_PAGES,indexed_pages-start)
        shard=shards_root/f'{start:08d}'
        marker=shard/'.verified'
        if marker.is_file():
            try:
                run_checked([zig,'build','-Doptimize=ReleaseFast','verify-blobs','--',str(shard)])
            except subprocess.CalledProcessError:
                print(f'Rebuilding invalid resumed shard {items[0]["wiki"]} start={start}',flush=True)
                shutil.rmtree(shard)
            else:
                shard_paths.append(shard);continue
        last_error=None
        for attempt in range(1,SHARD_RETRIES+1):
            if shard.exists(): shutil.rmtree(shard)
            try:
                run_checked([zig,'build','-Doptimize=ReleaseFast','build-blobs','--',str(dump),str(shard),
                             '--expander-root',str(expander),'--start-page',str(start),'--limit-pages',str(limit),
                             '--workers',str(min(workers,16)),'--now-unix',str(now_unix)])
                run_checked([zig,'build','-Doptimize=ReleaseFast','verify-blobs','--',str(shard)])
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
    run_checked([zig,'build','-Doptimize=ReleaseFast','merge-blobs','--',str(staging),*[str(path) for path in shard_paths]])
    run_checked([zig,'build','-Doptimize=ReleaseFast','verify-blobs','--',str(staging)])
    (staging/VERIFIED_MARKER).write_text('verified\n')


def build(items, downloads, output, zig, compression_workers=None):
    for item in items:
        validate_item(item)
    edition, date = items[0]['wiki'], items[0]['date']
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

def publish_verified_staging(staging, target, edition, date, compression_workers=None):
    marker = staging / VERIFIED_MARKER
    if not marker.is_file():
        raise ValueError(f'Unverified staging directory: {staging}')
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
        workers = compression_workers or default_workers()
        compress_many(pending, 1024*1024, workers)
    compressed = sorted(staging.rglob('*.wikblb.xz'))
    if len(compressed) != len(logical) or list(staging.rglob('*.wikblb')) or list(staging.rglob('*.xz.part')):
        raise ValueError(f'Incomplete compressed publication: {staging}')
    marker.unlink()
    metadata = {'edition':edition,'date':date,
        'status':'built' if compressed else 'empty', 'fallback_pages':fallback_pages,
        'fallback_report':'fallback-pages.jsonl', 'compression':'xz -9e; 1 MiB blocks','blobs':len(compressed)}
    (staging / 'complete.json').write_text(json.dumps(metadata)+'\n')
    os.rename(staging, target)
    print(f'Published: {target}', flush=True)

def build_locked(items, downloads, output, zig, compression_workers=None):
    for item in items:
        validate_item(item)
        source = downloads / item['wiki'] / item['date'] / item['name']
        if not source.is_file() or source.stat().st_size != item['size'] or digest(source) != item['sha1']:
            raise ValueError(f'Missing or unverified download: {source}')
    xml = [x for x in items if '-pages-meta-current' in x['name'] and re.search(r'\.xml(?:-p[0-9]+p[0-9]+)?\.bz2$', x['name'])]
    if not xml:
        raise ValueError('No full-namespace current XML in snapshot')
    edition, date = items[0]['wiki'], items[0]['date']
    target = output / edition / date
    if (target / 'complete.json').exists():
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
    (PROJECT / '.tmp').mkdir(exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix=f'build-{edition}-{date}-', dir=PROJECT / '.tmp'))
    try:
        registry = ensure_language_registry(downloads, output, edition, date)
        dump = scratch / 'pages.xml'
        # XML text cannot contain a raw <page> element token, so the streaming
        # count is also a cheap corruption/split-boundary check for sharding.
        page_count=copy_xml_with_page_count(xml,downloads,dump)
        workers = compression_workers or default_workers()
        workspace=target.with_name(date+'.shards')
        if page_count>=SHARD_THRESHOLD_PAGES:
            print(f'Sharding {edition}: {page_count:,} pages in chunks of {SHARD_PAGES:,}',flush=True)
            build_sharded(dump,staging,workspace,registry,zig,workers,page_count,items)
        else:
            run_checked([zig,'build','-Doptimize=ReleaseFast','build-dictionary','--',str(dump),str(staging),
                         '--language-registry-snapshot',str(registry),
                         '--llvm-workers',str(workers),'--parse-workers',str(min(workers,64)),
                         '--page-workers',str(min(workers,16))])
            run_checked([zig,'build','-Doptimize=ReleaseFast','verify-blobs','--',str(staging)])
            (staging / VERIFIED_MARKER).write_text('verified\n')
        publish_verified_staging(staging, target, edition, date, compression_workers)
        if workspace.exists(): shutil.rmtree(workspace)
    finally:
        shutil.rmtree(scratch)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--downloads','--in',type=Path,default=PROJECT/'data/dumps',metavar='DIR')
    p.add_argument('--output','--out',type=Path,default=PROJECT/'data/dictionaries',metavar='DIR')
    p.add_argument('--zig',default=shutil.which('zig') or 'zig')
    p.add_argument('--threads',type=int,default=default_workers(),help='Compiler, expansion and XZ workers per edition (default: 1 + CPU count // 3)')
    p.add_argument('--jobs',type=int,help='Concurrent editions (default: up to four, based on CPU count / threads)')
    p.add_argument('--wikis',nargs='+',help='Build only these edition IDs')
    a=p.parse_args()
    if a.threads < 1:p.error('Threads must be positive')
    if a.jobs is None:a.jobs=min(4,max(1,((os.cpu_count() or 1)+a.threads-1)//a.threads))
    if not 1 <= a.jobs <= 16:p.error('Jobs must be 1 through 16')
    items=json.loads((a.downloads/'manifest.json').read_text())['files']
    groups={}
    for item in items:
        validate_item(item)
        groups.setdefault((item['wiki'],item['date']),[]).append(item)
    if a.wikis:
        missing=set(a.wikis)-{key[0] for key in groups}
        if missing:p.error(f'Unknown editions: {", ".join(sorted(missing))}')
        groups={key:group for key,group in groups.items() if key[0] in a.wikis}
    failures=[]
    print(f'Building {len(groups)} editions with {a.jobs} concurrent jobs and {a.threads} workers per edition',flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        futures={pool.submit(build,group,a.downloads.resolve(),a.output.resolve(),a.zig,a.threads):key
                 for key,group in sorted(groups.items())}
        for future in concurrent.futures.as_completed(futures):
            key=futures[future]
            try:future.result()
            except Exception as e:
                failures.append(key);print(f'FAILED {key}: {e}',flush=True)
    if failures:raise SystemExit(f'{len(failures)} editions failed; no incomplete editions were published')
if __name__=='__main__':main()
