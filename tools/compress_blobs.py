#!/usr/bin/env python3
"""Publish independently seekable XZ blobs without deleting the raw dictionary."""
import argparse
import concurrent.futures
import hashlib
import lzma
import os
from pathlib import Path
import subprocess
import time

MAX_XZ_WORKERS = 4

def max_workers():
    return max(1, min(MAX_XZ_WORKERS, os.cpu_count() or 1))

def default_workers():
    return max_workers()



def verify_round_trip(path, target):
    with path.open('rb') as source, lzma.open(target,'rb') as decoded:
        if hashlib.file_digest(source,'sha256').digest()!=hashlib.file_digest(decoded,'sha256').digest():
            raise ValueError('Compression round trip failed: '+str(path))

def _validate_raw_blob(path):
    with path.open('rb', buffering=0) as source:
        if source.read(8)!=b'WIKBLB08':
            raise ValueError('Expected WIKBLB08: '+str(path))

def _compress_batch(paths, block_size):
    paths=list(paths)
    if not paths:return
    for path in paths:
        _validate_raw_blob(path)
        target=Path(str(path)+'.xz')
        if target.exists():raise FileExistsError(target)
    started=time.perf_counter()
    subprocess.run(['xz','-9e','--threads=1',f'--block-size={block_size}','--keep',*[str(path) for path in paths]],check=True)
    raw_bytes=0;compressed_bytes=0
    try:
        for path in paths:
            target=Path(str(path)+'.xz')
            verify_round_trip(path,target)
            raw_bytes+=path.stat().st_size;compressed_bytes+=target.stat().st_size
        for path in paths:path.unlink()
    except Exception:
        for path in paths:
            Path(str(path)+'.xz').unlink(missing_ok=True)
        raise
    print(f'batch: {len(paths)} blobs; {raw_bytes} -> {compressed_bytes} bytes; {time.perf_counter()-started:.3f}s; verified',flush=True)

def compress_many(paths, block_size, workers=None, small_limit=8*1024*1024, batch_size=128):
    workers = default_workers() if workers is None else workers
    if workers < 1 or workers > max_workers():raise ValueError(f'Compression workers must be 1 through {max_workers()}')
    paths=[Path(path) for path in paths]
    if not paths:return
    small=[];large=[]
    for path in paths:
        (small if path.stat().st_size <= small_limit else large).append(path)
    if small:
        batches=[small[i:i+batch_size] for i in range(0,len(small),batch_size)]
        concurrency=min(workers,len(batches))
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            list(pool.map(lambda batch:_compress_batch(batch,block_size),batches))
    for path in large:
        compress(path,block_size,workers)
        path.unlink()

def compress(path, block_size, workers=None):
    workers = default_workers() if workers is None else workers
    if workers < 1 or workers > max_workers():
        raise ValueError(f"Compression workers must be 1 through {max_workers()}")
    target=Path(str(path)+'.xz');temp=Path(str(target)+'.part')
    started=time.perf_counter()
    created=False
    try:
        with path.open('rb', buffering=0) as source:
            if source.read(8)!=b'WIKBLB08':raise ValueError('Expected WIKBLB08: '+str(path))
            source.seek(0)
            with temp.open('xb') as out:
                created=True
                subprocess.run(['xz','-9e',f'--threads={workers}',f'--block-size={block_size}','--stdout'],stdin=source,stdout=out,check=True)
                out.flush();os.fsync(out.fileno())
        verify_round_trip(path,temp)
        os.replace(temp,target)
        print(f'{target}: {path.stat().st_size} -> {target.stat().st_size} bytes; {time.perf_counter()-started:.3f}s; verified',flush=True)
    finally:
        if created:temp.unlink(missing_ok=True)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('files',nargs='+',type=Path);p.add_argument('--block-size',type=int,default=1024*1024);p.add_argument('--threads',type=int,default=default_workers(),help='XZ workers (default: 1 + CPU count // 3)');a=p.parse_args()
    if not 64*1024<=a.block_size<=16*1024*1024:p.error('Block size must be 64 KiB through 16 MiB')
    if not 1 <= a.threads <= max_workers():p.error(f'Threads must be 1 through {max_workers()}')
    for file in a.files:compress(file,a.block_size,a.threads)
if __name__=='__main__':main()
