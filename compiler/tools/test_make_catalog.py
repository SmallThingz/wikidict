import hashlib
import lzma
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import make_catalog as c


def language_blob(code='en', heading='English'):
    return b'WIKBLB08\x01' + code.encode() + b'\0' + heading.encode() + b'\0'


class CatalogTest(unittest.TestCase):
    def test_alias_discovery_and_catalogue_use_raw_and_xz_transport_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            alias_blob = b'WIKBLB08\x08'
            raw = root / 'raw-aliases.wikblb'
            raw.write_bytes(alias_blob)
            twin = root / 'packed-aliases.wikblb'
            twin.write_bytes(alias_blob)
            compressed = root / 'packed-aliases.wikblb.xz'
            compressed.write_bytes(lzma.compress(alias_blob))
            selected = c.catalogue_files(root)
            self.assertEqual(set(selected), {raw, compressed})
            rows = c.catalogue(selected, 'https://example.test/release').splitlines()[1:]
            self.assertEqual(len(rows), 2)
            expected = {
                f'https://example.test/release/{path.name}\tAliases\t{path.stat().st_size}\t{hashlib.sha256(path.read_bytes()).hexdigest()}'
                for path in (raw, compressed)
            }
            self.assertEqual(set(rows), expected)
            self.assertNotEqual(compressed.stat().st_size, len(alias_blob))
            self.assertNotEqual(hashlib.sha256(compressed.read_bytes()).hexdigest(), hashlib.sha256(alias_blob).hexdigest())

    def test_all_blob_kind_labels_and_rejection_bounds_are_preserved(self):
        labels = {1: 'English', 2: 'Thesaurus', 3: 'Citations', 4: 'Reconstructions',
                  5: 'Rhymes', 6: 'Sign glosses', 7: 'Supplemental pages', 8: 'Aliases'}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for kind, label in labels.items():
                with self.subTest(kind=kind):
                    path = root / f'kind-{kind}.wikblb'
                    path.write_bytes(language_blob() if kind == 1 else b'WIKBLB08' + bytes([kind]))
                    self.assertEqual(c.blob_label(path), label)
            for kind in (0, 9, 255):
                for compressed in (False, True):
                    with self.subTest(invalid_kind=kind, compressed=compressed):
                        path = root / ('invalid.wikblb.xz' if compressed else 'invalid.wikblb')
                        body = b'WIKBLB08' + bytes([kind]) + b'\0'
                        path.write_bytes(lzma.compress(body) if compressed else body)
                        with self.assertRaisesRegex(ValueError, 'invalid blob kind'):
                            c.catalogue([path], 'https://example.test/release')

    def test_raw_and_xz_catalogue_use_transport_size_and_checksum(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            raw = root / 'English.wikblb'
            raw.write_bytes(language_blob())
            compressed = root / 'French.wikblb.xz'
            compressed.write_bytes(lzma.compress(language_blob('fr', 'French')))

            text = c.catalogue([raw, compressed], 'https://example.test/release')
            rows = text.splitlines()
            self.assertEqual(len(rows), 3)
            self.assertIn('\tEnglish\t', rows[1])
            self.assertIn('\tFrench\t', rows[2])
            self.assertTrue(rows[2].endswith(hashlib.sha256(compressed.read_bytes()).hexdigest()))
            self.assertIn(f'\t{compressed.stat().st_size}\t', rows[2])

    def test_file_discovery_prefers_compressed_twin(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            raw = root / 'same.wikblb'
            xz = root / 'same.wikblb.xz'
            raw.write_bytes(language_blob())
            xz.write_bytes(lzma.compress(raw.read_bytes()))
            other = root / 'other.wikblb'
            other.write_bytes(language_blob('fr', 'French'))
            self.assertEqual(set(c.catalogue_files(root)), {xz, other})

    def test_rejects_bad_transport_and_header(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bad_xz = root / 'bad.wikblb.xz'
            bad_xz.write_bytes(b'not-xz')
            with self.assertRaisesRegex(ValueError, 'invalid XZ'):
                c.catalogue([bad_xz], 'https://example.test/release')
            wrong = root / 'wrong.wikblb'
            wrong.write_bytes(b'BAD')
            with self.assertRaisesRegex(ValueError, 'not a WIKBLB08'):
                c.catalogue([wrong], 'https://example.test/release')

    def test_rejects_duplicate_asset_names_and_invalid_urls(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            one = root / 'a' / 'English.wikblb'
            two = root / 'b' / 'English.wikblb'
            one.parent.mkdir(); two.parent.mkdir()
            one.write_bytes(language_blob()); two.write_bytes(language_blob())
            with self.assertRaisesRegex(ValueError, 'duplicate release asset'):
                c.catalogue([one, two], 'https://example.test/release')
            with self.assertRaisesRegex(ValueError, 'plain HTTPS'):
                c.catalogue([one], 'http://example.test/release')

    def test_enforces_client_entry_and_byte_limits(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'English.wikblb'
            path.write_bytes(language_blob())
            with patch.object(c, 'MAX_CATALOG_ENTRIES', 0):
                with self.assertRaisesRegex(ValueError, 'more than 0'):
                    c.catalogue([path], 'https://example.test/release')
            with patch.object(c, 'MAX_CATALOG_BYTES', 1):
                with self.assertRaisesRegex(ValueError, 'exceeds 1'):
                    c.catalogue([path], 'https://example.test/release')

    def test_utf8_byte_limit_includes_multilingual_rows_and_final_newline(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = [Path(tmp) / name for name in ('one.wikblb', 'two.wikblb')]
            for path, code, label in zip(paths, ('as', 'ja'), ('অসমীয়া', '日本語')):
                path.write_bytes(language_blob(code, label))
            url = 'https://example.test/dictionaries'
            expected = c.catalogue(paths, url)
            size = len(expected.encode('utf-8'))
            self.assertGreater(size, len(expected))
            with patch.object(c, 'MAX_CATALOG_BYTES', size):
                self.assertEqual(c.catalogue(paths, url), expected)
            with patch.object(c, 'MAX_CATALOG_BYTES', size - 1):
                with self.assertRaisesRegex(ValueError, 'exceeds'):
                    c.catalogue(paths, url)

    def test_rejects_unverified_language_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'bad.wikblb'
            path.write_bytes(language_blob('', 'Not a language'))
            with self.assertRaisesRegex(ValueError, 'unverified language code'):
                c.catalogue([path], 'https://example.test/release')

    def test_rejects_empty_input(self):
        with self.assertRaisesRegex(ValueError, 'no dictionaries'):
            c.catalogue([], 'https://example.test/release')


if __name__ == '__main__':
    unittest.main()
