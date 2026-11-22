"""Generic-name proof reuse keeps full byte checks and never exposes cached mutable state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
import urllib.parse
from unittest.mock import patch
import build_wiktionaries as b
import prepare_language_names_generic as names
from test_prepare_language_names_generic import ALIASES, TABLES, response


class GenericNamesReplayReuseTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.contract=patch.object(names,'primary_contract',return_value=({'fixture':b'source'},ALIASES,TABLES))
        self.contract.start();self.addCleanup(self.contract.stop)
        b._GENERIC_LANGUAGE_NAMES_REPLAYS.clear();b._GENERIC_LANGUAGE_NAMES_RUNTIME=None
        self.addCleanup(self.clear_cache)
        namespace=self.root/'namespace-registry.tsv'
        namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tcawiktionary\n# dump-date\t20261001\n# content-language\tca\n')
        args=argparse.Namespace(wiki='cawiktionary',date='20261001',namespace_registry=namespace,primary_sources=self.root,
                                output=self.root/'capture',languages=['ca','en'],delay=0,wall_seconds=30)
        def transport(url,timeout):
            query=urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            return 200,{},json.dumps(response(query['uselang'][0]),ensure_ascii=False).encode()
        self.manifest=names.capture(args,transport=transport,sleep=lambda _:None)
        self.path=args.output/'language-names.tsv'

    def clear_cache(self):
        b._GENERIC_LANGUAGE_NAMES_REPLAYS.clear();b._GENERIC_LANGUAGE_NAMES_RUNTIME=None

    def validate(self,path=None,edition='cawiktionary',date='20261001'):
        return b.validated_auxiliary_capture('language-names',path or self.path,edition,date)

    def rewrite_manifest(self,record):
        raw=json.dumps(record,sort_keys=True,ensure_ascii=False).encode()
        self.path.with_name('language-names.manifest.json').write_bytes(raw)
        self.path.with_name(names.COMPLETE).write_text(json.dumps({'schema':names.SCHEMA,'manifest_sha256':hashlib.sha256(raw).hexdigest()}))

    def test_repeat_copy_and_caller_mutation_preserve_exact_proof(self):
        with patch.object(names,'verify',wraps=names.verify) as replay:
            record,artifacts=self.validate();expected=json.loads(json.dumps(record));inventory=dict(artifacts)
            record['artifacts'].clear();record['dependency_sha256'].clear();artifacts.clear()
            self.assertEqual(self.validate(),(expected,inventory))
            copied=self.root/'copied';shutil.copytree(self.path.parent,copied)
            self.assertEqual(self.validate(copied/self.path.name),(expected,inventory))
            self.assertEqual(replay.call_count,2)

    def test_wrong_edition_and_date_still_reject(self):
        self.validate()
        for edition,date in [('enwiktionary','20261001'),('cawiktionary','20261002')]:
            with self.subTest(edition=edition,date=date),self.assertRaisesRegex(ValueError,'edition/date'):
                self.validate(edition=edition,date=date)

    def test_every_authoritative_artifact_is_rehashed_despite_same_size_and_mtime(self):
        _,inventory=self.validate()
        for name in inventory:
            with self.subTest(name=name):
                path=self.path.with_name(name);original=path.read_bytes();st=path.stat()
                changed=bytes([original[0]^1])+original[1:]
                try:
                    path.write_bytes(changed);os.utime(path,ns=(st.st_atime_ns,st.st_mtime_ns))
                    with self.assertRaises((ValueError,UnicodeError)):self.validate()
                finally:
                    path.write_bytes(original);os.utime(path,ns=(st.st_atime_ns,st.st_mtime_ns))
                self.validate()

    def test_coherently_rehashed_semantic_tamper_cannot_enter_cache(self):
        self.validate();before=len(b._GENERIC_LANGUAGE_NAMES_REPLAYS)
        raw=self.path.read_bytes().replace(b'Catalan',b'Changed')
        self.assertNotEqual(raw,self.path.read_bytes())
        self.path.write_bytes(raw);record=json.loads(json.dumps(self.manifest))
        record['artifacts'][self.path.name]={'size':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
        record.update(output_bytes=len(raw),output_sha256=hashlib.sha256(raw).hexdigest())
        self.rewrite_manifest(record)
        for _ in range(2):
            with self.assertRaisesRegex(ValueError,'Rendered rows'):self.validate()
        self.assertEqual(len(b._GENERIC_LANGUAGE_NAMES_REPLAYS),before)

    def test_missing_extra_and_symlink_evidence_reject(self):
        self.validate();path=self.path.with_name('language-names.source-fixture');saved=path.read_bytes()
        path.unlink()
        with self.assertRaises(ValueError):self.validate()
        path.write_bytes(saved)
        extra=self.path.with_name('language-names.unrecorded');extra.write_bytes(b'extra')
        with self.assertRaises(ValueError):self.validate()
        extra.unlink();outside=self.root/'outside';outside.write_bytes(saved);path.unlink();path.symlink_to(outside)
        with self.assertRaises(ValueError):self.validate()

    def test_snapshot_or_capture_directory_symlink_rejects(self):
        self.validate();copied=self.root/'copied';shutil.copytree(self.path.parent,copied)
        link=self.root/'linked';link.symlink_to(copied,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'snapshot path'):self.validate(link/self.path.name)
        self.path.unlink();self.path.symlink_to(copied/self.path.name)
        with self.assertRaisesRegex(ValueError,'snapshot path'):self.validate()

    def test_changed_helper_source_with_stale_loaded_module_rejects(self):
        self.validate();changed=self.root/'changed-helper.py'
        changed.write_bytes(Path(names.__file__).read_bytes()+b'\n# changed producer\n')
        with patch.object(names,'__file__',str(changed)):
            with self.assertRaisesRegex(ValueError,'producer/runtime'):self.validate()

    def test_changed_dependency_with_stale_loaded_module_rejects(self):
        self.validate();deps=self.root/'deps';deps.mkdir()
        for name in ('prepare_file_metadata.py','download_wiktionaries.py'):
            source=Path(names.evidence.__file__).with_name(name);shutil.copyfile(source,deps/name)
        with (deps/'download_wiktionaries.py').open('ab') as stream:stream.write(b'\n# changed dependency\n')
        with patch.object(names.evidence,'__file__',str(deps/'prepare_file_metadata.py')):
            with self.assertRaisesRegex(ValueError,'producer/runtime'):self.validate()

    def test_runtime_config_and_function_changes_reject_without_using_old_proof(self):
        self.validate()
        with patch.dict(names.SOURCE_PINS,{'unreviewed':'0'*64}):
            with self.assertRaisesRegex(ValueError,'producer/runtime'):self.validate()
        with patch.object(names,'render',lambda *args:b'wrong'):
            with self.assertRaisesRegex(ValueError,'producer/runtime'):self.validate()
        code=names.render.__code__
        try:
            names.render.__code__=(lambda *args:b'wrong').__code__
            with self.assertRaisesRegex(ValueError,'producer/runtime'):self.validate()
        finally:names.render.__code__=code
        self.validate()

    def test_cache_is_bounded_and_evicted_capture_revalidates(self):
        original=json.loads(json.dumps(self.manifest))
        for index in range(34):
            record=json.loads(json.dumps(original));record['fixture_generation']=index
            self.rewrite_manifest(record);self.validate()
            self.assertLessEqual(len(b._GENERIC_LANGUAGE_NAMES_REPLAYS),32)
        self.rewrite_manifest(original)
        self.assertEqual(self.validate()[0],original)

    def test_actual_builder_hash_identity_and_pinning_roundtrip(self):
        snapshots={'language-names':self.path}
        hashes=b.verified_auxiliary_hashes(snapshots,'cawiktionary','20261001')
        manifests,artifacts=b.auxiliary_capture_identities(snapshots,'cawiktionary','20261001')
        pinned=b.pinned_auxiliary_snapshots(snapshots,hashes,self.root/'pins',manifests,artifacts)
        self.assertEqual(b.verified_auxiliary_hashes(pinned,'cawiktionary','20261001'),hashes)
        self.assertEqual(b.auxiliary_capture_identities(pinned,'cawiktionary','20261001'),(manifests,artifacts))


if __name__=='__main__':unittest.main()
