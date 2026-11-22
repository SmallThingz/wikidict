"""Caller replay regressions: provenance, mutation, and independent boundaries."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import urllib.parse
from unittest.mock import patch

import build_wiktionaries as b
from test_build_wiktionaries import write_language_messages_fixture, write_wikibase_capture_fixture


@contextlib.contextmanager
def capture_fixture(kind):
    with tempfile.TemporaryDirectory() as temporary:
        root=Path(temporary)
        if kind=='entities':
            import prepare_wikibase_entities as helper
            snapshots=write_wikibase_capture_fixture(root/'capture')
            yield helper,helper,snapshots,'arwiktionary'
        elif kind=='messages':
            import prepare_language_messages as helper
            snapshots=write_language_messages_fixture(root/'capture')
            yield helper,helper,snapshots,'arwiktionary'
        elif kind=='messages-v2':
            import prepare_language_messages_v2 as helper
            from test_prepare_language_messages_v2 import MessageV2Test, WIKI
            fixture=MessageV2Test()
            fixture.setUp()
            try:
                args,_,_=fixture.collect(33,languages=['bn','en'])
                snapshots={name:args.output/(name+'.tsv') for name in helper.KINDS}
                yield helper,helper,snapshots,WIKI
            finally:
                fixture.doCleanups()
        elif kind=='date-numbering':
            import prepare_date_numbering as helper
            from test_prepare_date_numbering import CaptureTest, WIKI
            fixture=CaptureTest()
            fixture.setUp()
            try:
                fixture.collect()
                yield helper,helper,{'date-numbering':fixture.args.output/helper.SNAPSHOT},WIKI
            finally:
                fixture.doCleanups()
        elif kind=='site-info':
            import prepare_site_info as helper
            from test_prepare_site_info import SiteInfoCaptureTests
            fixture=SiteInfoCaptureTests()
            fixture.setUp()
            try:
                capture,_=fixture.collect()
                yield helper,helper,{'site-info':capture/helper.SNAPSHOT},'testwiktionary'
            finally:
                fixture.doCleanups()
        elif kind=='translate':
            import prepare_language_names_translate as helper
            from test_prepare_language_names_translate import TABLES,response
            namespace=root/'namespace-registry.tsv'
            namespace.write_text('# wikidict-namespace-registry-v1\n# wiki\tfrwiktionary\n'
                                 '# dump-date\t20261001\n# content-language\tfr\n')
            args=argparse.Namespace(wiki='frwiktionary',date='20261001',
                namespace_registry=namespace,primary_sources=root,output=root/'capture',
                languages=['en','fr'],delay=0,wall_seconds=60,core=helper.CORE,
                extra_direction_codes=[])
            def transport(url,timeout):
                query=urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
                return 200,{},json.dumps(response(query['uselang'][0])).encode()
            with patch.object(helper._base,'primary_contract',
                              return_value=({'fixture':b'pinned fixture'},{},TABLES)):
                helper.capture(args,transport=transport,sleep=lambda _:None)
                yield helper,helper._base,{'language-names':args.output/'language-names.tsv'},'frwiktionary'
        else:
            raise AssertionError(kind)


class AuxiliaryCaptureReplayTests(unittest.TestCase):
    kinds=('entities','messages','messages-v2','date-numbering','site-info','translate')

    def test_one_complete_replay_returns_exact_record_and_inventory(self):
        for kind in self.kinds:
            with self.subTest(kind=kind),capture_fixture(kind) as (helper,owner,snapshots,wiki):
                for name,path in snapshots.items():
                    expected_record=helper.validate_snapshot(path,wiki,'20261001')
                    expected_inventory=helper.capture_artifacts(path,expected_record)
                    with patch.object(owner,'validate_snapshot',wraps=owner.validate_snapshot) as replay:
                        actual=b.validated_auxiliary_capture(name,path,wiki,'20261001')
                    self.assertEqual(replay.call_count,1)
                    self.assertEqual(actual,(expected_record,expected_inventory))

    def test_each_independent_boundary_replays_and_returns_unshared_records(self):
        for kind in self.kinds:
            with self.subTest(kind=kind),capture_fixture(kind) as (_,owner,snapshots,wiki):
                name,path=next(iter(snapshots.items()))
                with patch.object(owner,'validate_snapshot',wraps=owner.validate_snapshot) as replay:
                    first=b.validated_auxiliary_capture(name,path,wiki,'20261001')
                    first[0]['wiki']='mutated-result'
                    first[1].clear()
                    second=b.validated_auxiliary_capture(name,path,wiki,'20261001')
                self.assertEqual(replay.call_count,2)
                self.assertEqual(second[0]['wiki'],wiki)
                self.assertIn(path.name,second[1])

    def test_requested_edition_and_date_remain_mandatory(self):
        for kind in self.kinds:
            with self.subTest(kind=kind),capture_fixture(kind) as (_,_,snapshots,wiki):
                name,path=next(iter(snapshots.items()))
                for requested_wiki,date in [('otherwiktionary','20261001'),(wiki,'19990101')]:
                    with self.subTest(wiki=requested_wiki,date=date),self.assertRaises(ValueError):
                        b.validated_auxiliary_capture(name,path,requested_wiki,date)

    def test_mutated_raw_tsv_namespace_and_manifest_fail_after_prior_success(self):
        for kind in self.kinds:
            for mutation in ('raw','tsv','namespace','manifest'):
                with self.subTest(kind=kind,mutation=mutation),capture_fixture(kind) as (_,_,snapshots,wiki):
                    name,path=next(iter(snapshots.items()))
                    _,inventory=b.validated_auxiliary_capture(name,path,wiki,'20261001')
                    if mutation=='raw':
                        target=next(path.with_name(n) for n in inventory
                                    if n.endswith('.raw.json') and 'namespace' not in n)
                    elif mutation=='tsv':
                        target=path
                    elif mutation=='namespace':
                        target=next(path.with_name(n) for n in inventory
                                    if 'namespace' in n and (n.endswith('.tsv') or n.endswith('.raw.json')))
                    else:
                        target=path.with_name(b.auxiliary_manifest_filename(name,path))
                    raw=target.read_bytes()
                    target.chmod(0o644)
                    if mutation=='manifest':
                        record=json.loads(raw);record['wiki']='otherwiktionary'
                        target.write_text(json.dumps(record))
                    else:
                        target.write_bytes(raw+b' ')
                    with self.assertRaises((ValueError,OSError)):
                        b.validated_auxiliary_capture(name,path,wiki,'20261001')

    def test_symlink_root_snapshot_manifest_and_raw_are_rejected(self):
        for kind in self.kinds:
            for location in ('root','snapshot','manifest','raw'):
                with self.subTest(kind=kind,location=location),capture_fixture(kind) as (_,_,snapshots,wiki):
                    name,path=next(iter(snapshots.items()))
                    _,inventory=b.validated_auxiliary_capture(name,path,wiki,'20261001')
                    if location=='root':
                        link=path.parent.with_name(path.parent.name+'-link')
                        link.symlink_to(path.parent,target_is_directory=True)
                        path=link/path.name
                    else:
                        target=path if location=='snapshot' else (
                            path.with_name(b.auxiliary_manifest_filename(name,path)) if location=='manifest' else
                            next(path.with_name(n) for n in inventory if n.endswith('.raw.json') and 'namespace' not in n))
                        backing=target.with_name(target.name+'.backing')
                        target.rename(backing);target.symlink_to(backing)
                    with self.assertRaises((ValueError,OSError)):
                        b.validated_auxiliary_capture(name,path,wiki,'20261001')

    def test_preread_exact_manifest_bytes_are_bound_to_replay_inventory(self):
        import prepare_wikibase_entities as helper
        with capture_fixture('entities') as (_,_,snapshots,wiki):
            name,path=next(iter(snapshots.items()))
            manifest=path.with_name(b.auxiliary_manifest_filename(name,path))
            original=helper.capture_artifacts
            def changed_after_preread(snapshot,record):
                manifest.write_bytes(manifest.read_bytes()+b' ')
                return original(snapshot,record)
            with patch.object(helper,'capture_artifacts',side_effect=changed_after_preread):
                with self.assertRaisesRegex(ValueError,'manifest changed during validation'):
                    b.validated_auxiliary_capture(name,path,wiki,'20261001')

    def test_paired_manifest_drift_is_rejected(self):
        for kind in ('entities','messages','messages-v2'):
            with self.subTest(kind=kind),capture_fixture(kind) as (_,_,snapshots,wiki):
                name,path=next(iter(snapshots.items()))
                b.validated_auxiliary_capture(name,path,wiki,'20261001')
                other_name=next(n for n in snapshots if n!=name)
                other=path.with_name(b.auxiliary_manifest_filename(other_name,snapshots[other_name]))
                record=json.loads(other.read_bytes());record['date']='19990101'
                other.write_text(json.dumps(record))
                with self.assertRaises((ValueError,OSError)):
                    b.validated_auxiliary_capture(name,path,wiki,'20261001')


if __name__=='__main__':
    unittest.main()
