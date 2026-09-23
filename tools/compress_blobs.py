#!/usr/bin/env python3
"""Publish independently seekable XZ blobs without deleting the raw dictionary."""
import argparse
import hashlib
import lzma
import os
from pathlib import Path
import subprocess
import time

def default_workers():
    return 1 + (os.cpu_count() or 1) // 3

def compress(path, block_size, workers=None):
    workers = default_workers() if workers is None else workers
    if workers < 1:
        raise ValueError("Compression workers must be positive")
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
        with path.open('rb') as source, lzma.open(temp,'rb') as decoded:
            if hashlib.file_digest(source,'sha256').digest()!=hashlib.file_digest(decoded,'sha256').digest():raise ValueError('Compression round trip failed')
        os.replace(temp,target)
        print(f'{target}: {path.stat().st_size} -> {target.stat().st_size} bytes; {time.perf_counter()-started:.3f}s; verified',flush=True)
    finally:
        if created:temp.unlink(missing_ok=True)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('files',nargs='+',type=Path);p.add_argument('--block-size',type=int,default=1024*1024);p.add_argument('--threads',type=int,default=default_workers(),help='XZ workers (default: 1 + CPU count // 3)');a=p.parse_args()
    if not 64*1024<=a.block_size<=16*1024*1024:p.error('Block size must be 64 KiB through 16 MiB')
    if a.threads < 1:p.error('Threads must be positive')
    for file in a.files:compress(file,a.block_size,a.threads)
if __name__=='__main__':main()
