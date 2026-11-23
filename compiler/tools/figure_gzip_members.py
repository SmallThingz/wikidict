"""Use independent gzip members as bounded row locators for Figure JSONL."""
import gzip
import hashlib
import os
from pathlib import Path
import stat
import zlib

BUFFER_BYTES = 64 * 1024


def held_stamp(source):
    value = os.fstat(source.fileno())
    if not stat.S_ISREG(value.st_mode):
        raise ValueError('Figure gzip source is not a regular file')
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns


def read_member(source, limit, physical_end, *, stored_sha=None):
    """Read one complete member without discarding buffered bytes of its successor."""
    if source.tell() == physical_end:
        return b''
    decoder = zlib.decompressobj(wbits=31)
    result = bytearray()
    while not decoder.eof:
        remaining = physical_end - source.tell()
        block = source.peek(1)[:min(BUFFER_BYTES, remaining)] if remaining > 0 else b''
        if not block:
            raise ValueError('Truncated Figure gzip member')
        try:
            result.extend(decoder.decompress(block, limit - len(result) + 1))
        except zlib.error as error:
            raise ValueError('Invalid Figure gzip member') from error
        if len(result) > limit or (decoder.unconsumed_tail and not decoder.eof):
            raise ValueError('Decoded Figure gzip row exceeds its bound')
        consumed = len(block) - len(decoder.unused_data)
        if not consumed or len(source.read(consumed)) != consumed:
            raise ValueError('Figure gzip member changed while reading')
        if stored_sha is not None:
            stored_sha.update(block[:consumed])
    if not result or result.find(b'\n') != len(result) - 1:
        raise ValueError('Figure gzip member must contain exactly one JSONL row')
    return bytes(result)


def read_indexed_row(path, stamp, locator):
    """Read a single locator minted by the completed ordinary replay."""
    path = Path(path)
    offset, stored_size, logical_size, logical_sha = locator
    end = offset + stored_size
    if not 0 <= offset < end <= stamp[2] or logical_size <= 0:
        raise ValueError('Invalid Figure gzip row locator')
    with path.open('rb', buffering=BUFFER_BYTES) as held:
        if held_stamp(held) != stamp:
            raise ValueError('Figure gzip source changed before indexed read')
        held.seek(offset)
        row = read_member(held, logical_size, end)
        if (held.tell() != end or len(row) != logical_size or
                hashlib.sha256(row).hexdigest() != logical_sha or held_stamp(held) != stamp):
            raise ValueError('Figure gzip indexed row differs from verified bytes')
        live = path.lstat()
        if not stat.S_ISREG(live.st_mode) or stamp != (live.st_dev, live.st_ino, live.st_size, live.st_mtime_ns, live.st_ctime_ns):
            raise ValueError('Figure gzip source changed during indexed read')
    return row


class Writer:
    """Emit deterministic standard gzip members and hash the original JSONL bytes."""
    def __init__(self, stream):
        self.stream = stream
        self.sha = hashlib.sha256()
        self.size = 0

    def write(self, row):
        if not row or row.find(b'\n') != len(row) - 1:
            raise ValueError('Figure gzip writer needs one complete JSONL row')
        stored = gzip.compress(row, compresslevel=1, mtime=0)
        if self.stream.write(stored) != len(stored):
            raise ValueError('Short Figure gzip write')
        self.size += len(row)
        self.sha.update(row)

    def identity(self):
        return {'bytes': self.size, 'sha256': self.sha.hexdigest()}
