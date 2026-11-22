import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_magic_words as legacy
import prepare_magic_words_int as prior
import prepare_magic_words_language as magic


class LanguageMagicWordCaptureTests(unittest.TestCase):
    wiki = 'arwiktionary'
    date = '20261001'

    def setUp(self):
        scratch = Path('.tmp')
        scratch.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def response(self):
        return {'query': {'general': {'wikiid': self.wiki, 'lang': 'ar'},
            'magicwords': [
                *[{'name': name, 'case-sensitive': False, 'aliases': [name.upper()]}
                  for name in sorted(legacy.SUPPORTED | legacy.PARSER_FUNCTIONS)],
                {'name': 'int', 'case-sensitive': False, 'aliases': ['INT:', 'داخلي:']},
                {'name': 'language', 'case-sensitive': False,
                 'aliases': ['#LANGUAGE', '#لغة', '＃言語：']},
            ]}}

    def fixture(self, name='capture', data=None):
        root = self.root / name
        root.mkdir()
        namespace = legacy.document({'query': {'general': {'wikiid': self.wiki, 'lang': 'ar'}}})
        (root / 'namespace-siteinfo.raw.json').write_bytes(namespace)
        (root / 'capture.complete.json').write_bytes(legacy.document({
            'wiki': self.wiki, 'date': self.date,
            'artifacts': {'namespace-siteinfo.raw.json': legacy.digest(namespace)}}))
        raw = legacy.document(self.response() if data is None else data)
        def fetch(url):
            return raw, dict(source_url=url, response_url=url, status=200,
                started_utc='2026-10-05T06:00:00+00:00',
                retrieved_utc='2026-10-05T06:00:01+00:00',
                raw_sha256=legacy.digest(raw), raw_bytes=len(raw))
        with patch.object(legacy, 'fetch_response', side_effect=AssertionError('Network forbidden')):
            legacy.capture_snapshot(root, self.wiki, self.date, fetcher=fetch)
        source = root / 'magic-words'
        legacy.derive_snapshot(source, root / legacy.DERIVED_DIRECTORY)
        prior.derive_snapshot(source, root / prior.DERIVED_DIRECTORY)
        return root, root / prior.DERIVED_DIRECTORY

    def contents(self, root):
        return {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in root.iterdir()}

    def derived(self):
        root, source = self.fixture()
        output = root / magic.DERIVED_DIRECTORY
        manifest, _ = magic.derive_snapshot(source, output)
        blobs = {name: legacy.read_regular(output / name) for name in magic.ARTIFACTS}
        return root, source, output, manifest, blobs

    def test_projection_retains_old_rows_and_exact_language_alias_case_flags(self):
        for flag in (False, True):
            data = self.response(); data['query']['magicwords'][-1]['case-sensitive'] = flag
            old, count = prior.render_snapshot(data, self.wiki, self.date, 'ar')
            new, rows = magic.render_snapshot(data, self.wiki, self.date, 'ar')
            self.assertEqual([row for row in new.splitlines() if not row.startswith(b'language\t')], old.splitlines())
            for alias in ('#LANGUAGE', '#لغة', '＃言語：'):
                self.assertIn(('language\t'+str(int(flag))+'\t'+alias+'\n').encode(), new)
            self.assertNotIn(b'language\t0\tlanguage\n', new)
            self.assertEqual(rows, count+3)
            data['query']['magicwords'].reverse()
            self.assertEqual(magic.render_snapshot(data, self.wiki, self.date, 'ar'), (new, rows))

    def test_missing_duplicate_case_flag_and_unsafe_alias_facts_are_rejected(self):
        cases=[]
        data=self.response();data['query']['magicwords'].pop();cases.append(data)
        data=self.response();data['query']['magicwords'].append(copy.deepcopy(data['query']['magicwords'][-1]));cases.append(data)
        for aliases in ([], '', [None], [''], ['bad\talias'], ['bad\nalias'], ['bad\x85alias'], ['x'*1025]):
            data=self.response();data['query']['magicwords'][-1]['aliases']=aliases;cases.append(data)
        for flag in (1,None,'false'):
            data=self.response();data['query']['magicwords'][-1]['case-sensitive']=flag;cases.append(data)
        for i,data in enumerate(cases):
            with self.subTest(case=i),self.assertRaises(ValueError):
                magic.render_snapshot(data,self.wiki,self.date,'ar')

    def test_derivation_preserves_all_prior_generations_and_reuses_exact_capture(self):
        root,source=self.fixture()
        prior_paths=[root/'magic-words',root/legacy.DERIVED_DIRECTORY,source]
        before=[self.contents(p) for p in prior_paths]
        with patch.object(legacy,'fetch_response',side_effect=AssertionError('Network forbidden')):
            manifest,created=magic.derive_snapshot(source,root/magic.DERIVED_DIRECTORY)
            self.assertTrue(created);self.assertEqual(manifest['version'],4)
            self.assertEqual(manifest['profile'],magic.PROFILE)
            self.assertEqual(len(manifest['artifacts']),9)
            self.assertEqual(set(manifest['artifacts']),magic.ARTIFACTS)
            output=root/magic.DERIVED_DIRECTORY;unchanged=self.contents(output)
            self.assertEqual(magic.derive_snapshot(source,output),(manifest,False))
            self.assertEqual(self.contents(output),unchanged)
        for path,contents in zip(prior_paths,before):self.assertEqual(self.contents(path),contents)
        self.assertEqual(magic.selected_snapshot_root(root),output)
        for path in prior_paths:self.assertEqual(magic.validate_snapshot(path),prior.validate_snapshot(path))
        self.assertEqual(magic.capture_artifacts(output,manifest),
                         dict(manifest['artifacts'],**{'magic-words.manifest.json':legacy.digest((output/'magic-words.manifest.json').read_bytes())}))

    def test_rebound_new_output_or_prior_capture_cannot_invent_aliases(self):
        _,_,_,original,blobs=self.derived()
        for target in ('magic-words.tsv',magic.SOURCE_TSV):
            with self.subTest(target=target):
                changed=dict(blobs)
                changed[target]=changed[target].replace(b'INT:',b'INVENTED:')
                manifest=copy.deepcopy(original)
                manifest['artifacts'][target]=legacy.digest(changed[target])
                if target=='magic-words.tsv':
                    manifest['output_sha256']=legacy.digest(changed[target]);manifest['output_bytes']=len(changed[target])
                else:manifest['source_capture']['output_sha256']=legacy.digest(changed[target])
                with self.assertRaises(ValueError):magic.validate_capture(manifest,changed)
        for target in (legacy.SOURCE_TSV,magic.SOURCE_MANIFEST,'magic-words.raw.json'):
            changed=dict(blobs);changed[target]+=b' '
            manifest=copy.deepcopy(original);manifest['artifacts'][target]=legacy.digest(changed[target])
            with self.subTest(target=target),self.assertRaises(ValueError):magic.validate_capture(manifest,changed)

    def test_dependency_identity_time_and_edition_bindings_remain_strict(self):
        _,source,output,original,blobs=self.derived()
        for key,value in [('generator_sha256','0'*64),('dependency_sha256',{}),('source_capture',{}),
                          ('content_language','en'),('derived_utc','2026-10-04T06:00:00+00:00')]:
            manifest=copy.deepcopy(original);manifest[key]=value
            with self.subTest(field=key),self.assertRaises(ValueError):magic.validate_capture(manifest,blobs)
        for wiki,date in [('enwiktionary',self.date),(self.wiki,'20260901')]:
            with self.subTest(wiki=wiki,date=date),self.assertRaises(ValueError):magic.validate_snapshot(output,wiki,date)
        changed=dict(blobs);changed.pop(magic.SOURCE_TSV)
        with self.assertRaises(ValueError):magic.validate_capture(original,changed)
        with self.assertRaisesRegex(ValueError,'authenticated int'):
            magic.derive_snapshot(source.parent/'magic-words',self.root/'invalid')

    def test_new_generation_cannot_fall_back_when_incomplete_symlink_or_wrong_profile(self):
        for kind in ('empty','symlink','int-profile'):
            root,source=self.fixture(kind)
            self.assertEqual(magic.selected_snapshot_root(root),source)
            output=root/magic.DERIVED_DIRECTORY
            if kind=='empty':output.mkdir()
            elif kind=='symlink':output.symlink_to(source.resolve(),target_is_directory=True)
            else:prior.derive_snapshot(root/'magic-words',output)
            with self.subTest(kind=kind),self.assertRaises(ValueError):magic.selected_snapshot_root(root)

    def test_changed_prior_capture_cannot_reuse_a_language_derivation(self):
        root,source=self.fixture('first');output=root/magic.DERIVED_DIRECTORY
        magic.derive_snapshot(source,output)
        data=self.response();data['query']['magicwords'][-1]['aliases'].append('#actual-new')
        _,other=self.fixture('second',data)
        with self.assertRaisesRegex(ValueError,'different int'):magic.derive_snapshot(other,output)

    def test_builder_pins_nine_v4_artifacts_and_retains_legacy_dispatch(self):
        import build_wiktionaries as builder
        root,source,output,manifest,_=self.derived()
        snapshots={'magic-words':output/'magic-words.tsv'}
        self.assertEqual(builder.auxiliary_capture_helper('magic-words',snapshots['magic-words']).__name__,magic.__name__)
        hashes=builder.verified_auxiliary_hashes(snapshots,self.wiki,self.date)
        captures,artifacts=builder.auxiliary_capture_identities(snapshots,self.wiki,self.date)
        self.assertEqual(hashes,{'magic-words':manifest['output_sha256']})
        destination=self.root/'pinned';destination.mkdir()
        pinned=builder.pinned_auxiliary_snapshots(snapshots,hashes,destination,captures,artifacts)
        self.assertEqual(magic.validate_snapshot(pinned['magic-words'],self.wiki,self.date),manifest)
        self.assertEqual({p.name for p in destination.iterdir()},magic.ARTIFACTS|{'magic-words.manifest.json'})
        for name in magic.ARTIFACTS|{'magic-words.manifest.json'}:self.assertEqual((destination/name).read_bytes(),(output/name).read_bytes())
        self.assertEqual(builder.verified_auxiliary_hashes({'magic-words':source/'magic-words.tsv'},self.wiki,self.date),
                         {'magic-words':prior.validate_snapshot(source)['output_sha256']})


if __name__ == '__main__':
    unittest.main()
