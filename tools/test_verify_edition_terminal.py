import gzip
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from verify_edition_terminal import PublicationSeeds, check_compact_reading_margins, choose_startup_language, copy_indexed_page, copy_publication, library_selection_keys, main, reading_body, reveal_witness, source_witness_visible, visible_body_witness
from verify_reader_ux import CheckFailure, DOWN, ENTER, ReaderPty


class EditionTerminalTests(unittest.TestCase):
    def test_transcript_compression_preserves_control_bytes_and_original_format(self):
        with tempfile.TemporaryDirectory() as tmp:
            reader = ReaderPty.__new__(ReaderPty)
            reader.output = Path(tmp)
            reader.raw = bytearray(b'\x1b[?1049h\x1b[2J\xff\x00' + 'ᑐᖁᓂᖅ'.encode() + b'\x1b[?1049l')
            plain = reader.write_transcript()
            self.assertEqual(plain.name, 'terminal.ansi')
            reader.compress_transcript = True
            compressed = reader.write_transcript()
            self.assertEqual(compressed.name, 'terminal.ansi.gz')
            self.assertEqual(gzip.decompress(compressed.read_bytes()), plain.read_bytes())
            self.assertEqual(plain.read_bytes(), reader.raw)

    def test_source_witness_requires_the_rendered_directional_mark(self):
        self.assertEqual(visible_body_witness('ᓄᖅᑲᖓᔪᑦ\u200e'), r'ᓄᖅᑲᖓᔪᑦ\u{200e}')
        self.assertEqual(visible_body_witness(' A\tB\nC\u2028D\u200dE '), 'A B C\\u{2028}D\u200dE')

    def test_indexed_page_uses_the_successful_writer_selection_and_only_reader_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            case = parent / 'page-0000'
            source = case / 'data'
            (source / 'languages').mkdir(parents=True)
            (source / 'languages.tsv').write_text('heading\nEnglish\n')
            blob = source / 'languages' / ('a' * 64 + '.wikblb')
            blob.write_bytes(b'original page')
            (source / '.dict-cache').mkdir()
            (source / '.dict-cache' / 'borrowed').write_text('do not copy')
            coverage = source / 'page-coverage.json'
            coverage.write_text(json.dumps(dict(version=1, start_page=12, index_byte_offset=831, pages_seen=1, requested_limit=1)))
            receipt = case / 'ordinary-output-result.json'
            page = dict(schema='wikidict.ordinary-indexed-output.v1', name=case.name, ordinal=12, index_byte_offset=831,
                        complete=True, error_name=None, index_row_sha256='f' * 64)
            receipt.write_text(json.dumps(page))
            work = parent / 'work'
            result = copy_indexed_page(case, work)
            self.assertEqual(set(result['reader_files']), {'languages.tsv', 'languages/' + blob.name})
            self.assertEqual(result['reader_files']['languages/' + blob.name]['sha256'], hashlib.sha256(blob.read_bytes()).hexdigest())
            self.assertFalse((work / 'complete.json').exists())
            self.assertFalse((work / '.dict-cache').exists())
            for changed in [dict(complete=False), dict(error_name='UncompiledPresentation'), dict(ordinal=13), dict(index_byte_offset=17)]:
                with self.subTest(changed=changed):
                    receipt.write_text(json.dumps(page | changed))
                    with self.assertRaises(CheckFailure):
                        copy_indexed_page(case, parent / 'refused')
                    self.assertFalse((parent / 'refused').exists())
            receipt.write_text(json.dumps(page))
            blob.unlink()
            blob.symlink_to(receipt)
            with self.assertRaisesRegex(CheckFailure, 'Invalid file'):
                copy_indexed_page(case, parent / 'bad-member')

    def test_whole_edition_cannot_opt_out_of_member_digest_verification(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            source = parent / 'edition'
            source.mkdir()
            (source / 'languages.tsv').write_text('heading\nEnglish\n')
            (source / 'complete.json').write_text(json.dumps({'status': 'built', 'publication_files': {'languages.tsv': None}}))
            with self.assertRaisesRegex(CheckFailure, 'size and digest'):
                copy_publication(source, parent / 'stage')
            self.assertFalse((parent / 'stage').exists())

    def test_library_route_uses_only_keys_offered_by_the_rendered_chooser(self):
        names = [f'Heading {i}' for i in range(138)]
        display = [''] * 30
        display[5:25] = names[:20]
        display[-2] = 'PgUp/PgDn page  Home/End'
        self.assertEqual(library_selection_keys(display, names, names[137]), b'\x1b[F' + ENTER)
        self.assertEqual(library_selection_keys(display, names, names[40]), b'\x1b[H' + b'\x1b[6~' * 2 + ENTER)
        self.assertEqual(library_selection_keys(display, names, names[117]), b'\x1b[F\x1b[5~' + ENTER)
        display[5] = 'truncated…'
        self.assertEqual(library_selection_keys(display, names, names[2]), b'\x1b[H' + DOWN * 2 + ENTER)
        display[-2] = 'Use arrows'
        self.assertEqual(library_selection_keys(display, names, names[2]), DOWN * 2 + ENTER)

    def test_implicit_startup_selects_the_requested_catalog_heading(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            catalog = root / 'languages.tsv'
            catalog.write_text('heading\nAymar aru\nUnclassified\nruso\n')
            reader = Mock()
            reader.screen.display = ['', 'Library']
            reader.text.return_value = 'Installed dictionaries'
            reader.wait.side_effect = lambda ready, label: self.assertTrue(ready(), label)

            def choose(keys, ready, label):
                self.assertEqual(keys, DOWN * 2 + ENTER)
                reader.screen.display = ['  dict.     ruso / language', '']
                reader.page_is.return_value = True
                self.assertTrue(ready(), label)

            reader.action.side_effect = choose
            choose_startup_language(reader, root, 'ruso')
            reader.action.assert_called_once()
            reader.snapshot.assert_called_once_with('language-chooser')
            with self.assertRaisesRegex(CheckFailure, 'missing from the catalog'):
                choose_startup_language(reader, root, 'English')

    def test_batch_preserves_stale_generation_failure_and_runs_next_case(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            source = parent / 'published'
            source.mkdir()
            catalog = b'heading\nOwner\n'
            (source / 'languages.tsv').write_bytes(catalog)
            manifest = json.dumps({'status': 'built', 'publication_files': {'languages.tsv': {
                'size': len(catalog), 'sha256': hashlib.sha256(catalog).hexdigest()}}}).encode()
            (source / 'complete.json').write_bytes(manifest)
            digest = hashlib.sha256(manifest).hexdigest()
            binary = parent / 'reader'
            binary.write_bytes(b'test double')
            selections = parent / 'entries.tsv'
            selections.write_text('output_directory\towner_heading\texact_title\tvisible_definition_witness\tselected_complete_sha256\tredirect_target\n'
                                  f'{source}\tOwner\tA\tFirst\t{"0" * 64}\t\n'
                                  f'{source}\tOwner\tB\tSecond\t{digest}\tDestination\n')
            factory = Mock(return_value=Mock(checks=['checked'], snapshots=[]))
            with patch('verify_edition_terminal.screen_projection', return_value=(None, factory)), \
                    patch('verify_edition_terminal.exercise') as exercise:
                self.assertEqual(main(['--binary', str(binary), '--cases', str(selections),
                                       '--report', str(parent / 'reports')]), 1)
            exercise.assert_called_once_with(factory.return_value, 'Owner', 'B', 'Second', 'Destination')
            self.assertEqual(factory.call_args.kwargs['kind'], 'language')
            ledger = next((parent / 'reports').glob('*/results.jsonl'))
            first, second = [json.loads(line) for line in ledger.read_text().splitlines()]
            self.assertEqual([first['passed'], second['passed']], [False, True])
            self.assertIn('manifest has changed', json.loads(Path(first['report']).read_text())['error'])
            self.assertEqual(json.loads(Path(second['report']).read_text())['complete_sha256'], digest)

    def test_failed_native_review_closes_reader_and_preserves_publication(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            source = parent / 'source'
            source.mkdir()
            data = b'heading\nOwner\n'
            (source / 'languages.tsv').write_bytes(data)
            (source / 'complete.json').write_text(json.dumps({'status': 'built', 'publication_files': {
                'languages.tsv': {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}}}))
            before = {p.name: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns) for p in source.iterdir()}
            binary = parent / 'reader'
            binary.write_bytes(b'not executed')
            events = []

            class FailedReader:
                def __init__(self, binary, root, width, rows, output, timeout, budget_end, projection, **kwargs):
                    self.screen = SimpleNamespace(close=lambda: events.append('projection closed'))
                    self.checks, self.snapshots = ['original check'], []
                    self.private_root = root
                    (root / 'languages.tsv').write_bytes(b'private state changed')
                    self.width, self.rows, self.timeout = width, rows, timeout

                def wait(self, predicate, label):
                    events.append((self.timeout, label))

                def snapshot(self, label):
                    events.append(label)

                def close(self):
                    events.append('reader closed')

            def fail(reader, language, entry, witness, redirect_target):
                self.assertIsNone(redirect_target)
                self.assertEqual((reader.width, reader.rows, reader.timeout), (90, 30, 5))
                self.assertNotEqual(reader.private_root, source)
                raise CheckFailure('body witness missing')

            with patch('verify_edition_terminal.screen_projection', return_value=(None, FailedReader)), \
                    patch('verify_edition_terminal.exercise', side_effect=fail):
                result = main(['--binary', str(binary), '--root', str(source), '--language', 'Owner',
                               '--entry', 'Title', '--witness', 'body', '--report', str(parent / 'reports'),
                               '--screen-projection', 'libvterm'])
            self.assertEqual(result, 1)
            self.assertEqual(events, [(45, 'opened edition'), 'failure-before-close', 'reader closed', 'projection closed'])
            report = json.loads(next((parent / 'reports').glob('*/result.json')).read_text())
            self.assertFalse(report['passed'])
            self.assertEqual(report['error'], 'body witness missing')
            self.assertEqual(report['checks'], ['original check'])
            self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns) for p in source.iterdir()})

    def test_supplemental_row_uses_the_collection_without_a_language_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            root = parent / 'edition'
            root.mkdir()
            binary = parent / 'reader'
            binary.write_bytes(b'test double')
            cases = parent / 'cases.tsv'
            cases.write_text('output_directory\towner_heading\texact_title\tvisible_definition_witness\tselected_complete_sha256\tkind\n'
                             f'{root}\t\tAppendix\tBody\t{"a" * 64}\tsupplemental\n')
            factory = Mock(return_value=Mock(checks=[], snapshots=[]))
            with patch('verify_edition_terminal.copy_publication', return_value='a' * 64), \
                    patch('verify_edition_terminal.screen_projection', return_value=(None, factory)), \
                    patch('verify_edition_terminal.exercise') as exercise:
                self.assertEqual(main(['--binary', str(binary), '--cases', str(cases), '--report', str(parent / 'out')]), 0)
            self.assertEqual(factory.call_args.kwargs, {'language': None, 'kind': 'supplemental'})
            exercise.assert_called_once_with(factory.return_value, 'supplemental', 'Appendix', 'Body', None)
            result = json.loads(next((parent / 'out').glob('*/*/result.json')).read_text())
            self.assertIsNone(result['language'])
            self.assertEqual(result['kind'], 'supplemental')

    def test_only_verified_publication_members_enter_the_writable_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            source = parent / 'source'
            source.mkdir()
            (source / '.dict-state').mkdir()
            (source / '.dict-state/history.json').write_text('original')
            data = b'heading\nRuna Simi\n'
            catalog = source / 'languages.tsv'
            catalog.write_bytes(data)
            manifest = {'status': 'built', 'publication_files': {
                'languages.tsv': {'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}}}
            (source / 'complete.json').write_text(json.dumps(manifest))
            dest = parent / 'workspace'
            copy_publication(source, dest)
            self.assertFalse((dest / '.dict-state').exists())
            (dest / 'languages.tsv').write_bytes(b'changed')
            self.assertEqual(catalog.read_bytes(), data)
            self.assertEqual((source / '.dict-state/history.json').read_text(), 'original')
            catalog.write_bytes(b'x' * len(data))
            with self.assertRaisesRegex(CheckFailure, 'member differs'):
                copy_publication(source, parent / 'bad')

    def test_authenticated_seed_rechecks_source_and_keeps_each_case_writable(self):
        def copy_fd(source, target):
            target.write(os.pread(source.fileno(), os.fstat(source.fileno()).st_size, 0))
            target.flush()
            target.seek(0)
            return True

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            source = work / 'edition'
            source.mkdir()
            member = source / 'languages.tsv'
            data = b'x' * (1024 * 1024 + 1)
            member.write_bytes(data)
            manifest = {'status': 'built', 'publication_files': {'languages.tsv': {
                'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}}}
            (source / 'complete.json').write_text(json.dumps(manifest))
            seeds = PublicationSeeds()
            self.addCleanup(seeds.close)
            with patch('verify_edition_terminal.clone_file', side_effect=copy_fd), \
                    patch('verify_edition_terminal.hashlib.file_digest', wraps=hashlib.file_digest) as digest:
                copy_publication(source, work / 'first', seeds=seeds)
                (work / 'first/languages.tsv').write_bytes(b'own case data')
                copy_publication(source, work / 'second', seeds=seeds)
                self.assertEqual(digest.call_count, 1)
                self.assertEqual((work / 'second/languages.tsv').read_bytes(), data)
                stamp = member.stat()
                member.write_bytes(b'y' + data[1:])
                os.utime(member, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                with self.assertRaisesRegex(CheckFailure, 'member differs'):
                    copy_publication(source, work / 'corrupt', seeds=seeds)
                member.unlink()
                with self.assertRaisesRegex(CheckFailure, 'Invalid file'):
                    copy_publication(source, work / 'missing', seeds=seeds)
                member.write_bytes(data)
                copy_publication(source, work / 'restored', seeds=seeds)
                self.assertEqual(digest.call_count, 3)
            with patch('verify_edition_terminal.clone_file', return_value=False), \
                    patch('verify_edition_terminal.hashlib.file_digest', wraps=hashlib.file_digest) as digest:
                copy_publication(source, work / 'ordinary', seeds=seeds)
                digest.assert_called_once()
                self.assertEqual((work / 'ordinary/languages.tsv').read_bytes(), data)

    def test_first_copy_across_devices_seeds_later_independent_reader_cases(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            source = work / 'edition'
            source.mkdir()
            original = source / 'languages.tsv'
            payload = b'a' * (1024 * 1024)
            original.write_bytes(payload)
            member = {'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}
            (source / 'complete.json').write_text(json.dumps({
                'status': 'built', 'publication_files': {'languages.tsv': member}}))

            def local_clone(src, dst):
                if os.path.samestat(os.fstat(src.fileno()), original.stat()):
                    return False  # The publication is on a different device from the reports.
                dst.write(os.pread(src.fileno(), len(payload), 0))
                dst.flush()
                dst.seek(0)
                return True

            seeds = PublicationSeeds()
            self.addCleanup(seeds.close)
            with patch('verify_edition_terminal.clone_file', side_effect=local_clone), \
                 patch('verify_edition_terminal.hashlib.file_digest', wraps=hashlib.file_digest) as digest:
                copy_publication(source, work / 'first', seeds=seeds)
                (work / 'first/languages.tsv').write_bytes(b'first reader state')
                copy_publication(source, work / 'second', seeds=seeds)
                self.assertEqual((work / 'second/languages.tsv').read_bytes(), payload)
                self.assertEqual(original.read_bytes(), payload)
                digest.assert_called_once()

    def test_copying_a_verified_empty_catalog_requires_explicit_empty_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            source = work / 'original'
            source.mkdir()
            catalog = b'heading\n'
            (source / 'languages.tsv').write_bytes(catalog)
            (source / 'complete.json').write_text(json.dumps({'status': 'empty', 'publication_files': {
                'languages.tsv': {'size': len(catalog), 'sha256': hashlib.sha256(catalog).hexdigest()}}}))
            with self.assertRaisesRegex(CheckFailure, 'manifest status'):
                copy_publication(source, work / 'entry-review')
            copy_publication(source, work / 'empty-review', expected_status='empty')
            self.assertEqual((work / 'empty-review/languages.tsv').read_bytes(), catalog)

    def test_long_entries_reach_the_last_page_and_a_middle_page_past_64(self):
        class Pages:
            width = 45
            position = 0
            page_downs = 0

            def text(self):
                return str(self.position)

            def entry_focused(self):
                return True

            def action(self, key, predicate, _label):
                if key == b'\x1b[5~':
                    self.position = max(0, self.position - 1)
                else:
                    self.position = {b'\x1b[F': 95, b'\x1b[H': 0}[key]
                assert predicate()

            def send(self, key):
                assert key == b'\x1b[6~'
                self.page_downs += 1
                self.position = min(95, self.position + 1)
                return self.position

            def wait(self, predicate, _label, *, after):
                assert self.position == after and predicate()

        pages = Pages()
        with patch('verify_edition_terminal.reading_body', return_value='text'), \
             patch('verify_edition_terminal.source_witness_visible', side_effect=lambda r, w, h: r.text() == w):
            for wanted in ('95', '94', '74'):
                pages.position = 0
                reveal_witness(pages, wanted, 'title')
                self.assertEqual(wanted, pages.text())
                if wanted == '94':
                    self.assertEqual(pages.page_downs, 0)
            with self.assertRaisesRegex(CheckFailure, 'Source witness missing'):
                reveal_witness(pages, 'absent', 'title')

    def test_body_witness_excludes_match_sidebar_and_reading_title(self):
        lines = [''] * 11
        lines[6:9] = ['other title │ chosen / owner', 'sidebar │', 'wrong │ actual definition']
        reader = SimpleNamespace(width=90, screen=SimpleNamespace(display=lines))
        self.assertEqual(reading_body(reader, 'chosen / owner'), 'actual definition')
        reader.width = 45
        lines[6:8] = ['first scrolled definition line', 'second line']
        lines[8] = 'part one │ part two'
        self.assertEqual(reading_body(reader, 'chosen / owner'), 'first scrolled definition line second line part one │ part two')

    def test_complete_table_verifies_wraps_in_their_original_rows_and_columns(self):
        lines = ['  │ Gen │ σημ │ σημ │', '  │     │ αία │ αιώ │', '  │     │  ς  │  ν  │',
                 '  │ Acc │ σημ │ σημ │', '  │     │ αία │ αίε │', '  │     │     │  ς  │']
        display = [''] * 6 + lines + [''] * 2
        rows = [[{'text': char} for char in line.ljust(45)] for line in display]
        reader = SimpleNamespace(width=45, screen=SimpleNamespace(display=display, cell_rows=lambda: rows))
        expected = [['Gen', 'σημαίας', 'σημαιών'], ['Acc', 'σημαία', 'σημαίες']]
        reader.expected_table = expected
        self.assertTrue(source_witness_visible(reader, 'σημαιών', 'σημαία / griego'))
        for wrong in (expected[::-1], expected[:1], expected + expected, [expected[0], expected[1][::-1]],
                      [['Gen', 'σημαίας', 'σημαίων'], expected[1]]):
            reader.expected_table = wrong
            self.assertFalse(source_witness_visible(reader, 'σημαιών', 'σημαία / griego'))
        reader.expected_table = expected
        rows[7][8]['text'] = ' '
        self.assertFalse(source_witness_visible(reader, 'σημαιών', 'σημαία / griego'))

    def test_wrapped_definition_beside_table_uses_only_its_own_physical_column(self):
        lines = [''] * 6 + [
            'sidebar'.ljust(29) + '│ chosen / owner  │a │b│',
            'private'.ljust(29) + '│ first words     │no│c│',
            'match'.ljust(29) + '│ next words      │so│d│',
            'elsewhere'.ljust(29) + '│ unrelated column │o│d│',
        ] + [''] * 2
        cells = [[{'text': char} for char in line] for line in lines]
        reader = SimpleNamespace(width=90, screen=SimpleNamespace(display=lines, cell_rows=lambda: cells))
        self.assertTrue(source_witness_visible(reader, 'first words next words', 'chosen / owner'))
        for witness in ('next words unrelated column', 'private match', 'chosen / owner first words'):
            self.assertFalse(source_witness_visible(reader, witness, 'chosen / owner'))

    def test_wrapped_source_words_inside_one_bordered_cell(self):
        def row(left, right=''):
            return 'sidebar'.ljust(29) + f'│   │ {left:21} │ {right:12} │'

        lines = [''] * 6 + [row('Parto supra di la', 'first'), row('kapitelo di kolono,', 'second'),
                            row('qua havas', 'third'), row('next section'), row(''),
                            row('another entry')] + [''] * 2
        cells = [[{'text': c} for c in line] for line in lines]
        reader = SimpleNamespace(width=90, screen=SimpleNamespace(display=lines, cell_rows=lambda: cells))
        self.assertTrue(source_witness_visible(reader, 'Parto supra di la kapitelo di kolono, qua havas', 'abako / Ido'))
        for wrong in ('di la second', 'first kapitelo', 'third next section', 'havas next section',
                      'section another entry', 'sidebar Parto', 'kapitelo supra di'):
            self.assertFalse(source_witness_visible(reader, wrong, 'abako / Ido'))

    def test_full_width_glyph_wrap_only_rejoins_at_the_pane_edge(self):
        def cells(text):
            row = []
            for char in text:
                width = 2 if ord(char) > 127 else 1
                row.append({'text': char, 'width': width})
                if width == 2:
                    row.append({'text': '', 'width': 0})
            return row + [{'text': ' ', 'width': 1}] * (45 - len(row))

        rows = [cells('')] * 6 + [cells('  Adam / 英文'), cells('  ' + '甲' * 20),
                                  cells('  乙丙'), cells('  丁戊')] + [cells('')] * 2
        display = [''.join(c['text'] for c in row) for row in rows]
        reader = SimpleNamespace(width=45, screen=SimpleNamespace(display=display, cell_rows=lambda: rows))
        self.assertTrue(source_witness_visible(reader, '甲甲乙丙', 'Adam / 英文'))
        for hidden in ('乙丙丁戊', '甲甲丙乙', 'Adam / 英文'):
            self.assertFalse(source_witness_visible(reader, hidden, 'Adam / 英文'))

    def test_narrow_definition_and_wide_glyphs_stay_inside_the_reading_pane(self):
        rows = [[' '] * 45 for _ in range(24)]
        rows[5][0], rows[22][-1] = 'H', 'F'  # Header and footer span the full terminal.
        rows[15][41:43] = ['語', '']

        def check(error=None):
            native = SimpleNamespace(cell_rows=lambda: [[{'text': c} for c in row] for row in rows])
            pyte = SimpleNamespace(buffer=[[SimpleNamespace(data=c) for c in row] for row in rows])
            for screen in (native, pyte):
                reader = SimpleNamespace(screen=screen, rows=24, width=45)
                if error is None:
                    check_compact_reading_margins(reader)
                else:
                    with self.assertRaisesRegex(CheckFailure, error):
                        check_compact_reading_margins(reader)

        check()
        rows[16][0] = '။'
        check('row 17, column 1')
        rows[16][0] = ' '
        rows[15][41:44] = [' ', '語', '']
        check('row 16, column 44')
