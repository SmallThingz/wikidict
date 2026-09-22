#!/usr/bin/env python3
"""Write an Android-compatible release catalogue from verified raw WIKBLB08 files."""
import argparse
import hashlib
from pathlib import Path
from urllib.parse import quote, urlsplit


def catalogue(files, base_url):
    parsed = urlsplit(base_url)
    if parsed.scheme != 'https' or not parsed.netloc or parsed.username or parsed.query or parsed.fragment:
        raise ValueError('base URL must be a plain HTTPS directory URL')
    rows = ['# wikidict-list-v1: URL<TAB>label<TAB>bytes<TAB>sha256']
    names = set()
    for path in sorted(files):
        if path.name in names:
            raise ValueError(f'duplicate release asset name: {path.name}')
        names.add(path.name)
        with path.open('rb') as source:
            if source.read(8) != b'WIKBLB08':
                raise ValueError(f'not an uncompressed WIKBLB08 dictionary: {path}')
            kind = source.read(1)
            if kind not in [bytes([i]) for i in range(1, 7)]:
                raise ValueError(f'invalid blob kind: {path}')
            def nul():
                out = bytearray()
                while len(out) < 65536:
                    b = source.read(1)
                    if not b:
                        raise ValueError(f'truncated header: {path}')
                    if b == b'\0':
                        return out.decode('utf-8')
                    out.extend(b)
                raise ValueError('header is too long')
            if kind == b'\x01':
                nul()
                label = nul()
            else:
                label = {2:'Thesaurus',3:'Citations',4:'Reconstructions',5:'Rhymes',6:'Sign glosses'}[kind[0]]
            if not label or any(c in label for c in '\t\r\n'):
                raise ValueError(f'invalid language label: {path}')
            source.seek(0)
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        rows.append(f'{base_url.rstrip("/")}/{quote(path.name)}\t{label}\t{path.stat().st_size}\t{digest}')
    if len(rows) == 1:
        raise ValueError('no dictionaries found')
    return '\n'.join(rows) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--base-url', required=True, help='HTTPS release/download/TAG directory')
    parser.add_argument('--output', type=Path, default=Path('dictionaries.list'))
    args = parser.parse_args()
    args.output.write_text(catalogue(args.root.rglob('*.wikblb'), args.base_url), encoding='utf-8')


if __name__ == '__main__':
    main()
