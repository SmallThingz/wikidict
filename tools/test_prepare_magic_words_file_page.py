import copy
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import prepare_magic_words_file_page as magic
import prepare_magic_words_category as prior
import test_prepare_magic_words_category as old


class FilePageAliasTests(unittest.TestCase):
    wiki='arwiktionary'
    date='20261001'
    setUp=old.IsbnMagicWordsTests.setUp
    contents=old.IsbnMagicWordsTests.contents
    category=old.IsbnMagicWordsTests.category

    def response(self):
        data=old.IsbnMagicWordsTests.response(self)
        data['query']['magicwords'].extend([
            {'name':'filepath','aliases':['FILEPATH','مسار_ملف'],'case-sensitive':False},
            {'name':'pagesize','aliases':['PAGESIZE','حجم_صفحة'],'case-sensitive':True}])
        return data

    def test_only_captured_file_page_aliases_are_added_with_exact_flags(self):
        data=self.response()
        for version,renderer in ((7,prior.render_snapshot),(9,prior.render_isbn_snapshot)):
            original,count=renderer(data,self.wiki,self.date,'ar')
            new,total=magic.render_snapshot(data,self.wiki,self.date,'ar',version)
            self.assertEqual([row for row in new.splitlines()if row.split(b'\t')[0]not in (b'filepath',b'pagesize')],original.splitlines())
            self.assertEqual(total,count+4)
            self.assertIn(b'filepath\t0\tFILEPATH\n',new)
            self.assertIn(b'pagesize\t1\tPAGESIZE\n',new)
            without=copy.deepcopy(data);without['query']['magicwords']=[x for x in without['query']['magicwords']if x['name']not in magic.WORDS]
            self.assertEqual(magic.render_snapshot(without,self.wiki,self.date,'ar',version),(original,count))

    def test_duplicate_or_unsafe_alias_authority_is_refused(self):
        for kind in ('record','alias','flag','control','empty'):
            data=self.response();row=data['query']['magicwords'][-1]
            if kind=='record':data['query']['magicwords'].append(copy.deepcopy(row))
            elif kind=='alias':row['aliases'].append(row['aliases'][0])
            elif kind=='flag':row['case-sensitive']=1
            elif kind=='control':row['aliases']=['bad\nvalue']
            else:row['aliases']=[]
            with self.subTest(kind=kind),self.assertRaises(ValueError):magic.render_snapshot(data,self.wiki,self.date,'ar',7)

    def test_offline_derivation_preserves_v7_and_v9_sources_and_normal_selection(self):
        import build_wiktionaries as builder
        for version in (7,9):
            root,source=self.category('capture'+str(version))
            if version==9:
                output=root/prior.ISBN_DIRECTORY;prior.derive_snapshot(source,output,include_isbn=True);source=output
            before=self.contents(source);destination=root/magic.DERIVED_DIRECTORY
            with mock.patch.object(magic.legacy,'fetch_response',side_effect=AssertionError('No network')):
                manifest,created=magic.derive_snapshot(source,destination)
                self.assertTrue(created);self.assertEqual(manifest['version'],10)
                self.assertEqual(self.contents(source),before)
                self.assertEqual((destination/magic.SOURCE_TSV).read_bytes(),before['magic-words.tsv'][0])
                self.assertEqual(magic.derive_snapshot(source,destination),(manifest,False))
                self.assertEqual(magic.selected_snapshot_root(root),destination)
                path=destination/'magic-words.tsv'
                self.assertIs(builder.auxiliary_capture_helper('magic-words',path),magic)
                record,artifacts=builder.validated_auxiliary_capture('magic-words',path,self.wiki,self.date)
                self.assertEqual(record,manifest);self.assertIn(magic.SOURCE_MANIFEST,artifacts)
            output=destination/'magic-words.tsv';output.chmod(0o644);output.write_bytes(b'changed')
            with self.assertRaises(ValueError):magic.selected_snapshot_root(root)
            self.assertEqual(prior.validate_snapshot(source)['version'],version)

    def test_incomplete_preferred_generation_never_falls_back(self):
        root,source=self.category('incomplete')
        (root/magic.DERIVED_DIRECTORY).mkdir()
        with self.assertRaises((ValueError,OSError)):magic.selected_snapshot_root(root)
        self.assertEqual(prior.validate_snapshot(source)['version'],7)


class ParserFunctionStagingTests(unittest.TestCase):
    def test_real_facts_discovery_namespace_site_join_and_dedicated_staging(self):
        import build_wiktionaries as builder
        import prepare_parser_function_facts as facts
        import test_prepare_parser_function_facts as fixtures
        with tempfile.TemporaryDirectory()as tmp:
            root=Path(tmp)
            namespace,site,triples=fixtures.ParserFunctionFactsTests().inputs(root)
            generation=root/'captures'/facts.DIRECTORY
            record=facts.derive(namespace,site,triples,generation,fixtures.WIKI,fixtures.DATE)
            snapshots=builder.discover_auxiliary_generation(root/'captures',facts.DIRECTORY,('parser-function-facts',),fixtures.WIKI,fixtures.DATE)
            self.assertEqual(snapshots,{'parser-function-facts':generation/facts.OUTPUT})
            actual=builder.validated_auxiliary_capture
            def selected(name,path,*args,**kwargs):
                return actual(name,path,*args,**kwargs)if name=='parser-function-facts'else None
            # The site/namespace fixtures stand in for independently qualified
            # normal providers; the new facts helper and both joins are real.
            snapshots.update({'namespace-registry':namespace,'site-info':site})
            with mock.patch.object(builder,'validated_auxiliary_capture',side_effect=selected):
                hashes=builder.verified_auxiliary_hashes(snapshots,fixtures.WIKI,fixtures.DATE)
                changed=root/'changed-site.json';changed.write_bytes(site.read_bytes()+b' ')
                with self.assertRaises(ValueError):builder.verified_auxiliary_hashes(dict(snapshots,**{'site-info':changed}),fixtures.WIKI,fixtures.DATE)
            pinned=builder.pinned_auxiliary_snapshots({'parser-function-facts':generation/facts.OUTPUT},
                    {'parser-function-facts':hashes['parser-function-facts']},root/'staged')
            self.assertEqual(pinned['parser-function-facts'],root/'staged'/'parser-function-facts'/facts.OUTPUT)
            self.assertEqual(facts.verify(pinned['parser-function-facts'].parent),record)
            self.assertEqual(builder.auxiliary_snapshot_args(pinned),['--parser-function-facts-snapshot',str(pinned['parser-function-facts'])])
            (generation/'unexpected').write_bytes(b'no')
            with self.assertRaises(ValueError):builder.discover_auxiliary_generation(root/'captures',facts.DIRECTORY,('parser-function-facts',),fixtures.WIKI,fixtures.DATE)


if __name__=='__main__':unittest.main()
