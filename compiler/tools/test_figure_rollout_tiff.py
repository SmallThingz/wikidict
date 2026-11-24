"""The authenticated singleton TIFF join keeps the ordinary rollout scope."""
import copy
import gzip
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import prepare_figure_metadata as figure


class RolloutTiffReplayTests(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).with_name('testdata')
        fixture = source / 'current-file-observations' / 'ru-ordinary-rollout-tiff.json.gz'
        self.proof = json.loads(gzip.decompress(fixture.read_bytes()))
        self.namespace = (source / 'ru-denaske114' / 'namespace-registry.tsv').read_bytes()
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name, text in self.proof['artifacts'].items():
            (self.root / name).write_bytes(text.encode())

    def replay(self, *, wiki='ruwiktionary', profile=None, compatible=True):
        return figure.replay_source(
            self.root, self.proof['reference'], self.proof['batch'], wiki, '20261001',
            self.namespace, set(), {}, profile_kind=profile or figure.FIGURE_PROFILE_V4,
            allow_compatible_epochs=compatible)

    def test_real_rollout_companion_keeps_http_and_image_identity(self):
        result = self.replay()
        base = 'file-metadata.response-010169-01.raw.json'
        tiff = 'file-metadata.tiff-response-010169-01.raw.json'
        self.assertEqual(set(result), {base, tiff, ('tiff-titles', base)})
        reference = self.proof['reference']['tiff_batch']['request']
        self.assertEqual(result.pop(('tiff-titles', base)), json.loads((self.root / reference).read_text())['titles'])
        for name, identity in result.items():
            field = 'tiff_metadata_response' if '.tiff-' in name else 'response'
            raw = self.proof['batch'][field].encode()
            self.assertEqual(identity, {'sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw)})

    def test_rollout_requires_edition_profile_and_receipts(self):
        for options in ({'wiki': 'dewiktionary'}, {'profile': figure.FIGURE_PROFILE_V5}, {'compatible': False}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.replay(**options)
        receipt = self.root / self.proof['reference']['tiff_batch']['accepted_receipt']
        original = json.loads(receipt.read_bytes())
        receipt.write_bytes(figure.encoded(dict(original, response_sha256='f' * 64)))
        with self.assertRaises(ValueError):
            self.replay()

    def test_tiff_companion_cannot_borrow_a_different_epoch_or_file(self):
        batch = self.proof['batch']
        original = json.loads(batch['tiff_metadata_response'])
        receipt = self.root / self.proof['reference']['tiff_batch']['accepted_receipt']
        original_receipt = json.loads(receipt.read_bytes())
        for field in ('core', 'file', 'registered-handler', 'generator'):
            with self.subTest(field=field):
                changed = copy.deepcopy(original)
                if field == 'core':
                    changed['query']['general']['git-hash'] = figure.site_info.FIGURE_WMF5_CORE
                elif field == 'generator':
                    changed['query']['general']['generator'] = 'MediaWiki 1.48.0-wmf.6'
                elif field == 'file':
                    changed['query']['pages'][0]['imageinfo'][0]['sha1'] = '0' * 40
                else:
                    handler = next(e for e in changed['query']['extensions'] if e['name'] == 'PagedTiffHandler')
                    handler['vcs-version'] = 'f' * 40
                raw = figure.encoded(changed)
                receipt.write_bytes(figure.encoded(dict(original_receipt, response_bytes=len(raw),
                                                        response_sha256=hashlib.sha256(raw).hexdigest())))
                batch['tiff_metadata_response'] = raw.decode()
                with self.assertRaises(ValueError):
                    self.replay()
