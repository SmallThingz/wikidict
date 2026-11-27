"""Full-edition provisioning through the real collector/replayer; HTTP is synthetic."""
from contextlib import contextmanager
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import build_wiktionaries as builder
import prepare_language_messages as legacy
import prepare_language_messages_v2 as messages
import test_build_wiktionaries as builder_tests
import test_prepare_language_messages_v2 as capture_tests


class CompleteEditionProvisioningTests(unittest.TestCase):
    def setUp(self):
        self.outer=builder_tests.LoopMessageSelectionTests()
        self.outer.setUp()
        self.addCleanup(self.outer.doCleanups)
        self.authority=capture_tests.CompleteMessageTest()
        self.authority.setUp()
        self.addCleanup(self.authority.doCleanups)
        self.root=self.outer.root
        self.old=self.root/'language-messages'
        args=SimpleNamespace(wiki=self.outer.wiki,date=self.outer.date,
            namespace_registry=self.outer.namespace,output=self.old,
            languages=['bn','en'],messages=['show'],delay=0,wall_seconds=60)
        legacy.capture(args,transport=capture_tests.Transport(),sleep=lambda _:None)
        self.old_bytes={p.name:p.read_bytes() for p in self.old.iterdir()}
        self.transport=capture_tests.CompleteTransport()
        real_capture=messages.capture_complete
        def collect(args,transport=None,sleep=None):
            return real_capture(args,transport=transport or self.transport,sleep=sleep or (lambda _:None))
        self.capture_patch=patch.object(messages,'capture_complete',side_effect=collect)
        self.capture=self.capture_patch.start()
        self.addCleanup(self.capture_patch.stop)

    def resolve(self,network='offline',overrides=None,sources=True,**kwargs):
        if sources:kwargs['language_message_api_sources']=self.authority.sources
        # Figure acquisition is an independent existing route. Exercise the
        # real edition resolver, messages, final authority validation and hashes.
        with patch.object(builder,'PROJECT',self.outer.project), \
             patch.object(builder,'resolve_figure_snapshot_options',return_value={}):
            result=builder.resolve_edition_snapshot_options(self.outer.manifest,self.outer.groups,
                self.outer.downloads,overrides,workspace=self.outer.project,
                metadata_network=network,**kwargs)
        return result[(self.outer.wiki,self.outer.date)]['auxiliary_snapshots']

    @contextmanager
    def staged_selection(self,snapshots,*,exact=False):
        records={
            name:dict(path=str(path.relative_to(self.outer.project)),bytes=path.stat().st_size,
                      sha256=builder.sha256_file(path))
            for name,path in snapshots.items()
        }
        capture_root=str(self.root.relative_to(self.outer.project))
        with TemporaryDirectory(dir=self.outer.project) as view:
            overrides,root=builder.materialize_snapshot_selection(
                self.outer.project,Path(view),records,capture_root,exact_capture=exact)
            self.assertIsNotNone(root)
            yield overrides,root,(self.outer.wiki,str(root.relative_to(self.outer.project)))

    def assert_old_unchanged(self):
        self.assertEqual(self.old_bytes,{p.name:p.read_bytes() for p in self.old.iterdir()})

    def test_offline_without_pair_does_not_inspect_unused_namespace(self):
        namespace=self.root/'namespace-alias.tsv'
        namespace.symlink_to(self.outer.namespace)
        for selected in ({}, {'interface-messages': self.old/'interface-messages.tsv',
                              'language-fallbacks': self.old/'language-fallbacks.tsv'}):
            self.assertEqual({},builder.resolve_language_message_snapshot_options(
                self.root,self.outer.wiki,self.outer.date,namespace,selected,{},
                metadata_network='offline'))
        self.capture.assert_not_called()

    def test_online_default_replaces_one_key_selection_with_complete_pair_once(self):
        selected=self.resolve('allow')
        pair=self.root/'language-messages-complete-v1'
        self.assertEqual(selected['interface-messages'],pair/'interface-messages.tsv')
        self.assertEqual(selected['language-fallbacks'],pair/'language-fallbacks.tsv')
        rows=selected['interface-messages'].read_text()
        for language in ('bn','en'):
            self.assertIn(language+'\tshow\tV\tlocal '+language,rows)
            self.assertIn(language+'\thide\tV\texact hide',rows)
        requests=[{k:v[0] for k,v in parse_qs(urlsplit(url).query).items()} for url in self.transport.calls]
        starts=[q['amlang'] for q in requests if q.get('ammessages')=='*' and 'amfrom' not in q]
        self.assertCountEqual(starts,['bn','en'])
        record=messages.verify_complete(pair)['interface-messages']
        self.assertIsNone(record['dump_date'])
        self.assertEqual(record['temporal_scope'],'current-api-sequential-observations')
        self.assertFalse(record['corpus_query_closure_proven'])
        calls=list(self.transport.calls)
        self.assertEqual(selected,self.resolve('allow',sources=False))
        self.assertEqual(self.capture.call_count,1)
        self.assertEqual(self.transport.calls,calls)
        self.assert_old_unchanged()

    def test_offline_keeps_and_validates_selected_limited_capture_without_http(self):
        selected=self.resolve()
        self.assertEqual(selected['interface-messages'],self.old/'interface-messages.tsv')
        self.capture.assert_not_called()
        self.assertFalse((self.root/'language-messages-complete-v1').exists())
        self.assert_old_unchanged()

    def test_offline_replays_complete_generation_without_source_bundle_or_http(self):
        selected=self.resolve('allow');calls=list(self.transport.calls)
        self.capture.reset_mock()
        self.assertEqual(selected,self.resolve('offline',sources=False))
        self.capture.assert_not_called()
        self.assertEqual(self.transport.calls,calls)

    def test_default_complete_pair_with_unobserved_hide_is_rejected_without_recapture(self):
        generation=self.root/'language-messages-complete-v1'
        self.authority.collect(output=generation,namespace_registry=self.outer.namespace,
            messages=messages.planned_capture_messages(['show']))
        self.capture.reset_mock()
        rows=(generation/'interface-messages.tsv').read_text().splitlines()
        for language in ('bn','en'):
            self.assertFalse(any(row.startswith(language+'\thide\t') for row in rows))
        for name in ('language-messages-complete-v1','language-messages-loop-v1'):
            target=self.root/name
            if generation!=target:
                generation.rename(target)
                generation=target
            for network in ('offline','allow'):
                with self.subTest(generation=name,network=network), self.assertRaisesRegex(
                        ValueError,r'Complete message pair lacks required observations: bn/hide, en/hide'):
                    self.resolve(network)
        self.capture.assert_not_called()
        self.assertEqual(self.transport.calls,[])
        self.assert_old_unchanged()

    def test_explicit_missing_hide_row_counts_as_an_observation(self):
        def mark_missing_for_english(query,response):
            if query.get('amlang')=='en' and query.get('ammessages')!='*':
                for row in response['query']['allmessages']:
                    if row['name']=='hide':
                        del row['content']
                        row['missing']=True
        self.transport.mutate=mark_missing_for_english
        selected=self.resolve('allow')
        rows=selected['interface-messages'].read_text().splitlines()
        self.assertIn('en\thide\tM',rows)
        self.assertIn('bn\thide\tV\texact hide',rows)
        calls=list(self.transport.calls)
        self.assertEqual(self.resolve(sources=False),selected)
        self.assertEqual(self.capture.call_count,1)
        self.assertEqual(self.transport.calls,calls)

    def test_exact_staged_selection_with_no_message_roles_does_not_acquire(self):
        stored={name:path for name,path in self.resolve().items() if name not in messages.KINDS}
        with self.staged_selection(stored,exact=True) as (overrides,root,staged):
            selected=self.resolve('allow',overrides,exact_snapshot_selection=True,_staged_capture=staged)
            self.assertEqual(selected,overrides)
            self.assertFalse((root/'language-messages-complete-v1').exists())
        self.capture.assert_not_called()
        self.assertEqual(self.transport.calls,[])
        persistent=self.outer.downloads/self.outer.wiki/self.outer.date
        self.assertFalse((persistent/'language-messages-complete-v1').exists())

    def test_nonexact_staged_selection_reuses_persistent_capture_after_restage(self):
        stored={name:path for name,path in self.resolve().items() if name not in messages.KINDS}
        generation=self.outer.downloads/self.outer.wiki/self.outer.date/'language-messages-complete-v1'
        expected={name:generation/(name+'.tsv') for name in messages.KINDS}
        with self.staged_selection(stored) as (overrides,root,staged):
            self.assertEqual(self.resolve('allow',overrides,_staged_capture=staged),overrides | expected)
            self.assertFalse((root/generation.name).exists())
        self.assertFalse(root.exists())
        self.assertTrue((generation/messages.COMPLETE).is_file())
        calls=list(self.transport.calls)
        with self.staged_selection(stored) as (overrides,new_root,staged):
            self.assertNotEqual(new_root,root)
            for network in ('offline','allow'):
                with self.subTest(network=network):
                    selected=self.resolve(network,overrides,sources=False,_staged_capture=staged)
                    self.assertEqual(selected,overrides | expected)
            self.assertFalse((new_root/generation.name).exists())
        self.assertEqual(self.capture.call_count,1)
        self.assertEqual(self.transport.calls,calls)

    def test_online_missing_reviewed_source_fails_before_capture(self):
        with self.assertRaisesRegex(ValueError,'language-message-api-sources'):
            self.resolve('allow',sources=False)
        self.capture.assert_not_called()
        self.assertFalse((self.root/'language-messages-complete-v1').exists())
        self.assert_old_unchanged()

    def test_explicit_partial_or_full_selection_never_triggers_capture(self):
        for names in [('interface-messages',),('interface-messages','language-fallbacks')]:
            with self.subTest(names=names):
                overrides={name:self.old/(name+'.tsv') for name in names}
                selected=self.resolve('allow',overrides,sources=False)
                for name,path in overrides.items():self.assertEqual(selected[name],path)
        self.capture.assert_not_called()
        self.assert_old_unchanged()

    def test_explicit_corruption_is_rejected_without_recapture(self):
        overrides={name:self.old/(name+'.tsv') for name in messages.KINDS}
        overrides['interface-messages'].write_bytes(b'corrupt')
        with self.assertRaises(ValueError):self.resolve('allow',overrides)
        self.capture.assert_not_called()

    def test_corrupt_complete_generation_is_not_replaced_online_or_offline(self):
        selected=self.resolve('allow')
        selected['interface-messages'].write_bytes(b'corrupt')
        self.capture.reset_mock()
        for network in ('offline','allow'):
            with self.subTest(network=network),self.assertRaises(ValueError):self.resolve(network)
        self.capture.assert_not_called()
        self.assert_old_unchanged()

    def test_current_api_core_change_preserves_failure_and_never_falls_back(self):
        self.transport.mutate=lambda query,value:value['query']['general'].update({'git-hash':'0'*40})
        with self.assertRaisesRegex(ValueError,'API source revision'):self.resolve('allow')
        generation=self.root/'language-messages-complete-v1'
        self.assertTrue((generation/'language-messages.failure.json').is_file())
        self.assertFalse((generation/messages.COMPLETE).exists())
        calls=list(self.transport.calls)
        with self.assertRaises((OSError,ValueError)):self.resolve('allow')
        self.assertEqual(self.capture.call_count,1)
        self.assertEqual(self.transport.calls,calls)
        self.assert_old_unchanged()

    def test_complete_pair_namespace_identity_must_match_selected_namespace(self):
        selected=self.resolve('allow')
        other=self.outer.project/'other-namespace.tsv'
        other.write_bytes(self.outer.namespace.read_bytes()+b'# additional pinned comment\n')
        self.capture.reset_mock()
        with self.assertRaisesRegex(ValueError,'differs from selected edition/namespace'):
            builder.resolve_language_message_snapshot_options(self.root,self.outer.wiki,self.outer.date,
                other,selected,{},metadata_network='allow')
        self.capture.assert_not_called()

    def test_complete_generation_symlink_is_rejected_without_http(self):
        (self.root/'language-messages-complete-v1').symlink_to(self.old,target_is_directory=True)
        with self.assertRaises(ValueError):self.resolve('allow')
        self.capture.assert_not_called()


if __name__=='__main__':unittest.main()
