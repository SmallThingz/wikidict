#!/usr/bin/env python3
"""Build every fully downloaded snapshot; publish verified extreme-XZ blobs."""
import argparse
import bz2
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
        raise ValueError(f'Previous build incomplete: {staging}; inspect/remove it before retrying')
    scratch = PROJECT / '.tmp' / f'build-{edition}-{date}'
    scratch.mkdir(parents=True, exist_ok=False)
    try:
        dump = scratch / 'pages.xml'
        # Extraction accepts sequential page elements across multipart XML streams.
        with dump.open('wb') as out:
            for item in sorted(xml, key=lambda x: x['name']):
                with bz2.open(downloads / edition / date / item['name'], 'rb') as source:
                    shutil.copyfileobj(source, out, 1024*1024)
        subprocess.run([zig,'build','-Doptimize=ReleaseFast','build-dictionary','--',str(dump),str(staging)], cwd=PROJECT, check=True)
        subprocess.run([zig,'build','-Doptimize=ReleaseFast','verify-blobs','--',str(staging)], cwd=PROJECT, check=True)
        blobs = sorted(staging.rglob('*.wikblb'))
        if not blobs:
            raise ValueError('Compiler produced no dictionaries')
        for blob in blobs:
            compress(blob, 1024*1024, compression_workers)
            blob.unlink()
        (staging / 'complete.json').write_text(json.dumps({'edition':edition,'date':date,'compression':'xz -9e; 1 MiB blocks','blobs':len(blobs)})+'\n')
        os.rename(staging, target)
        print(f'Published: {target}', flush=True)
    finally:
        shutil.rmtree(scratch)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--downloads','--in',type=Path,default=PROJECT/'data/dumps',metavar='DIR')
    p.add_argument('--output','--out',type=Path,default=PROJECT/'data/dictionaries',metavar='DIR')
    p.add_argument('--zig',default=shutil.which('zig') or 'zig')
    p.add_argument('--threads',type=int,default=default_workers(),help='XZ workers per blob (default: 1 + CPU count // 3)')
    a=p.parse_args()
    if a.threads < 1:p.error('Compression workers must be positive')
    items=json.loads((a.downloads/'manifest.json').read_text())['files']
    groups={}
    for item in items:
        validate_item(item)
        groups.setdefault((item['wiki'],item['date']),[]).append(item)
    failures=[]
    for key, group in sorted(groups.items()):
        try:build(group,a.downloads.resolve(),a.output.resolve(),a.zig,a.threads)
        except Exception as e:
            failures.append(key);print(f'FAILED {key}: {e}',flush=True)
    if failures:raise SystemExit(f'{len(failures)} editions failed; no incomplete editions were published')
if __name__=='__main__':main()
