import copy
import json
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


class IsbnMagicWordsTests(unittest.TestCase):
    wiki = 'arwiktionary'
    date = '20261001'
    setUp = CategoryMagicWordsTests.setUp
    contents = CategoryMagicWordsTests.contents

    def response(self):
        data = CategoryMagicWordsTests.response(self)
        # Exact shape of the retained DE raw ISBN declaration; the surrounding
        # fixture remains synthetic and does not claim DE capture acceptance.
        data['query']['magicwords'].append(
            dict(name='isbn', aliases=['#isbn'], **{'case-sensitive': True}))
        return data

    def category(self, name='capture', data=None):
        root, lst = fixtures.StatisticsMagicWordCaptureTests.fixture(self, name, data)
        statistics = root / prior.DERIVED_DIRECTORY
        prior.derive_snapshot(lst, statistics)
        category = root / magic.DERIVED_DIRECTORY
        magic.derive_snapshot(statistics, category)
        return root, category

    def derived(self):
        root, category = self.category()
        output = root / magic.ISBN_DIRECTORY
        record, _ = magic.derive_snapshot(category, output, include_isbn=True)
        blobs = {name: magic.legacy.read_regular(output / name) for name in magic.ISBN_ARTIFACTS}
        return root, category, output, record, blobs

    def test_isbn_adds_only_captured_alias_and_absence_preserves_v7_bytes(self):
        data = self.response()
        old, count = magic.render_snapshot(data, self.wiki, self.date, 'ar')
        new, added = magic.render_isbn_snapshot(data, self.wiki, self.date, 'ar')
        self.assertEqual([line for line in new.splitlines() if not line.startswith(b'isbn\t')], old.splitlines())
        self.assertIn(b'isbn\t1\t#isbn\n', new)
        self.assertEqual(added, count + 1)
        data['query']['magicwords'].pop()
        self.assertEqual(magic.render_isbn_snapshot(data, self.wiki, self.date, 'ar'), (old, count))
        self.assertEqual(magic.render_snapshot(data, self.wiki, self.date, 'ar'), (old, count))

    def test_isbn_duplicate_record_alias_and_malformed_fields_refuse(self):
        for change in ('record', 'alias', 'flag', 'empty', 'type', 'control', 'long'):
            data = self.response(); row = data['query']['magicwords'][-1]
            if change == 'record': data['query']['magicwords'].append(copy.deepcopy(row))
            elif change == 'alias': row['aliases'].append('#isbn')
            elif change == 'flag': row['case-sensitive'] = 1
            elif change == 'empty': row['aliases'] = []
            elif change == 'type': row['aliases'] = [None]
            elif change == 'control': row['aliases'] = ['bad\talias']
            else: row['aliases'] = ['x' * 1025]
            with self.subTest(change=change), self.assertRaises(ValueError):
                magic.render_isbn_snapshot(data, self.wiki, self.date, 'ar')

    def test_offline_isbn_derivation_preserves_known_v7_preimage_and_normal_route(self):
        import build_wiktionaries as builder
        root, category = self.category()
        path = category / 'magic-words.manifest.json'
        record = json.loads(path.read_bytes())
        record['generator_sha256'] = magic.CATEGORY_V7_PRODUCER_SHA256
        path.chmod(0o644); path.write_bytes(magic.legacy.document(record))
        before = self.contents(category)
        output = root / magic.ISBN_DIRECTORY
        with patch.object(magic.legacy, 'fetch_response', side_effect=AssertionError('No network')):
            manifest, created = magic.derive_snapshot(category, output, include_isbn=True)
            self.assertTrue(created)
            self.assertEqual((manifest['version'], manifest['profile']), (9, magic.ISBN_PROFILE))
            self.assertEqual(self.contents(category), before)
            self.assertEqual((output / magic.ISBN_SOURCE_MANIFEST).read_bytes(), before['magic-words.manifest.json'][0])
            self.assertEqual((output / magic.ISBN_SOURCE_TSV).read_bytes(), before['magic-words.tsv'][0])
            frozen = self.contents(output)
            self.assertEqual(magic.derive_snapshot(category, output, include_isbn=True), (manifest, False))
            self.assertEqual(self.contents(output), frozen)
            self.assertEqual(magic.selected_snapshot_root(root), output)
            for capture in (category, output):
                tsv = capture / 'magic-words.tsv'
                self.assertIs(builder.auxiliary_capture_helper('magic-words', tsv), magic)
                validated, inventory = builder.validated_auxiliary_capture('magic-words', tsv, self.wiki, self.date)
                self.assertEqual(validated, magic.validate_snapshot(capture))
                self.assertIn('magic-words.raw.json', inventory)

    def test_missing_isbn_can_derive_without_inventing_a_row(self):
        data = self.response(); data['query']['magicwords'].pop()
        root, category = self.category(data=data)
        output = root / magic.ISBN_DIRECTORY
        record, _ = magic.derive_snapshot(category, output, include_isbn=True)
        self.assertEqual((output / 'magic-words.tsv').read_bytes(), (category / 'magic-words.tsv').read_bytes())
        self.assertEqual(magic.validate_snapshot(output), record)

    def test_present_invalid_isbn_directory_does_not_fall_back(self):
        for invalid in ('empty', 'symlink', 'category'):
            root, category = self.category(invalid)
            output = root / magic.ISBN_DIRECTORY
            if invalid == 'empty': output.mkdir()
            elif invalid == 'symlink': output.symlink_to(category.resolve(), target_is_directory=True)
            else:
                output.mkdir()
                for path in category.iterdir(): (output / path.name).write_bytes(path.read_bytes())
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                magic.selected_snapshot_root(root)

    def test_isbn_identity_roles_context_and_rebound_output_remain_strict(self):
        _, _, output, original, blobs = self.derived()
        for field, value in (
                ('version', 8), ('profile', magic.PROFILE), ('generator_sha256', '0' * 64),
                ('dependency_sha256', {}), ('source_capture', {}), ('content_language', 'de'),
                ('source_url', 'https://example.invalid/api.php'), ('raw_sha256', '0' * 64),
                ('retrieved_utc', '2026-11-01T00:00:00+00:00'),
                ('derived_utc', '2020-01-01T00:00:00+00:00')):
            record = copy.deepcopy(original); record[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                magic.validate_capture(record, blobs)
        for wiki, date in (('dewiktionary', self.date), (self.wiki, '20260901')):
            with self.assertRaises(ValueError): magic.validate_snapshot(output, wiki, date)
        missing = dict(blobs); missing.pop(magic.ISBN_SOURCE_MANIFEST)
        with self.assertRaises(ValueError): magic.validate_capture(original, missing)
        for name in ('magic-words.tsv', magic.ISBN_SOURCE_TSV):
            changed = dict(blobs)
            changed[name] = changed[name] + b'isbn\t1\t#invented\n'
            record = copy.deepcopy(original)
            record['artifacts'][name] = magic.legacy.digest(changed[name])
            if name == 'magic-words.tsv':
                record.update(output_sha256=magic.legacy.digest(changed[name]), output_bytes=len(changed[name]))
            else:
                record['source_capture']['output_sha256'] = magic.legacy.digest(changed[name])
            with self.subTest(artifact=name), self.assertRaises(ValueError):
                magic.validate_capture(record, changed)
        changed = dict(blobs)
        predecessor = json.loads(changed[magic.ISBN_SOURCE_MANIFEST])
        predecessor['rows'] += 1
        changed[magic.ISBN_SOURCE_MANIFEST] = magic.legacy.document(predecessor)
        record = copy.deepcopy(original)
        digest = magic.legacy.digest(changed[magic.ISBN_SOURCE_MANIFEST])
        record['artifacts'][magic.ISBN_SOURCE_MANIFEST] = digest
        record['source_capture']['manifest_sha256'] = digest
        with self.assertRaises(ValueError): magic.validate_capture(record, changed)
