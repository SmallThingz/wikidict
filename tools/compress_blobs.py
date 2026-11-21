#!/usr/bin/env python3
"""Publish independently seekable XZ blobs without deleting the raw dictionary."""
import argparse
import concurrent.futures
import threading
import lzma
import os
from pathlib import Path
import subprocess
import stat
import time

MAX_XZ_WORKERS = 4
SHARD_BATCH_FILES = 128
SHARD_BATCH_BYTES = 8 * 1024 * 1024

def max_workers():
    return max(1, min(MAX_XZ_WORKERS, os.cpu_count() or 1))

def default_workers():
    return max_workers()



def verify_round_trip(path, target):
    with path.open('rb') as source, lzma.open(target, 'rb') as decoded:
        while True:
            expected = source.read(256 * 1024)
            if decoded.read(256 * 1024) != expected:
                raise ValueError('Compression round trip failed: ' + str(path))
            if not expected:
                return

def _validate_raw_blob(path):
    with path.open('rb', buffering=0) as source:
        if source.read(8)!=b'WIKBLB08':
            raise ValueError('Expected WIKBLB08: '+str(path))

def compress_small_batch_keep(paths, block_size):
    """Publish a bounded small-file batch, retaining every raw recovery copy."""
    paths = [Path(path) for path in paths]
    if not 1 <= len(paths) <= SHARD_BATCH_FILES or len(set(paths)) != len(paths):
        raise ValueError('Small compression batch must have 1 through 128 unique files')
    total_bytes = 0
    for path in paths:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('Expected regular blob: ' + str(path))
        total_bytes += info.st_size
    if total_bytes > SHARD_BATCH_BYTES:
        raise ValueError('Compression batch exceeds its byte budget')
    started = time.perf_counter()
    _encode_verified_batch(paths, block_size)
    print(f'small batch: {len(paths)} blobs; {time.perf_counter()-started:.3f}s; verified; raw retained', flush=True)


def _encode_verified_batch(paths, block_size):
    """Only give a stream its final name after all batch members round-trip."""
    parts = [Path(str(path) + '.xz.part') for path in paths]
    targets = [Path(str(path) + '.xz') for path in paths]
    for path, part, target in zip(paths, parts, targets):
        _validate_raw_blob(path)
        if part.exists() or part.is_symlink(): raise FileExistsError(part)
        if target.exists() or target.is_symlink(): raise FileExistsError(target)
    try:
        subprocess.run(['xz', '-0', '--threads=1', f'--block-size={block_size}',
                        '--keep', '--suffix=.xz.part', '--', *map(str, paths)], check=True)
        for path, part in zip(paths, parts):
            fd = os.open(part, os.O_RDONLY | os.O_NOFOLLOW)
            try: os.fsync(fd)
            finally: os.close(fd)
            verify_round_trip(path, part)
        for part, target in zip(parts, targets): os.replace(part, target)
    finally:
        for part in parts: part.unlink(missing_ok=True)


def _compress_batch(paths, block_size):
    paths=list(paths)
    if not paths:return
    started=time.perf_counter()
    _encode_verified_batch(paths, block_size)
    raw_bytes = sum(path.stat().st_size for path in paths)
    compressed_bytes = sum(Path(str(path) + '.xz').stat().st_size for path in paths)
    for directory in {path.parent for path in paths}:
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)
    # Verified outputs are now the recovery copies; raw cleanup must not roll them back.
    for path in paths:path.unlink()
    print(f'batch: {len(paths)} blobs; {raw_bytes} -> {compressed_bytes} bytes; {time.perf_counter()-started:.3f}s; verified',flush=True)

def _compress_large_wave(paths, block_size):
    """Encode at most three files with two XZ processes, then commit as a wave."""
    paths = list(paths)
    if not paths or len(paths) > 3:
        raise ValueError('Large compression wave must have one through three files')
    for path in paths:
        _validate_raw_blob(path)
        target = Path(str(path) + '.xz')
        part = Path(str(target) + '.part')
        if target.exists(): raise FileExistsError(target)
        if part.exists(): raise FileExistsError(part)

    raw_sizes = [path.stat().st_size for path in paths]
    next_index = 0
    guard = threading.Lock()
    failed = threading.Event()
    errors = []
    durations = [None] * len(paths)

    def encode_worker():
        nonlocal next_index
        while not failed.is_set():
            with guard:
                if failed.is_set() or next_index >= len(paths): return
                index = next_index
                next_index += 1
            path = paths[index]
            part = Path(str(path) + '.xz.part')
            started = time.perf_counter()
            try:
                with path.open('rb', buffering=0) as source, part.open('xb') as out:
                    subprocess.run(['xz', '-0', '--threads=2',
                                    f'--block-size={block_size}',
                                    '--memlimit-compress=2147483648', '--no-adjust', '--stdout'],
                                   stdin=source, stdout=out, check=True)
                    out.flush()
                    os.fsync(out.fileno())
                durations[index] = time.perf_counter() - started
            except Exception as error:
                with guard:
                    errors.append(error)
                    failed.set()
                return

    started = time.perf_counter()
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)
    try:
        futures = [pool.submit(encode_worker) for _ in range(min(2, len(paths)))]
        for future in futures: future.result()
        if errors: raise errors[0]
        if any(duration is None for duration in durations):
            raise RuntimeError('Large compression wave stopped early')
        # Only one Python LZMA decoder is active at a time. No raw input is
        # removed until every output in this wave passes the round trip.
        for path in paths:
            verify_round_trip(path, Path(str(path) + '.xz.part'))
        for path in paths:
            os.replace(Path(str(path) + '.xz.part'), Path(str(path) + '.xz'))
        for path in paths:
            path.unlink()
        for path, raw_size, duration in zip(paths, raw_sizes, durations):
            target = Path(str(path) + '.xz')
            print(f'{target}: {raw_size} -> {target.stat().st_size} bytes; encode={duration:.3f}s; verified', flush=True)
        print(f'large wave: {len(paths)} blobs; {time.perf_counter()-started:.3f}s; verified', flush=True)
    finally:
        failed.set()
        pool.shutdown(wait=True, cancel_futures=True)
        for path in paths:
            Path(str(path) + '.xz.part').unlink(missing_ok=True)

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
    if workers >= 4 and len(large) >= 2:
        # The two workers pull from each three-file wave as they become free.
        # A wave holds at most three temporary outputs on disk.
        for start in range(0, len(large), 3):
            wave = large[start:start+3]
            if len(wave) == 1:
                compress(wave[0], block_size, workers)
                wave[0].unlink()
            else:
                _compress_large_wave(wave, block_size)
    else:
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
                subprocess.run(['xz','-0',f'--threads={workers}',f'--block-size={block_size}','--stdout'],stdin=source,stdout=out,check=True)
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
