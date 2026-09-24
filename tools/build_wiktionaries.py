#!/usr/bin/env python3
"""Build every fully downloaded snapshot; publish verified extreme-XZ blobs."""
import argparse
import bz2
import concurrent.futures
import fcntl
import tempfile
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
from compress_blobs import compress, default_workers
from download_wiktionaries import digest, validate_item

PROJECT = Path(__file__).resolve().parent.parent

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
        print(f'Already built: {target}', flush=True)
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.with_name(date + '.building')
    if staging.exists():
        if not staging.is_dir() or staging.is_symlink():
            raise ValueError(f'Unsafe incomplete build path: {staging}')
        print(f'Retrying incomplete build: {staging}', flush=True)
        shutil.rmtree(staging)
    (PROJECT / '.tmp').mkdir(exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix=f'build-{edition}-{date}-', dir=PROJECT / '.tmp'))
    try:
        dump = scratch / 'pages.xml'
        # Extraction accepts sequential page elements across multipart XML streams.
        with dump.open('wb') as out:
            for item in sorted(xml, key=lambda x: x['name']):
                with bz2.open(downloads / edition / date / item['name'], 'rb') as source:
                    shutil.copyfileobj(source, out, 1024*1024)
        workers = compression_workers or default_workers()
        subprocess.run([zig,'build','-Doptimize=ReleaseFast','build-dictionary','--',str(dump),str(staging),
                        '--llvm-workers',str(workers),'--parse-workers',str(min(workers,64)),
                        '--page-workers',str(min(workers,16))], cwd=PROJECT, check=True)
        subprocess.run([zig,'build','-Doptimize=ReleaseFast','verify-blobs','--',str(staging)], cwd=PROJECT, check=True)
        report = staging / 'fallback-pages.jsonl'
        fallback_pages = validate_fallback_report(report)
        blobs = sorted(staging.rglob('*.wikblb'))
        for blob in blobs:
            compress(blob, 1024*1024, compression_workers)
            blob.unlink()
        (staging / 'complete.json').write_text(json.dumps({'edition':edition,'date':date,
            'status':'built' if blobs else 'empty', 'fallback_pages':fallback_pages,
            'fallback_report':'fallback-pages.jsonl', 'compression':'xz -9e; 1 MiB blocks','blobs':len(blobs)})+'\n')
        os.rename(staging, target)
        print(f'Published: {target}', flush=True)
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
