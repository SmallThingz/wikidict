import copy
import unittest
from unittest.mock import patch
import prepare_magic_words_category as magic
import prepare_magic_words_statistics as prior
import test_prepare_magic_words_statistics as fixtures

class CategoryMagicWordsTests(unittest.TestCase):
    wiki='arwiktionary'
    date='20261001'
    setUp=fixtures.StatisticsMagicWordCaptureTests.setUp
    contents=fixtures.StatisticsMagicWordCaptureTests.contents

    def response(self):
        data=fixtures.StatisticsMagicWordCaptureTests.response(self)
        data['query']['magicwords'].extend([
            dict(name='pagesincategory',aliases=['صفحات_في_التصنيف','PAGESINCATEGORY'],**{'case-sensitive':True}),
            dict(name='pagesincategory_pages',aliases=['صفحات','pages']),
            dict(name='pagesincategory_all',aliases=['كل','all']),
            dict(name='pagesincategory_files',aliases=['ملفات','files']),
            dict(name='pagesincategory_subcats',aliases=['تصنيفات_فرعية','subcats']),
            dict(name='rawsuffix',aliases=['أر','R'],**{'case-sensitive':True})])
        return data

    def test_category_tokens_preserve_every_old_row_and_exact_flags(self):
        data=self.response();old,old_count=prior.render_snapshot(data,self.wiki,self.date,'ar')
        new,count=magic.render_snapshot(data,self.wiki,self.date,'ar')
        self.assertEqual([r for r in new.splitlines() if r.split(b'\t')[0].decode() not in magic.CATEGORY_WORDS],old.splitlines())
        self.assertEqual(count,old_count+12)
        self.assertIn('rawsuffix\t1\tأر\n'.encode(),new)
        self.assertIn(b'pagesincategory_pages\t0\tpages\n',new)
        data['query']['magicwords'].reverse();self.assertEqual(magic.render_snapshot(data,self.wiki,self.date,'ar'),(new,count))
        plain=copy.deepcopy(data);plain['query']['magicwords']=[w for w in plain['query']['magicwords'] if w['name'] not in magic.CATEGORY_WORDS]
        self.assertEqual(magic.render_snapshot(plain,self.wiki,self.date,'ar'),prior.render_snapshot(plain,self.wiki,self.date,'ar'))

    def test_immutable_v6_derivation_replay_and_incomplete_preference(self):
        root,lst=fixtures.StatisticsMagicWordCaptureTests.fixture(self)
        source=root/prior.DERIVED_DIRECTORY;prior.derive_snapshot(lst,source)
        before={p:self.contents(p) for p in root.iterdir() if p.is_dir()}
        output=root/magic.DERIVED_DIRECTORY
        with patch.object(magic.legacy,'fetch_response',side_effect=AssertionError('No network')):
            manifest,created=magic.derive_snapshot(source,output)
            self.assertTrue(created);self.assertEqual(manifest['version'],7)
            self.assertEqual((output/magic.SOURCE_TSV).read_bytes(),(source/'magic-words.tsv').read_bytes())
            self.assertEqual(magic.derive_snapshot(source,output),(manifest,False))
            self.assertEqual(magic.selected_snapshot_root(root),output)
        for p,raw in before.items():self.assertEqual(self.contents(p),raw)
        (output/'magic-words.tsv').chmod(0o644);(output/'magic-words.tsv').write_bytes(b'changed')
        with self.assertRaises(ValueError):magic.selected_snapshot_root(root)
        self.assertEqual(prior.validate_snapshot(source)['version'],6)

    def test_duplicate_flags_and_unsafe_aliases_refuse(self):
        for change in ('duplicate','flag','empty','control'):
            data=self.response()
            if change=='duplicate':data['query']['magicwords'].append(copy.deepcopy(data['query']['magicwords'][-1]))
            elif change=='flag':data['query']['magicwords'][-1]['case-sensitive']=1
            elif change=='empty':data['query']['magicwords'][-1]['aliases']=[]
            else:data['query']['magicwords'][-1]['aliases']=['bad\talias']
            with self.subTest(change=change),self.assertRaises(ValueError):magic.render_snapshot(data,self.wiki,self.date,'ar')
