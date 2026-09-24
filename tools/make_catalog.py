#!/usr/bin/env python3
"""Write an Android-compatible release catalogue from verified WIKBLB08 files."""
import argparse
import hashlib
import lzma
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import quote, urlsplit

MAX_CATALOG_BYTES = 2 * 1024 * 1024
MAX_CATALOG_ENTRIES = 10_000


@contextmanager
def logical_blob(path):
    if path.name.endswith('.wikblb.xz'):
        with lzma.open(path, 'rb') as source:
            yield source
    elif path.name.endswith('.wikblb'):
        with path.open('rb') as source:
            yield source
    else:
        raise ValueError(f'not a .wikblb or .wikblb.xz dictionary: {path}')


def blob_label(path):
    try:
        with logical_blob(path) as source:
            if source.read(8) != b'WIKBLB08':
                raise ValueError(f'not a WIKBLB08 dictionary: {path}')
            kind = source.read(1)
            if kind not in [bytes([i]) for i in range(1, 7)]:
                raise ValueError(f'invalid blob kind: {path}')

            def nul():
                out = bytearray()
                while len(out) < 65536:
                    byte = source.read(1)
                    if not byte:
                        raise ValueError(f'truncated header: {path}')
                    if byte == b'\0':
                        try:
                            return out.decode('utf-8')
                        except UnicodeDecodeError:
                            raise ValueError(f'invalid UTF-8 header: {path}') from None
                    out.extend(byte)
                raise ValueError(f'header is too long: {path}')

            if kind == b'\x01':
                code = nul()
                if not code:
                    raise ValueError(f'unverified language code: {path}')
                label = nul()
            else:
                label = {2:'Thesaurus',3:'Citations',4:'Reconstructions',5:'Rhymes',6:'Sign glosses'}[kind[0]]
    except lzma.LZMAError as error:
        raise ValueError(f'invalid XZ dictionary: {path}: {error}') from None

    if not label or any(char in label for char in '\t\r\n'):
        raise ValueError(f'invalid language label: {path}')
    return label


def catalogue(files, base_url):
    parsed = urlsplit(base_url)
    if parsed.scheme != 'https' or not parsed.netloc or parsed.username or parsed.query or parsed.fragment:
        raise ValueError('base URL must be a plain HTTPS directory URL')

    paths = sorted(Path(path) for path in files)
    if not paths:
        raise ValueError('no dictionaries found')
    if len(paths) > MAX_CATALOG_ENTRIES:
        raise ValueError(f'catalogue has more than {MAX_CATALOG_ENTRIES} dictionaries')

    rows = ['# wikidict-list-v1: URL<TAB>label<TAB>bytes<TAB>sha256']
    names = set()
    for path in paths:
        if path.name in names:
            raise ValueError(f'duplicate release asset name: {path.name}')
        names.add(path.name)
        label = blob_label(path)
        with path.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        rows.append(f'{base_url.rstrip("/")}/{quote(path.name)}\t{label}\t{path.stat().st_size}\t{digest}')
        if len(('\n'.join(rows) + '\n').encode('utf-8')) > MAX_CATALOG_BYTES:
            raise ValueError(f'catalogue exceeds {MAX_CATALOG_BYTES} bytes')

    return '\n'.join(rows) + '\n'


def catalogue_files(root):
    compressed = sorted(root.rglob('*.wikblb.xz'))
    compressed_raw = {Path(str(path)[:-3]) for path in compressed}
    raw = [path for path in sorted(root.rglob('*.wikblb')) if path not in compressed_raw]
    return raw + compressed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--base-url', required=True, help='HTTPS release/download/TAG directory')
    parser.add_argument('--output', type=Path, default=Path('dictionaries.list'))
    args = parser.parse_args()
    args.output.write_text(catalogue(catalogue_files(args.root), args.base_url), encoding='utf-8')


if __name__ == '__main__':
    main()
