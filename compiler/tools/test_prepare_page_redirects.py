import gzip
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_page_redirects as p
import build_wiktionaries as b
import extraction_cache as cache


class PageRedirectsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.downloads = self.root / 'data/dumps'
        self.folder = self.downloads / 'testwiktionary/20261001'
        self.folder.mkdir(parents=True)
        self.workspace = self.root / 'work'
        self.name = 'testwiktionary-20261001-redirect.sql.gz'
        self.sql = self.folder / self.name

    def fixture(self, records=(), tail=b''):
        def quote(v):
            if v is None:return b'NULL'
            if type(v) is int:return str(v).encode()
            if isinstance(v,str):v=v.encode()
            return b"'" + v.replace(b'\\',b'\\\\').replace(b"'",b"\\'").replace(b'\n',b'\\n').replace(b'\0',b'\\0') + b"'"
        raw = b'CREATE TABLE `redirect` (\n'
        raw += b''.join(b'  `' + name.encode() + b'` text,\n' for name in ('rd_from','rd_namespace','rd_title','rd_interwiki','rd_fragment'))
        raw += b') ENGINE=InnoDB;\n'
        if records:
            raw += b'INSERT INTO `redirect` VALUES ' + b','.join(b'(' + b','.join(quote(v) for v in row) + b')' for row in records) + b';\n'
        raw += tail
        self.sql.write_bytes(gzip.compress(raw,mtime=0))
        return [dict(wiki='testwiktionary',date='20261001',name=self.name,
                     url='https://dumps.wikimedia.org/testwiktionary/20261001/'+self.name,
                     size=self.sql.stat().st_size,sha1=hashlib.sha1(self.sql.read_bytes()).hexdigest())]

    def test_unsorted_sql_exact_fragments_nulls_and_cache_round_trip(self):
        items=self.fixture([(9,0,"O'Brien",None,'e\u0301 &nsbp;'),(2,110,'Target_name','w','A_B')])
        identity=p.source_identity(items,self.downloads)
        output=p.prepare_from_dumps(items,self.downloads,self.workspace,identity)
        raw=output.read_bytes()
        self.assertEqual(raw,p.header(identity)+p.wire_row((2,110,b'Target_name',b'w',b'A_B'))+
                         p.wire_row((9,0,b"O'Brien",b'','e\u0301 &nsbp;'.encode()))+b'# end\t2\n')
        before=output.stat().st_mtime_ns
        self.assertEqual(p.prepare_from_dumps(items,self.downloads,self.workspace,identity),output)
        self.assertEqual(output.stat().st_mtime_ns,before)
        self.assertEqual(p.validate_wire(output,identity)['row_count'],2)

    def test_empty_table_is_complete_but_missing_schema_is_not(self):
        items=self.fixture()
        output=p.prepare_from_dumps(items,self.downloads,self.workspace)
        self.assertEqual(p.validate_wire(output,p.source_identity(items,self.downloads))['row_count'],0)
        self.sql.write_bytes(gzip.compress(b'-- no schema\n',mtime=0))
        items[0].update(size=self.sql.stat().st_size,sha1=hashlib.sha1(self.sql.read_bytes()).hexdigest())
        with self.assertRaises(ValueError):p.prepare_from_dumps(items,self.downloads,self.root/'bad')

    def test_duplicate_invalid_utf8_and_incomplete_sql_fail_without_publication(self):
        cases=([(1,0,'a','',''),(1,0,'b','','')],[(1,0,b'\xff','','')])
        for i,records in enumerate(cases):
            with self.subTest(case=i):
                items=self.fixture(records)
                with self.assertRaises((ValueError,UnicodeError)):p.prepare_from_dumps(items,self.downloads,self.root/str(i))
                self.assertFalse((self.root/str(i)/'derived-page-redirects/page-redirects.tsv').exists())
        items=self.fixture(tail=b"INSERT INTO `redirect` VALUES (1,0,'a','',''),\n")
        with self.assertRaises(ValueError):p.prepare_from_dumps(items,self.downloads,self.root/'truncated')

    def test_wire_rejects_wrong_identity_footer_order_and_extra_bytes(self):
        items=self.fixture([(1,0,'a','','')]);identity=p.source_identity(items,self.downloads)
        output=p.prepare_from_dumps(items,self.downloads,self.workspace);raw=output.read_bytes()
        changed=[raw.replace(b'# end\t1',b'# end\t2'),raw+b'x',
                 raw.replace(b'# wiki\ttestwiktionary',b'# wiki\totherwiktionary'),
                 raw.replace(b'1\t0\t61\t\t\n',b'01\t0\t61\t\t\n')]
        for data in changed:
            with self.subTest(data=data):
                output.write_bytes(data)
                with self.assertRaises(ValueError):p.validate_wire(output,identity)

    def test_changed_sql_and_symlink_input_are_rejected(self):
        items=self.fixture([(1,0,'a','','')]);identity=p.source_identity(items,self.downloads)
        changed=self.fixture([(1,0,'a','','different')])
        with self.assertRaises(ValueError):p.prepare_from_dumps(changed,self.downloads,self.workspace,identity)
        original=self.sql.with_suffix('.saved');self.sql.rename(original);self.sql.symlink_to(original)
        with self.assertRaises(ValueError):p.source_identity(changed,self.downloads)

    def test_xml_only_identity_and_controller_default_root_compatibility(self):
        items=self.fixture([(1,0,'a','','')])
        tool=self.root/'zig';tool.write_bytes(b'tool')
        with patch.object(b.shutil,'which',return_value=str(tool)),patch.object(b,'source_fingerprint',return_value='source'),patch.object(b,'PROJECT',self.root):
            explicit=b.build_input_identity(items,'zig',{},None,None,downloads=self.downloads)
            implicit=b.build_input_identity(items,'zig',{},None,None)
            self.assertEqual(explicit,implicit)
            self.assertEqual(explicit['derived_page_redirects']['sql_sha256'],p.sha256(self.sql))
            xml=[dict(items[0],name='custom.xml')]
            old=b.build_input_identity(xml,'zig',{},None,None)
            self.assertNotIn('derived_page_redirects',old)
            self.assertIsNone(p.prepare_from_dumps(xml,self.downloads,self.workspace))
            changed=self.fixture([(1,0,'a','','other')])
            fresh=b.build_input_identity(changed,'zig',{},None,None)
            with self.assertRaises(ValueError):b.require_build_identity(explicit,fresh)

    def test_pipeline_sidecar_and_expander_reuse_are_bound_separately_from_aux(self):
        snapshots={'namespace-registry':Path('ns.tsv')}
        args=b.pipeline_snapshot_args(Path('languages.tsv'),snapshots,page_redirects_snapshot=Path('redirects.tsv'))
        self.assertIn('--page-redirects-snapshot',args)
        self.assertEqual(snapshots,{'namespace-registry':Path('ns.tsv')})
        root=self.root/'expander';data=root/'.bundle-expander';data.mkdir(parents=True)
        (root/'.incomplete').write_text('expander ready')
        for name in ('page-index.tsv','dict-bundle-expander','namespace-registry.tsv'):(data/name).write_text('x')
        side=data/'page-redirects.tsv';side.write_text('a')
        expected=p.sha256(side)
        self.assertTrue(b.expander_ready(root,page_redirects_sha=expected))
        self.assertFalse(b.expander_ready(root))
        side.write_text('b')
        self.assertFalse(b.expander_ready(root,page_redirects_sha=expected))

    def test_extraction_identity_changes_with_sidecar_without_touching_old_cache(self):
        with patch.object(cache,'tool_identity',return_value={'tool':'stub'}),patch.object(cache,'unicode_case_identity',return_value={}):
            before=cache.identity(Path('extractor'),'a'*64,'b'*64,'c'*64,page_redirects_sha256='d'*64)
            after=cache.identity(Path('extractor'),'a'*64,'b'*64,'c'*64,page_redirects_sha256='e'*64)
            self.assertNotEqual(before,after)
            self.assertEqual(before['page_redirects_sha256'],'d'*64)

    def test_partial_derived_pair_is_reconstructed_and_symlink_destination_refused(self):
        items=self.fixture([(1,0,'a','','')])
        output=p.prepare_from_dumps(items,self.downloads,self.workspace)
        expected=output.read_bytes()
        output.with_name('page-redirects.provenance.json').unlink()
        self.assertEqual(p.prepare_from_dumps(items,self.downloads,self.workspace).read_bytes(),expected)
        output.unlink();output.symlink_to(self.sql)
        with self.assertRaises(ValueError):p.prepare_from_dumps(items,self.downloads,self.workspace)


if __name__ == '__main__':
    unittest.main()
