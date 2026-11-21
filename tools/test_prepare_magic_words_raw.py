import copy
import json
from pathlib import Path
import tempfile
import unittest
import prepare_magic_words_raw as raw

B=Path(__file__).parent
CAPTURE=B/'testdata'/'ml-raw-transclusion'

class RawProjectionTests(unittest.TestCase):
    def inputs(self):
        manifest=raw.legacy.parse_json((CAPTURE/'magic-words.manifest.json').read_bytes())
        blobs={name:(CAPTURE/name).read_bytes() for name in manifest['artifacts']}
        return manifest,blobs

    def test_actual_capture_adds_only_two_captured_raw_rows(self):
        manifest,blobs=self.inputs()
        raw.validate_capture(manifest,blobs,'mlwiktionary','20261001')
        old=blobs[raw.SOURCE_TSV].splitlines();new=blobs['magic-words.tsv'].splitlines()
        self.assertEqual(old,[row for row in new if not row.startswith(b'raw\t')])
        self.assertEqual([row.decode() for row in new if row.startswith(b'raw\t')],['raw\t0\tRAW:','raw\t0\tഅസംസ്കൃതം:'])
        self.assertEqual(raw.legacy.digest(blobs[raw.SOURCE_TSV]),'57b678a18f73dec67cb9140663c41a4328e68b635accf95db531149629f46dc8')
        self.assertEqual(raw.capture_artifacts(CAPTURE,manifest)['magic-words.tsv'],manifest['output_sha256'])

    def test_case_flags_and_complete_prefixes_remain_source_values(self):
        _,blobs=self.inputs();data=raw.legacy.parse_json(blobs['magic-words.raw.json'])
        word=next(w for w in data['query']['magicwords'] if w['name']=='raw')
        word.update(aliases=['Exact：'],**{'case-sensitive':True})
        new,_=raw.render_snapshot(data,blobs[raw.SOURCE_TSV])
        self.assertIn('raw\t1\tExact：\n'.encode(),new)
        self.assertNotIn(b'raw\t0\tRAW:',new)

    def test_duplicate_invalid_and_unavailable_raw_authority_refused(self):
        _,blobs=self.inputs();original=raw.legacy.parse_json(blobs['magic-words.raw.json'])
        for kind in ('missing','duplicate','alias','empty','colonless','nested','control','flag'):
            with self.subTest(kind=kind):
                data=copy.deepcopy(original);word=next(w for w in data['query']['magicwords'] if w['name']=='raw')
                if kind=='missing':data['query']['magicwords'].remove(word)
                elif kind=='duplicate':data['query']['magicwords'].append(copy.deepcopy(word))
                elif kind=='alias':word['aliases'].append(word['aliases'][0])
                elif kind=='empty':word['aliases']=[]
                elif kind=='colonless':word['aliases']=['RAW']
                elif kind=='nested':word['aliases']=['raw:extra:']
                elif kind=='control':word['aliases']=['raw\n:']
                else:word['case-sensitive']=1
                with self.assertRaises(ValueError):raw.render_snapshot(data,blobs[raw.SOURCE_TSV])

    def test_rehashed_output_and_changed_predecessor_do_not_gain_authority(self):
        original,original_blobs=self.inputs()
        for kind in ('output','source','identity'):
            with self.subTest(kind=kind):
                manifest=copy.deepcopy(original);blobs=dict(original_blobs)
                if kind=='output':
                    blobs['magic-words.tsv']=blobs['magic-words.tsv'].replace(b'RAW:',b'INVENTED:')
                    manifest['output_sha256']=raw.legacy.digest(blobs['magic-words.tsv'])
                    manifest['output_bytes']=len(blobs['magic-words.tsv'])
                    manifest['artifacts']['magic-words.tsv']=manifest['output_sha256']
                elif kind=='source':
                    blobs[raw.SOURCE_TSV]+=b'raw\t0\tRAW:\n'
                    manifest['artifacts'][raw.SOURCE_TSV]=raw.legacy.digest(blobs[raw.SOURCE_TSV])
                    manifest['source_capture']['output_sha256']=raw.legacy.digest(blobs[raw.SOURCE_TSV])
                else:manifest['wiki']='otherwiktionary'
                with self.assertRaises(ValueError):raw.validate_capture(manifest,blobs,'mlwiktionary','20261001')

    def test_unknown_artifact_name_is_never_read(self):
        manifest,blobs=self.inputs()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for name,body in blobs.items():(root/name).write_bytes(body)
            manifest['artifacts']['../outside']=raw.legacy.digest(b'outside')
            (root/'magic-words.manifest.json').write_bytes(raw.legacy.document(manifest))
            with self.assertRaises(ValueError):raw.validate_snapshot(root)

if __name__=='__main__':unittest.main()
