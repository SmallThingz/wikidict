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
