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
import re
import shutil
import tempfile
import time

from verify_reader_ux import DOWN, ENTER, ReaderPty, normalized, require


class NativeCellReaderPty(ReaderPty):
    projection_name = 'libvterm'

    def snapshot(self, label):
        super().snapshot(label)
        snapshot = self.snapshots[-1]
        path = self.output / Path(snapshot['file']).with_suffix('.cells.json.gz')
        grid = dict(projection=self.projection_name, columns=self.width, rows=self.rows, cells=self.screen.cell_rows())
        payload = json.dumps(grid, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        path.write_bytes(gzip.compress(payload, compresslevel=1, mtime=0))
        snapshot['cells_file'] = path.name


def screen_projection(name):
    if name == 'kitty':
        import terminal_kitty
        return terminal_kitty, NativeCellReaderPty
    if name == 'libvterm':
        import terminal_libvterm
        return terminal_libvterm, NativeCellReaderPty
    import pyte
    return pyte, ReaderPty


def copy_publication(source, destination, expected_digest=None, *, expected_status='built'):
    raw = (source / 'complete.json').read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    require(expected_digest is None or digest == expected_digest, 'Selected edition manifest has changed')
    manifest = json.loads(raw)
    require(expected_status in ('built', 'empty') and manifest['status'] == expected_status,
            f'Expected dictionary manifest status {expected_status!r}')
    members = manifest['publication_files']
    require(isinstance(members, dict) and all(isinstance(value, dict) for value in members.values()),
            'Expected size and digest for every publication member')
    copy_members(source, destination, members)
    (destination / 'complete.json').write_bytes(raw)
    return digest


def copy_members(source, destination, members):
    require('languages.tsv' in members, 'Missing language catalog')
    destination.mkdir()
    copied = {}
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
            size = os.fstat(f.fileno()).st_size
            digest = hashlib.file_digest(f, 'sha256').hexdigest()
        if expected is not None:
            require(size == expected['size'] and digest == expected['sha256'], f'Publication member differs: {name}')
        else:
            copied[name] = dict(size=size, sha256=digest)
    return copied


def copy_indexed_page(case, destination):
    """Open one ordinary indexed Writer result in an isolated writable Reader directory."""
    source = case / 'data'
    receipt = case / 'ordinary-output-result.json'
    coverage = source / 'page-coverage.json'
    for path in (receipt, coverage):
        require(path.resolve(strict=True) == path and path.is_file(), f'Invalid indexed page input: {path}')
    raw = receipt.read_bytes()
    coverage_raw = coverage.read_bytes()
    page, seen = json.loads(raw), json.loads(coverage_raw)
    require(page.get('schema') == 'wikidict.ordinary-indexed-output.v1' and page.get('name') == case.name and
            page.get('complete') is True and page.get('error_name') is None and
            isinstance(page.get('index_row_sha256'), str) and re.fullmatch('[0-9a-f]{64}', page['index_row_sha256']),
            'Expected a completed ordinary indexed page')
    for key, field in (('ordinal', 'start_page'), ('index_byte_offset', 'index_byte_offset')):
        require(type(page.get(key)) is int and page[key] >= 0 and type(seen.get(field)) is int and
                seen[field] == page[key], 'Page coverage differs from the indexed selection')
    require(all(type(seen.get(key)) is int and seen[key] == 1 for key in ('version', 'requested_limit', 'pages_seen')),
            'Expected coverage for exactly one page')
    # The ordinary Writer emits raw blobs. Leave caches, settings, media downloads
    # and build diagnostics in place. Report exactly which Reader inputs we used.
    def snapshot():
        paths = [source / 'languages.tsv', *sorted(source.glob('*.wikblb')), *sorted((source / 'languages').glob('*.wikblb'))]
        return {str(p.relative_to(source)): binary_identity(p.lstat()) for p in paths}
    before = snapshot()
    require(len(before) > 1, 'Indexed page has no Reader blobs')
    members = copy_members(source, destination, dict.fromkeys(before))
    require(snapshot() == before and receipt.read_bytes() == raw and coverage.read_bytes() == coverage_raw,
            'Indexed page changed while staging')
    return dict(ordinal=page['ordinal'], index_byte_offset=page['index_byte_offset'], index_row_sha256=page['index_row_sha256'],
                receipt_sha256=hashlib.sha256(raw).hexdigest(), coverage_sha256=hashlib.sha256(coverage_raw).hexdigest(),
                reader_files=members)


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


def wrapped_table_cell_contains(rows, left, right, wanted):
    """Match adjacent lines inside one bordered column when the next word had to wrap."""
    previous = ''
    spare = 0
    for row in rows:
        cells = row[left + 1:right]
        if len(cells) < 3 or cells[0]['text'] != ' ' or cells[-1]['text'] != ' ':
            previous = ''
            continue
        content = cells[1:-1]
        line = normalized(' '.join(''.join(c['text'] for c in content).split()))
        if not line:
            previous = ''
            continue
        # The one-cell padding is outside the available text width. A new
        # indented line, or a word that fit on the previous row, is no wrap proof.
        word = itertools.takewhile(lambda c: not c['text'].isspace(), content)
        word_width = sum(c.get('width', 1) for c in word)
        if previous and word_width and 1 + word_width > spare:
            previous += ' ' + line
            if wanted in previous:
                return True
        else:
            previous = line
        spare = sum(1 for _ in itertools.takewhile(lambda c: c['text'] == ' ', reversed(content)))
    return False


def source_witness_visible(reader, wanted, heading):
    if wanted in reading_body(reader, heading):
        return True
    if not hasattr(reader.screen, 'cell_rows'):
        return False

    # Prose can wrap beside a floated table. Compare consecutive lines in the
    # same physical column without interleaving cells from the table or sidebar.
    start = min(36, reader.width // 3) if reader.width >= 80 else 0
    rows = reader.screen.cell_rows()[6:-2]

    # A full line may split a word (including an unspaced CJK sentence).
    # Use cell coordinates: a wide glyph can leave one unused column.
    # The native Reader reserves two cells at the right of its reading pane.
    left, right = start + 2, reader.width - 2
    fragments = []
    previous_end = 0
    for row in rows:
        content = row[left:right]
        text = normalized(' '.join(''.join(cell['text'] for cell in content).split()))
        if not text or text == heading or '│' in text:
            previous_end = 0
            fragments.append(' ')
            continue
        if previous_end + content[0].get('width', 1) <= right or not content[0]['text'].strip():
            fragments.append(' ')
        fragments.append(text)
        previous_end = max((left + i + cell.get('width', 1) for i, cell in enumerate(content)
                            if cell['text'].strip()), default=0)
    if wanted in ''.join(fragments):
        return True

    def table_edges(row):
        return tuple(i for i in range(start, len(row)) if row[i]['text'] == '│')

    for edges, lines in itertools.groupby(rows, key=table_edges):
        if len(edges) < 2:
            continue
        lines = list(lines)
        prose = [''.join(cell['text'] for cell in row[start:edges[0]]) for row in lines]
        text = normalized(' '.join(' '.join(prose).split()))
        if text != heading and wanted in text.removeprefix(heading + ' '):
            return True
        if any(wrapped_table_cell_contains(lines, left_edge, right_edge, wanted)
               for left_edge, right_edge in itertools.pairwise(edges)):
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


def exercise(reader, heading_label, entry, witness, redirect_target=None):
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
    heading = normalized(' '.join(f'{redirect_target or entry} / {heading_label}'.split()))
    reader.action(ENTER, lambda: reader.entry_focused() and
                  (reading_text(reader) + ' ').startswith(heading + ' '), 'opened requested entry')
    wanted = normalized(' '.join(witness.split()))
    reveal_witness(reader, wanted, heading)
    reader.snapshot('entry-wide')
    frame = reader.resize(45, 24)
    reader.wait(reader.entry_focused, 'entry resized to 45 columns', after=frame)
    # Reflow preserves the current scroll offset. Start the narrow review at
    # the title when the definition is outside the resized viewport.
    if not source_witness_visible(reader, wanted, heading):
        reader.action(b'\x1b[H', lambda: reader.entry_focused() and
                      (reading_text(reader) + ' ').startswith(heading + ' '), 'Home returns to the entry title')
    reveal_witness(reader, wanted, heading)
    reader.snapshot('entry-narrow')
    reader.action(b'\x1b', lambda: reader.page_is('search') and not reader.entry_focused(), 'back to results')
    reader.finish(b'\x03')


def binary_identity(stat):
    return stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns


def library_selection_keys(display, headings, target):
    index = headings.index(target)
    if len(display) < 12 or 'Home/End' not in display[-2]:
        return DOWN * index + ENTER

    # Read the actual page size from the first rendered catalog page. Older
    # or truncated layouts can still use the two advertised endpoints.
    visible = [normalized(line.strip()) for line in display[5:-4] if line.strip()]
    page = len(visible) if 'PgUp/' in display[-2] and visible == [normalized(h) for h in headings[:len(visible)]] else 0

    def route(distance, anchor, page_key, arrow):
        pages, singles = divmod(distance, page) if page > 1 else (0, distance)
        return pages + singles + 1, anchor + page_key * pages + arrow * singles

    forward = route(index, b'\x1b[H', b'\x1b[6~', DOWN)
    backward = route(len(headings) - 1 - index, b'\x1b[F', b'\x1b[5~', b'\x1b[A')
    return min(forward, backward, key=lambda path: path[0])[1] + ENTER


def choose_startup_language(reader, root, language):
    header, *headings = (root / 'languages.tsv').read_text(encoding='utf-8').splitlines()
    require(header == 'heading' and language in headings, 'Selected language is missing from the catalog')

    def library_visible():
        return reader.screen.display[1].strip() == 'Library' and 'Installed dictionaries' in reader.text()

    def selected(heading):
        label = normalized(reader.screen.display[0][12:].rstrip())
        return reader.page_is('search') and label == normalized(heading + ' / language')

    initial = 'English' if 'English' in headings else headings[0] if len(headings) == 1 else None
    if initial is not None:
        reader.wait(lambda: selected(initial), 'opened default collection')
        if initial == language:
            return
        reader.action(b'\tL', library_visible, 'opened installed language chooser')
    else:
        reader.wait(library_visible, 'offered installed languages at startup')
    reader.snapshot('language-chooser')
    keys = library_selection_keys(reader.screen.display, headings, language)
    reader.action(keys, lambda: selected(language), 'opened chosen language')


def run_case(binary, stamp, binary_digest, source, language, entry, witness, expected_digest, parent, engine, kind, implicit=False,
             indexed_page=False, redirect_target=None):
    out = Path(tempfile.mkdtemp(prefix='edition-pty-', dir=parent))
    result = dict(edition_root=str(source), language=language, kind=kind, entry=entry, witness=witness,
                  passed=False, screens=[], screen_projection=engine, binary_sha256=binary_digest, implicit_language=implicit)
    try:
        if redirect_target is not None:
            result['redirect_target'] = redirect_target
        projection, reader_type = screen_projection(engine)
        with tempfile.TemporaryDirectory(dir=out) as temp:
            root = Path(temp) / 'dictionary'
            if indexed_page:
                result['indexed_page'] = copy_indexed_page(source, root)
            else:
                result['complete_sha256'] = copy_publication(source, root, expected_digest)
            require(binary_identity(binary.stat()) == stamp, 'Reader executable changed before launch')
            started = time.monotonic()
            reader = reader_type(binary, root, 90, 30, out / 'screens', 45, started + 45,
                                 projection, language=None if implicit else language, kind=kind)
            reader.projection_name = engine
            try:
                # A cold compressed edition may still be indexing after the ordinary key-response deadline.
                try:
                    if implicit:
                        choose_startup_language(reader, root, language)
                    else:
                        reader.wait(lambda: reader.frames and reader.page_is('search'), 'opened edition')
                finally:
                    result['opening_wait_seconds'] = time.monotonic() - started
                reader.timeout = 5
                exercise(reader, language or kind, entry, witness, redirect_target)
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
                    if engine in ('kitty', 'libvterm'):
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
    selection.add_argument('--indexed-page', type=Path, help='Test one ordinary Writer case directory containing ordinary-output-result.json and data/.')
    selection.add_argument('--cases', type=Path, help='TSV of source-selected entries for serial review')
    parser.add_argument('--kind', choices=('language', 'supplemental'), help='Record collection (default: language)')
    parser.add_argument('--language', help='Exact compiled language heading')
    parser.add_argument('--entry', help='Exact title in the selected collection')
    parser.add_argument('--redirect-target', help='Expected title after opening the selected redirect')
    parser.add_argument('--witness', help='Visible text expected from the original entry body')
    parser.add_argument('--implicit-language', action='store_true', help='Launch without a language override and use the keyboard chooser when needed')
    parser.add_argument('--report', type=Path, required=True, help='Parent directory for captured terminal screens')
    parser.add_argument('--screen-projection', choices=('pyte', 'libvterm', 'kitty'), default='pyte',
                        help='Screen cell engine (libvterm and kitty require their respective native libraries)')
    args = parser.parse_args(argv)
    if args.cases:
        if any((args.kind, args.language, args.entry, args.witness, args.redirect_target)):
            parser.error('--cases supplies the language, entry and witness for each row')
        with args.cases.open(encoding='utf-8', newline='') as data:
            rows = csv.DictReader(data, delimiter='\t')
            columns = ('output_directory', 'owner_heading', 'exact_title', 'visible_definition_witness', 'selected_complete_sha256')
            if not set(columns).issubset(rows.fieldnames or []):
                parser.error('TSV requires columns ' + ', '.join(columns))
            cases = [(row['output_directory'], row['owner_heading'] or None, row['exact_title'],
                      row['visible_definition_witness'], row['selected_complete_sha256'], row.get('kind') or 'language',
                      row.get('redirect_target') or None)
                     for row in rows]
    else:
        cases = [(str(args.indexed_page or args.root), args.language, args.entry, args.witness, None, args.kind or 'language', args.redirect_target)]
    parent = args.report.resolve()
    if not cases:
        parser.error('No entries selected')
    for root, language, entry, witness, digest, kind, redirect_target in cases:
        if not all(s and s.strip() for s in (root, entry, witness)):
            parser.error('Each entry needs a dictionary directory, title and witness')
        if redirect_target is not None and not redirect_target.strip():
            parser.error('A redirect needs its exact destination title')
        if kind not in ('language', 'supplemental'):
            parser.error(f'Unsupported collection: {kind!r}')
        if kind == 'language' and not (language and language.strip()):
            parser.error('A language entry requires its exact owner heading')
        if kind == 'supplemental' and language is not None:
            parser.error('Leave the owner heading empty for a supplemental entry')
        if args.implicit_language and kind != 'language':
            parser.error('--implicit-language exercises language collections only')
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
    for root, language, entry, witness, digest, kind, redirect_target in cases:
        path, passed = run_case(binary, stamp, binary_digest, Path(root).resolve(), language, entry, witness,
                                digest, parent, args.screen_projection, kind, args.implicit_language,
                                indexed_page=args.indexed_page is not None, redirect_target=redirect_target)
        if args.cases:
            with (parent / 'results.jsonl').open('a', encoding='utf-8') as ledger:
                ledger.write(json.dumps(dict(root=root, language=language, kind=kind, entry=entry, passed=passed, report=str(path)),
                                        ensure_ascii=False) + '\n')
        failures += not passed
    return int(failures != 0)


if __name__ == '__main__':
    raise SystemExit(main())
