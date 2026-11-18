#!/usr/bin/env python3
"""Render a source-selected entry from a compiled edition in a disposable terminal."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import time

from verify_reader_ux import DOWN, ENTER, ReaderPty, normalized, require


class NativeCellReaderPty(ReaderPty):
    def snapshot(self, label):
        super().snapshot(label)
        snapshot = self.snapshots[-1]
        path = self.output / Path(snapshot['file']).with_suffix('.cells.json')
        path.write_text(json.dumps(dict(projection='libvterm', columns=self.width,
                                        rows=self.rows, cells=self.screen.cell_rows()),
                                   ensure_ascii=False, indent=2) + '\n')
        snapshot['cells_file'] = path.name


def screen_projection(name):
    if name == 'libvterm':
        import terminal_libvterm
        return terminal_libvterm, NativeCellReaderPty
    import pyte
    return pyte, ReaderPty


def copy_publication(source, destination):
    raw = (source / 'complete.json').read_bytes()
    manifest = json.loads(raw)
    require(manifest['status'] == 'built', 'Entry review requires a built dictionary')
    members = manifest['publication_files']
    require('languages.tsv' in members, 'Missing language catalog')
    destination.mkdir()
    for name, expected in members.items():
        rel = Path(name)
        require(not rel.is_absolute() and rel.parts and '..' not in rel.parts and
                rel.parts[0] not in ('.dict-cache', '.dict-media', '.dict-state', 'complete.json'),
                f'Invalid publication member {name!r}')
        original = source / rel
        require(original.resolve() == original and original.is_file(), f'Invalid file {name!r}')
        target = destination / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, target)
        with target.open('rb') as f:
            require(target.stat().st_size == expected['size'] and
                    hashlib.file_digest(f, 'sha256').hexdigest() == expected['sha256'],
                    f'Publication member differs: {name}')
    (destination / 'complete.json').write_bytes(raw)
    return hashlib.sha256(raw).hexdigest()


def reading_text(reader, first_row=6):
    # In split view the matches column is separate from the wrapped definition.
    lines = reader.screen.display[first_row:-2]
    if reader.width == 90:
        lines = [line.partition('│')[2] for line in lines]
    return normalized(' '.join(' '.join(lines).split()))


def reveal_witness(reader, wanted):
    body = reading_text(reader, 8)
    if wanted in body:
        return
    if '[+]' in body or '[+ notes]' in body:
        frame = reader.send('d')
        reader.wait(reader.entry_focused, 'expanded entry details', after=frame)
    for _ in range(64):
        if wanted in reading_text(reader, 8):
            return
        previous = reader.text()
        frame = reader.send(b'\x1b[6~')
        reader.wait(reader.entry_focused, 'paged through entry', after=frame)
        if reader.text() == previous:
            break
    require(wanted in reading_text(reader, 8), f'Source witness missing from body at {reader.width} columns')


def exercise(reader, language, entry, witness):
    reader.wait(lambda: reader.frames and reader.page_is('search'), 'opened edition')
    reader.action(b'\x15wikidict-no-match-5400b4b7', lambda: reader.query() == 'wikidict-no-match-5400b4b7'
                  and reader.page_is('search', count=0) and 'No matching words.' in reader.text(), 'empty search')
    reader.snapshot('empty')
    reader.action(b'\x15' + entry.encode(), lambda: reader.query() == normalized(entry) and
                  reader.page_is('search') and reader.header()[3] > 0, 'recovered search')
    reader.action(DOWN, lambda: reader.screen.cursor.hidden, 'selected first exact prefix match')
    reader.action(ENTER, lambda: reader.entry_focused() and
                  normalized(f'{entry} / {language}') in reading_text(reader), 'opened requested entry')
    wanted = normalized(' '.join(witness.split()))
    reveal_witness(reader, wanted)
    reader.snapshot('entry-wide')
    frame = reader.resize(45, 24)
    reader.wait(reader.entry_focused, 'entry resized to 45 columns', after=frame)
    reveal_witness(reader, wanted)
    reader.snapshot('entry-narrow')
    reader.action(b'\x1b', lambda: reader.page_is('search') and not reader.entry_focused(), 'back to results')
    reader.finish(b'\x03')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--language', required=True, help='Exact compiled language heading')
    parser.add_argument('--entry', required=True, help='Exact title in that language')
    parser.add_argument('--witness', required=True, help='Visible text expected from the original entry body')
    parser.add_argument('--report', type=Path, required=True, help='Parent directory for captured terminal screens')
    parser.add_argument('--screen-projection', choices=('pyte', 'libvterm'), default='pyte',
                        help='Screen cell engine (libvterm requires the native libvterm.so.0 library)')
    args = parser.parse_args(argv)
    source = args.root.resolve(strict=True)
    binary = args.binary.resolve(strict=True)
    parent = args.report.resolve()
    require(parent != source and source not in parent.parents, 'Reports must be outside the publication')
    require(all(s.strip() for s in (args.language, args.entry, args.witness)), 'Empty selection or witness')
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='edition-pty-', dir=parent))
    result = dict(edition_root=str(source), language=args.language, entry=args.entry, witness=args.witness,
                  passed=False, screens=[], screen_projection=args.screen_projection)
    try:
        projection, reader_type = screen_projection(args.screen_projection)
        with binary.open('rb') as f:
            result['binary_sha256'] = hashlib.file_digest(f, 'sha256').hexdigest()
        with tempfile.TemporaryDirectory(dir=out) as temp:
            root = Path(temp) / 'dictionary'
            result['complete_sha256'] = copy_publication(source, root)
            reader = reader_type(binary, root, 90, 30, out / 'screens', 5, time.monotonic() + 45,
                                 projection, language=args.language)
            try:
                exercise(reader, args.language, args.entry, args.witness)
            finally:
                try:
                    reader.close()
                    result.update(checks=reader.checks, screens=reader.snapshots)
                finally:
                    if args.screen_projection == 'libvterm':
                        reader.screen.close()
        result['passed'] = True
    except Exception as exc:
        result['error'] = str(exc)
    path = out / 'result.json'
    path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(path)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
