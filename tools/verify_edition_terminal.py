#!/usr/bin/env python3
"""Render a source-selected entry from a compiled edition in a disposable terminal."""

import argparse
import csv
import gzip
import hashlib
import itertools
import json
import os
from pathlib import Path
import shutil
import tempfile
import time

from verify_reader_ux import DOWN, ENTER, ReaderPty, normalized, require


class NativeCellReaderPty(ReaderPty):
    def snapshot(self, label):
        super().snapshot(label)
        snapshot = self.snapshots[-1]
        path = self.output / Path(snapshot['file']).with_suffix('.cells.json.gz')
        grid = dict(projection='libvterm', columns=self.width, rows=self.rows, cells=self.screen.cell_rows())
        payload = json.dumps(grid, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        path.write_bytes(gzip.compress(payload, compresslevel=1, mtime=0))
        snapshot['cells_file'] = path.name


def screen_projection(name):
    if name == 'libvterm':
        import terminal_libvterm
        return terminal_libvterm, NativeCellReaderPty
    import pyte
    return pyte, ReaderPty


def copy_publication(source, destination, expected_digest=None):
    raw = (source / 'complete.json').read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    require(expected_digest is None or digest == expected_digest, 'Selected edition manifest has changed')
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
    return digest


def reading_text(reader):
    # In split view the matches column is separate from the wrapped definition.
    lines = reader.screen.display[6:-2]
    if reader.width == 90:
        lines = [line.partition('│')[2] for line in lines]
    return normalized(' '.join(' '.join(lines).split()))


def reading_body(reader, heading):
    text = reading_text(reader)
    if text == heading:
        return ''
    # The title scrolls with the entry. After paging, even the first visible line can be definition text.
    return text.removeprefix(heading + ' ')


def source_witness_visible(reader, wanted, heading):
    if wanted in reading_body(reader, heading):
        return True
    if not hasattr(reader.screen, 'cell_rows'):
        return False

    # Prose can wrap beside a floated table. Compare consecutive lines in the
    # same physical column without interleaving cells from the table or sidebar.
    start = min(36, reader.width // 3) if reader.width >= 80 else 0
    rows = reader.screen.cell_rows()[6:-2]

    def table_edges(row):
        return tuple(i for i in range(start, len(row)) if row[i]['text'] == '│')

    for edges, lines in itertools.groupby(rows, key=table_edges):
        if len(edges) < 2:
            continue
        prose = [''.join(cell['text'] for cell in row[start:edges[0]]) for row in lines]
        text = normalized(' '.join(' '.join(prose).split()))
        if text != heading and wanted in text.removeprefix(heading + ' '):
            return True
    return False


def reveal_witness(reader, wanted, heading):
    body = reading_body(reader, heading)
    if source_witness_visible(reader, wanted, heading):
        return
    if '[+]' in body or '[+ notes]' in body:
        frame = reader.send('d')
        reader.wait(reader.entry_focused, 'expanded entry details', after=frame)
    for _ in range(64):
        if source_witness_visible(reader, wanted, heading):
            return
        previous = reader.text()
        frame = reader.send(b'\x1b[6~')
        reader.wait(reader.entry_focused, 'paged through entry', after=frame)
        if reader.text() == previous:
            break
    require(source_witness_visible(reader, wanted, heading), f'Source witness missing from body at {reader.width} columns')


def exercise(reader, heading_label, entry, witness):
    reader.action(b'\x15wikidict-no-match-5400b4b7', lambda: reader.query() == 'wikidict-no-match-5400b4b7'
                  and reader.page_is('search', count=0) and 'No matching words.' in reader.text(), 'empty search')
    require(reader.text().count('No matching words.') == 1, 'Empty search repeats the same message')
    total = reader.header()[1]
    expected_count = f'{total} {"word" if total == 1 else "words"}'
    require(reader.screen.display[1].split('/')[1].strip() == expected_count,
            f'Incorrect word count label for {total} records')
    reader.snapshot('empty')
    reader.action(b'\x15' + entry.encode(), lambda: reader.query() == normalized(entry) and
                  reader.page_is('search') and reader.header()[3] > 0, 'recovered search')
    reader.action(DOWN, lambda: reader.screen.cursor.hidden, 'selected first exact prefix match')
    heading = normalized(' '.join(f'{entry} / {heading_label}'.split()))
    reader.action(ENTER, lambda: reader.entry_focused() and
                  (reading_text(reader) + ' ').startswith(heading + ' '), 'opened requested entry')
    wanted = normalized(' '.join(witness.split()))
    reveal_witness(reader, wanted, heading)
    reader.snapshot('entry-wide')
    frame = reader.resize(45, 24)
    reader.wait(reader.entry_focused, 'entry resized to 45 columns', after=frame)
    reveal_witness(reader, wanted, heading)
    reader.snapshot('entry-narrow')
    reader.action(b'\x1b', lambda: reader.page_is('search') and not reader.entry_focused(), 'back to results')
    reader.finish(b'\x03')


def binary_identity(stat):
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns


def run_case(binary, stamp, binary_digest, source, language, entry, witness, expected_digest, parent, engine, kind):
    out = Path(tempfile.mkdtemp(prefix='edition-pty-', dir=parent))
    result = dict(edition_root=str(source), language=language, kind=kind, entry=entry, witness=witness,
                  passed=False, screens=[], screen_projection=engine, binary_sha256=binary_digest)
    try:
        projection, reader_type = screen_projection(engine)
        with tempfile.TemporaryDirectory(dir=out) as temp:
            root = Path(temp) / 'dictionary'
            result['complete_sha256'] = copy_publication(source, root, expected_digest)
            require(binary_identity(binary.stat()) == stamp, 'Reader executable changed before launch')
            started = time.monotonic()
            reader = reader_type(binary, root, 90, 30, out / 'screens', 45, started + 45,
                                 projection, language=language, kind=kind)
            try:
                # A cold compressed edition may still be indexing after the ordinary key-response deadline.
                try:
                    reader.wait(lambda: reader.frames and reader.page_is('search'), 'opened edition')
                finally:
                    result['opening_wait_seconds'] = time.monotonic() - started
                reader.timeout = 5
                exercise(reader, language or kind, entry, witness)
            except Exception:
                try:
                    reader.snapshot('failure-before-close')
                except Exception as exc:
                    result['failure_snapshot_error'] = str(exc)
                raise
            finally:
                try:
                    reader.close()
                    result.update(checks=reader.checks, screens=reader.snapshots)
                finally:
                    if engine == 'libvterm':
                        reader.screen.close()
        require(binary_identity(binary.stat()) == stamp, 'Reader executable changed during review')
        result['passed'] = True
    except Exception as exc:
        result['error'] = str(exc)
    path = out / 'result.json'
    path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(path, flush=True)
    return path, result['passed']


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--root', type=Path)
    selection.add_argument('--cases', type=Path, help='TSV of source-selected entries for serial review')
    parser.add_argument('--kind', choices=('language', 'supplemental'), help='Record collection (default: language)')
    parser.add_argument('--language', help='Exact compiled language heading')
    parser.add_argument('--entry', help='Exact title in the selected collection')
    parser.add_argument('--witness', help='Visible text expected from the original entry body')
    parser.add_argument('--report', type=Path, required=True, help='Parent directory for captured terminal screens')
    parser.add_argument('--screen-projection', choices=('pyte', 'libvterm'), default='pyte',
                        help='Screen cell engine (libvterm requires the native libvterm.so.0 library)')
    args = parser.parse_args(argv)
    if args.cases:
        if any((args.kind, args.language, args.entry, args.witness)):
            parser.error('--cases supplies the language, entry and witness for each row')
        with args.cases.open(encoding='utf-8', newline='') as data:
            rows = csv.DictReader(data, delimiter='\t')
            columns = ('output_directory', 'owner_heading', 'exact_title', 'visible_definition_witness', 'selected_complete_sha256')
            if not set(columns).issubset(rows.fieldnames or []):
                parser.error('TSV requires columns ' + ', '.join(columns))
            cases = [(row['output_directory'], row['owner_heading'] or None, row['exact_title'],
                      row['visible_definition_witness'], row['selected_complete_sha256'], row.get('kind') or 'language')
                     for row in rows]
    else:
        cases = [(str(args.root), args.language, args.entry, args.witness, None, args.kind or 'language')]
    parent = args.report.resolve()
    if not cases:
        parser.error('No entries selected')
    for root, language, entry, witness, digest, kind in cases:
        if not all(s and s.strip() for s in (root, entry, witness)):
            parser.error('Each entry needs a dictionary directory, title and witness')
        if kind not in ('language', 'supplemental'):
            parser.error(f'Unsupported collection: {kind!r}')
        if kind == 'language' and not (language and language.strip()):
            parser.error('A language entry requires its exact owner heading')
        if kind == 'supplemental' and language is not None:
            parser.error('Leave the owner heading empty for a supplemental entry')
        if args.cases and (not digest or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest)):
            parser.error('Each TSV row needs the SHA-256 digest of the selected complete.json')
        source = Path(root).resolve()
        require(parent != source and source not in parent.parents, 'Reports must be outside the publication')
    parent.mkdir(parents=True, exist_ok=True)
    binary = args.binary.resolve(strict=True)
    with binary.open('rb') as f:
        stamp = binary_identity(os.fstat(f.fileno()))
        binary_digest = hashlib.file_digest(f, 'sha256').hexdigest()
        require(binary_identity(os.fstat(f.fileno())) == stamp, 'Reader executable changed during hashing')
    if args.cases:
        parent = Path(tempfile.mkdtemp(prefix='edition-batch-', dir=parent))
    failures = 0
    for root, language, entry, witness, digest, kind in cases:
        path, passed = run_case(binary, stamp, binary_digest, Path(root).resolve(), language, entry, witness,
                                digest, parent, args.screen_projection, kind)
        if args.cases:
            with (parent / 'results.jsonl').open('a', encoding='utf-8') as ledger:
                ledger.write(json.dumps(dict(root=root, language=language, kind=kind, entry=entry, passed=passed, report=str(path)),
                                        ensure_ascii=False) + '\n')
        failures += not passed
    return int(failures != 0)


if __name__ == '__main__':
    raise SystemExit(main())
