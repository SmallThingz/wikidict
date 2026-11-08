"""Incremental message evidence and unchanged paired TSV integration."""
import copy
import errno
import json
import os
from pathlib import Path
import tempfile
import io
import tarfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import build_wiktionaries as builder
import prepare_language_messages as legacy
import prepare_language_messages_v2 as v2
import prepare_language_messages_union as union

WIKI, DATE = 'satwiktionary', '20261001'
NAMESPACE = ('# wikidict-namespace-registry-v1\n# wiki\tsatwiktionary\n'
             '# dump-date\t20261001\n# content-language\tsat\n')


class Transport:
    def __init__(self, missing=False, alter=None):
        self.calls = []
        self.missing, self.alter = missing, alter

    def __call__(self, url, timeout):
        query = parse_qs(urlsplit(url).query)
        self.calls.append(query)
        general = {'wikiid': WIKI, 'lang': 'sat'}
        if query['meta'] == ['siteinfo|languageinfo']:
            value = {'query': {'general': general, 'languageinfo': {
                code: {'code': code, 'fallbacks': chain}
                for code, chain in {'en': [], 'sat': ['en'], 'fr': ['en']}.items()}}}
        else:
            self.assert_plain(query)
            value = {'query': {'general': general, 'allmessages': [
                {'name': key, 'normalizedname': legacy.normalize_key(key),
                 **({'missing': True} if self.missing else {'content': 'ᱟᱰᱨᱟᱣ ' + key + '\n\t\\ $1'})}
                for key in query['ammessages'][0].split('|')]}}
        if self.alter:
            self.alter(value)
        return 200, {'Content-Type': 'application/json'}, json.dumps(value).encode()

    @staticmethod
    def assert_plain(query):
        assert query['meta'] == ['siteinfo|allmessages']
        assert 'amenableparser' not in query and 'amargs' not in query


class MessageUnionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = union.evidence.REPO / '.tmp'
        scratch.mkdir(exist_ok=True)
        cls.base_temp = tempfile.TemporaryDirectory(prefix='message-union-base-', dir=scratch)
        cls.addClassCleanup(cls.base_temp.cleanup)
        root = Path(cls.base_temp.name)
        namespace = root / 'namespace.tsv'
        namespace.write_text(NAMESPACE)
        cls.fixture_base = root / 'base'
        args = SimpleNamespace(wiki=WIKI, date=DATE, namespace_registry=namespace,
            output=cls.fixture_base, languages=['en', 'sat'], messages=['parser-template-loop-warning'] +
            [f'key-{i:03d}' for i in range(61)], delay=0, wall_seconds=60)
        # Construction of a synthetic pre-existing capture is not a durability
        # test. Restore real fsync before any union operation under test.
        with patch.object(os, 'fsync', lambda descriptor: None):
            cls.original = v2.capture(args, transport=Transport(), sleep=lambda _: None)
        cls.original_files = {p.name: p.read_bytes() for p in cls.fixture_base.iterdir()}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='message-union-test-', dir=union.evidence.REPO / '.tmp')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.fixture_base

    def capture(self, name='union', missing=False, alter=None, message='filedesc'):
        args = SimpleNamespace(base=self.base, language='sat', message=message,
                               output=self.root / name, delay=0, wall_seconds=60)
        transport = Transport(missing, alter)
        result = union.capture(args, transport=transport, sleep=lambda _: None)
        return args.output, result, transport

    def rebind(self, root, change=None):
        inventory = legacy.owned_payload(root)
        hashes = {}
        for kind in union.KINDS:
            path = root / (kind + '.manifest.json')
            record = json.loads(path.read_text())
            record['artifacts'] = inventory
            raw = (root / (kind + '.tsv')).read_bytes()
            record.update(output_bytes=len(raw), output_sha256=union.evidence.digest(raw))
            if change:
                change(record)
            path.write_bytes(union.evidence.encoded(record))
            hashes[path.name] = union.evidence.digest(path.read_bytes())
        (root / union.COMPLETE).write_bytes(union.evidence.encoded({'schema': union.SCHEMA, 'manifests': hashes}))

    def test_one_request_preserves_124_rows_and_fallback_bytes(self):
        root, records, transport = self.capture()
        self.assertEqual(len(transport.calls), 1)
        self.assertEqual(transport.calls[0]['meta'], ['siteinfo|allmessages'])
        self.assertEqual(transport.calls[0]['amlang'], ['sat'])
        self.assertEqual(transport.calls[0]['ammessages'], ['filedesc'])
        before = self.original_files['interface-messages.tsv'].splitlines(keepends=True)
        after = (root / 'interface-messages.tsv').read_bytes().splitlines(keepends=True)
        extra = [row for row in after if row.startswith(b'sat\tfiledesc\t')]
        self.assertEqual(len(extra), 1)
        self.assertEqual([row for row in after if row not in extra], before)
        self.assertEqual(records['interface-messages']['rows'], 125)
        self.assertEqual((root / 'language-fallbacks.tsv').read_bytes(), self.original_files['language-fallbacks.tsv'])
        self.assertEqual({p.name: p.read_bytes() for p in self.base.iterdir()}, self.original_files)
        record = records['interface-messages']
        self.assertEqual(record['sources'][0]['retrieved_utc'], self.original['interface-messages']['retrieved_utc'])
        self.assertEqual([row['role'] for row in record['sources']], ['base-capture', 'singleton-message'])
        self.assertNotIn('keys', record)
        self.assertFalse(record['corpus_query_closure_proven'])
        self.assertEqual(union.verify(root), records)

    def test_explicit_missing_is_retained_as_one_negative_row(self):
        root, records, _ = self.capture(missing=True)
        self.assertIn(b'sat\tfiledesc\tM\n', (root / 'interface-messages.tsv').read_bytes())
        self.assertEqual(records['interface-messages']['rows'], 125)
        self.assertEqual(union.verify(root), records)

    def test_existing_pair_is_rejected_before_request(self):
        transport = Transport()
        args = SimpleNamespace(base=self.base, language='sat', message='key-000',
                               output=self.root / 'rejected', delay=0, wall_seconds=60)
        with self.assertRaisesRegex(ValueError, 'conflicts'):
            union.capture(args, transport=transport)
        self.assertEqual(transport.calls, [])
        self.assertFalse(args.output.exists())

    def test_duplicate_base_rows_and_wrong_selected_key_are_rejected(self):
        base = self.original['interface-messages']
        raw = self.original_files['interface-messages.tsv']
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            union.merged_messages(raw + raw.splitlines(keepends=True)[4], {'filedesc': 'x'}, 'sat', 'filedesc', base)
        with self.assertRaisesRegex(ValueError, 'key set'):
            union.merged_messages(raw, {'other': 'x'}, 'sat', 'filedesc', base)
        for key in ('Filedesc', 'file|desc', ''):
            with self.subTest(key=key), self.assertRaises(ValueError):
                union.selection({'selection': {'language': 'sat', 'key': key}})

    def test_unrequested_or_duplicate_response_never_completes(self):
        mutations = [lambda value: value['query']['allmessages'][0].update(name='other'),
                     lambda value: value['query']['allmessages'].append(copy.deepcopy(value['query']['allmessages'][0]))]
        for i, mutate in enumerate(mutations):
            with self.subTest(i=i), self.assertRaises(ValueError):
                self.capture(str(i), alter=mutate)
            self.assertFalse((self.root / str(i) / union.COMPLETE).exists())

    def test_missing_receipt_is_rejected_even_after_inventory_rebind(self):
        root, records, _ = self.capture()
        (root / records['interface-messages']['singleton']['accepted_receipt']).unlink()
        self.rebind(root)
        with self.assertRaises((ValueError, OSError)):
            union.verify(root)

    def test_changed_response_and_tsv_are_rejected_by_replay(self):
        root, _, _ = self.capture()
        path = root / 'language-messages.0001-01.raw.json'
        value = json.loads(path.read_text())
        value['query']['allmessages'][0]['content'] = 'changed'
        path.write_text(json.dumps(value))
        self.rebind(root)
        with self.assertRaisesRegex(ValueError, 'response differs'):
            union.verify(root)
        root, _, _ = self.capture('changed-tsv')
        path = root / 'interface-messages.tsv'
        path.write_bytes(path.read_bytes().replace(b'sat\tfiledesc\tV\t', b'sat\tfiledesc\tV\tchanged '))
        self.rebind(root)
        with self.assertRaisesRegex(ValueError, 'TSV differs'):
            union.verify(root)

    def test_fallback_change_cannot_be_hidden_by_rebound_manifest(self):
        root, _, _ = self.capture()
        path = root / 'language-fallbacks.tsv'
        path.write_bytes(path.read_bytes().replace(b'sat\ten\n', b'sat\tfr\n'))
        self.rebind(root)
        with self.assertRaisesRegex(ValueError, 'TSV differs'):
            union.verify(root)

    def test_provenance_scope_namespace_and_producer_are_bound(self):
        changes = [lambda record: record['sources'][0].update(retrieved_utc='invented'),
                   lambda record: record.update(corpus_query_closure_proven=True),
                   lambda record: record.update(namespace_registry_sha256='0' * 64),
                   lambda record: record['producer'].update(generator_sha256='not-a-digest'),
                   lambda record: record['selection'].update(key='other')]
        for i, change in enumerate(changes):
            root, _, _ = self.capture(str(i))
            self.rebind(root, change)
            with self.subTest(i=i), self.assertRaises(ValueError):
                union.verify(root)

    def test_archive_and_completion_hashes_are_bound(self):
        root, _, _ = self.capture()
        path = root / union.ARCHIVE
        raw = path.read_bytes()
        path.write_bytes(raw[:-1024])
        with self.assertRaisesRegex(ValueError, 'inventory'):
            union.verify(root)
        root, _, _ = self.capture('completion')
        (root / union.COMPLETE).write_text('{}')
        with self.assertRaisesRegex(ValueError, 'completion'):
            union.verify(root)

    def test_pair_manifest_change_is_rejected(self):
        root, _, _ = self.capture()
        path = root / 'language-fallbacks.manifest.json'
        value = json.loads(path.read_text())
        value['selection']['key'] = 'other'
        path.write_bytes(union.evidence.encoded(value))
        hashes = {k + '.manifest.json': union.evidence.digest((root / (k + '.manifest.json')).read_bytes()) for k in union.KINDS}
        (root / union.COMPLETE).write_bytes(union.evidence.encoded({'schema': union.SCHEMA, 'manifests': hashes}))
        with self.assertRaisesRegex(ValueError, 'Paired'):
            union.verify(root)

    def test_builder_both_dispatches_and_flat_relocation(self):
        root, records, _ = self.capture('language-messages-loop-v1')
        for kind in union.KINDS:
            path = root / (kind + '.tsv')
            self.assertIs(builder.auxiliary_capture_helper(kind, path), union)
            record, inventory = builder.validated_auxiliary_capture(kind, path, WIKI, DATE)
            self.assertEqual(record, records[kind])
            self.assertIn(union.ARCHIVE, inventory)
        self.assertEqual(set(builder.discover_auxiliary_generation(self.root, root.name, union.KINDS, WIKI, DATE)), set(union.KINDS))
        copied = self.root / 'relocated'
        namespace = self.root / 'namespace-registry.tsv'
        namespace.write_text(NAMESPACE)
        registry = self.root / 'language-registry.tsv'
        registry.write_text('sat\tSantali\tsat\tSantali\tsat\n')
        snapshots = {kind: root / (kind + '.tsv') for kind in union.KINDS}
        snapshots.update({'namespace-registry': namespace, 'language-registry': registry})
        hashes = {name: union.evidence.digest(path.read_bytes()) for name, path in snapshots.items()}
        pinned = builder.pinned_auxiliary_snapshots(snapshots, hashes, copied)
        self.assertEqual(set(pinned), set(snapshots))
        self.assertEqual(pinned['interface-messages'].parent, pinned['namespace-registry'].parent)
        self.assertEqual((copied / 'namespace-registry.tsv').read_text(), NAMESPACE)
        self.assertEqual(union.verify(copied), records)
        with self.assertRaisesRegex(ValueError, 'edition/date'):
            union.validate_snapshot(pinned['interface-messages'], 'enwiktionary', DATE)
        (copied / 'language-messages.unexpected.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'Unexpected union-owned'):
            union.verify(copied)

    def test_verify_initializes_absent_scratch_parent_in_isolated_repo(self):
        root, records, _ = self.capture()
        isolated_repo = self.root / 'isolated-checkout'
        isolated_repo.mkdir()
        scratch = isolated_repo / '.tmp'
        self.assertFalse(scratch.exists())
        with patch.object(union.evidence, 'REPO', isolated_repo):
            self.assertEqual(union.verify(root), records)
        self.assertTrue(scratch.is_dir())
        self.assertFalse(scratch.is_symlink())
        self.assertEqual(list(scratch.iterdir()), [])

    def test_original_v1_remains_supported_but_not_preferred_loop(self):
        namespace = self.root / 'namespace.tsv'
        namespace.write_text(NAMESPACE)
        args = SimpleNamespace(wiki=WIKI, date=DATE, namespace_registry=namespace,
            output=self.root / 'base-v1', languages=['sat'], messages=['old-key'], delay=0, wall_seconds=60)
        with patch.object(os, 'fsync', lambda descriptor: None):
            legacy.capture(args, transport=Transport(), sleep=lambda _: None)
        # This is a newly generated v1 fixture, so keep its actual provenance.
        # Historical captures still require the unchanged legacy verifier.
        self.base = args.output
        root, records, _ = self.capture()
        self.assertEqual(union.verify(root), records)
        self.assertEqual(records['interface-messages']['rows'], 2)
        with self.assertRaisesRegex(ValueError, 'replayed v2'):
            union.require_preferred_loop(records['interface-messages'])


    def test_recorded_historical_producer_does_not_replace_complete_replay(self):
        root, _, _ = self.capture('language-messages-loop-v1')
        def historical(record):
            record['producer']['generator_sha256'] = '1' * 64
            for base in record['producer']['base_producers']:
                base['generator_sha256'] = '2' * 64
                base['dependency_sha256'] = {k: '3' * 64 for k in base['dependency_sha256']}
        self.rebind(root, historical)
        before = {p.name: p.read_bytes() for p in root.iterdir()}
        result = union.verify(root)
        self.assertEqual({p.name: p.read_bytes() for p in root.iterdir()}, before)
        self.assertEqual(result['interface-messages']['producer']['generator_sha256'], '1' * 64)
        builder.discover_auxiliary_generation(self.root, root.name, union.KINDS, WIKI, DATE)
        # Coherently rehash the accepted raw response AND its receipt. Current
        # reconstruction must still reject its disagreement with the output.
        receiptpath = root / result['interface-messages']['singleton']['accepted_receipt']
        receipt = json.loads(receiptpath.read_bytes()); path = root / receipt['response']
        value = json.loads(path.read_bytes()); value['query']['allmessages'][0]['content'] = 'changed'
        raw = union.evidence.encoded(value); path.write_bytes(raw)
        receipt.update(response_bytes=len(raw), response_sha256=union.evidence.digest(raw))
        receiptpath.write_bytes(union.evidence.encoded(receipt)); self.rebind(root)
        with self.assertRaisesRegex(ValueError, 'TSV differs'): union.verify(root)

    def test_historical_union_provenance_requires_exact_roles_and_hash_shapes(self):
        changes = [lambda p: p.update(extra='unknown'),
                   lambda p: p['base_producers'].reverse(),
                   lambda p: p['base_producers'][0]['dependency_sha256'].update(extra='4' * 64),
                   lambda p: p['base_producers'][1].update(generator_sha256='A' * 64)]
        for index, change in enumerate(changes):
            root, _, _ = self.capture(str(index))
            self.rebind(root, lambda record: change(record['producer']))
            with self.subTest(index=index), self.assertRaises(ValueError): union.verify(root)


class CompleteBaseUnionTest(unittest.TestCase):
    def setUp(self):
        import test_prepare_language_messages_v2 as complete_tests
        self.complete_tests = complete_tests
        self.fixture = complete_tests.CompleteMessageTest()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def capture(self, missing=False, empty=False, large=False):
        def enlarge(query, value):
            if large and query.get('amfrom'):
                value['query']['allmessages'][0]['content'] = 'x' * (3 * 1024 * 1024)
        with patch.object(os, 'fsync', lambda descriptor: None):
            args, _, original = self.fixture.collect(mutate=enlarge)
        self.base = args.output
        before = {p.name: p.read_bytes() for p in self.base.iterdir()}
        def singleton(query, value):
            row = value['query']['allmessages'][0]
            if missing:
                row.pop('content'); row['missing'] = True
            elif empty:
                row['content'] = ''
        transport = self.complete_tests.CompleteTransport(singleton)
        args = SimpleNamespace(base=self.base, language='bn', message='potential-form-tooltip',
            output=self.fixture.base / 'union', delay=0, wall_seconds=60)
        records = union.capture(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(len(transport.calls), 1)
        self.assertEqual(parse_qs(urlsplit(transport.calls[0]).query)['ammessages'], ['potential-form-tooltip'])
        self.assertEqual({p.name: p.read_bytes() for p in self.base.iterdir()}, before)
        self.assertEqual((args.output / 'language-fallbacks.tsv').read_bytes(), before['language-fallbacks.tsv'])
        old = before['interface-messages.tsv'].splitlines(keepends=True)
        new = (args.output / 'interface-messages.tsv').read_bytes().splitlines(keepends=True)
        self.assertEqual([row for row in new if not row.startswith(b'bn\tpotential-form-tooltip\t')], old)
        self.assertEqual(records['interface-messages']['rows'], original['interface-messages']['rows'] + 1)
        self.assertFalse(records['interface-messages']['corpus_query_closure_proven'])
        self.assertEqual(records['interface-messages']['sources'][0]['retrieved_utc'], original['interface-messages']['retrieved_utc'])
        return args.output, records

    def rebind(self, root, change=None):
        hashes = {}
        for kind in union.KINDS:
            path = root / (kind + '.manifest.json')
            record = json.loads(path.read_bytes())
            record['artifacts'] = union.owned_payload(root, record['base_profile'])
            if change: change(record)
            path.write_bytes(union.evidence.encoded(record))
            hashes[path.name] = union.evidence.digest(path.read_bytes())
        (root / union.COMPLETE).write_bytes(union.evidence.encoded(dict(schema=union.SCHEMA, manifests=hashes)))

    def test_complete_base_singleton_and_normal_paired_builder_route(self):
        root, records = self.capture()
        self.assertEqual(union.verify(root), records)
        self.assertEqual(records['interface-messages']['base_profile']['schema'], v2.COMPLETE_SCHEMA)
        for kind in union.KINDS:
            path = root / (kind + '.tsv')
            self.assertIs(builder.auxiliary_capture_helper(kind, path), union)
            self.assertEqual(builder.validated_auxiliary_capture(kind, path, self.complete_tests.WIKI, DATE)[0], records[kind])
        with self.assertRaisesRegex(ValueError, 'replayed v2'):
            union.require_preferred_loop(records['interface-messages'])

    def test_complete_base_explicit_missing_remains_negative(self):
        root, records = self.capture(missing=True)
        self.assertIn(b'bn\tpotential-form-tooltip\tM\n', (root / 'interface-messages.tsv').read_bytes())
        self.assertEqual(union.verify(root), records)

    def test_complete_base_empty_value_is_not_missing(self):
        root, records = self.capture(empty=True)
        self.assertIn(b'bn\tpotential-form-tooltip\tV\t\n', (root / 'interface-messages.tsv').read_bytes())
        self.assertEqual(union.verify(root), records)

    def test_complete_large_archive_uses_complete_bounds_only(self):
        root, records = self.capture(large=True)
        self.assertGreater((root / union.ARCHIVE).stat().st_size, union.MAX_ARCHIVE)
        self.assertGreater((root / 'interface-messages.tsv').stat().st_size, union.MAX_CHILD_FILE)
        self.assertEqual(union.verify(root), records)
        self.assertEqual(union.base_bounds({'schema': v2.SCHEMA}), (union.MAX_ARCHIVE, union.MAX_CHILD_FILE))
        with self.assertRaisesRegex(ValueError, 'Unknown'):
            union.base_bounds({'schema': 'unknown'})

    def test_complete_prior_singleton_and_batch_keep_one_original_archive(self):
        prior, old = self.capture(missing=True, large=True)
        before = {path.name: path.read_bytes() for path in prior.iterdir()}
        transport = self.complete_tests.CompleteTransport()
        args = SimpleNamespace(base=prior, language='bn', message=None,
            messages=['family/en', 'family/pl', 'family/yi'],
            output=self.fixture.base / 'family', delay=0, wall_seconds=60)
        with patch.object(union.os, 'link', side_effect=OSError(errno.EXDEV, 'different filesystem')):
            records = union.capture(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(len(transport.calls), 1)
        self.assertEqual((args.output / union.ARCHIVE).read_bytes(), before[union.ARCHIVE])
        self.assertEqual([path.name for path in args.output.glob('*.tar')], [union.ARCHIVE])
        new = (args.output / 'interface-messages.tsv').read_bytes().splitlines(keepends=True)
        self.assertEqual([row for row in new if not row.startswith(b'bn\tfamily/')],
                         before['interface-messages.tsv'].splitlines(keepends=True))
        self.assertEqual(records['interface-messages']['rows'], old['interface-messages']['rows'] + 3)
        self.assertEqual((args.output / 'language-fallbacks.tsv').read_bytes(), before['language-fallbacks.tsv'])
        self.assertEqual(union.verify(args.output), records)
        self.assertEqual({path.name: path.read_bytes() for path in prior.iterdir()}, before)
        with patch.object(union.os, 'link', side_effect=OSError(errno.EACCES, 'permission denied')):
            with self.assertRaises(OSError) as refused:
                union.verify(args.output)
        self.assertEqual(refused.exception.errno, errno.EACCES)

    def test_complete_profile_and_resealed_archived_request_remain_bound(self):
        root, records = self.capture()
        self.rebind(root, lambda record: record['base_profile'].update(coverage_sha256='0' * 64))
        with self.assertRaisesRegex(ValueError, 'Base profile differs'): union.verify(root)
        self.rebind(root, lambda record: record.update(base_profile=records['interface-messages']['base_profile']))
        request = self.base / (v2.PREFIX + 'requested.json')
        data = json.loads(request.read_bytes()); data['api_core'] = 'f' * 40
        request.write_bytes(union.evidence.encoded(data))
        self.fixture.rebind(self.base)
        with tarfile.open(root / union.ARCHIVE, 'w', format=tarfile.USTAR_FORMAT) as archive:
            for path in sorted(self.base.iterdir()):
                raw = path.read_bytes(); info = tarfile.TarInfo(path.name)
                info.size, info.mode, info.mtime = len(raw), 0o600, 0
                archive.addfile(info, io.BytesIO(raw))
        self.rebind(root)
        with self.assertRaises(ValueError): union.verify(root)


class MessageFamilyUnionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        MessageUnionTest.setUpClass.__func__(cls)

    setUp = MessageUnionTest.setUp
    singleton = MessageUnionTest.capture

    def batch(self, name='family', keys=None, alter=None, transport=None, sleep=lambda _: None):
        args = SimpleNamespace(base=self.base, language='sat', message=None,
            messages=['family/en', 'family/pl', 'family/yi'] if keys is None else keys,
            output=self.root / name, delay=0, wall_seconds=60)
        transport = transport or Transport(alter=alter)
        records = union.capture(args, transport=transport, sleep=sleep)
        return args.output, records, transport

    def rebind(self, root, change=None):
        hashes = {}
        for kind in union.KINDS:
            path = root / (kind + '.manifest.json')
            record = json.loads(path.read_bytes())
            record['artifacts'] = union.owned_payload(root, record['base_profile'], record['prior_singleton'])
            if change:
                change(record)
            path.write_bytes(union.evidence.encoded(record))
            hashes[path.name] = union.evidence.digest(path.read_bytes())
        (root / union.COMPLETE).write_bytes(union.evidence.encoded(
            {'schema': union.BATCH_SCHEMA, 'manifests': hashes}))

    def test_one_batch_preserves_positive_empty_and_negative_without_parsing(self):
        def mixed(value):
            rows = value['query']['allmessages']
            rows[0]['content'] = '{{literal}} $1 <b>source</b>'
            rows[1]['content'] = ''
            rows[2].pop('content')
            rows[2]['missing'] = True
        root, records, transport = self.batch(alter=mixed)
        self.assertEqual(len(transport.calls), 1)
        self.assertEqual(transport.calls[0]['ammessages'], ['family/en|family/pl|family/yi'])
        self.assertEqual(transport.calls[0]['amlang'], ['sat'])
        raw = (root / 'interface-messages.tsv').read_bytes()
        self.assertIn(b'sat\tfamily/en\tV\t{{literal}} $1 <b>source</b>\n', raw)
        self.assertIn(b'sat\tfamily/pl\tV\t\n', raw)
        self.assertIn(b'sat\tfamily/yi\tM\n', raw)
        self.assertEqual(records['interface-messages']['rows'], 127)
        self.assertFalse(records['interface-messages']['prior_singleton'])
        self.assertEqual(union.verify(root), records)

    def test_prior_singleton_and_original_archive_survive_exactly_once(self):
        prior, prior_records, _ = self.singleton(missing=True, message='family')
        before = {path.name: path.read_bytes() for path in prior.iterdir()}
        self.base = prior
        root, records, transport = self.batch()
        self.assertEqual(len(transport.calls), 1)
        self.assertEqual({path.name: path.read_bytes() for path in prior.iterdir()}, before)
        self.assertEqual((root / union.ARCHIVE).read_bytes(), before[union.ARCHIVE])
        self.assertEqual([path.name for path in root.glob('*.tar')], [union.ARCHIVE])
        for name in union.prior_names():
            if name in before:
                self.assertEqual((root / (union.PRIOR_PREFIX + name)).read_bytes(), before[name])
        after = (root / 'interface-messages.tsv').read_bytes().splitlines(keepends=True)
        self.assertEqual([row for row in after if not row.startswith(b'sat\tfamily/')],
                         before['interface-messages.tsv'].splitlines(keepends=True))
        self.assertEqual((root / 'language-fallbacks.tsv').read_bytes(), before['language-fallbacks.tsv'])
        self.assertEqual(records['interface-messages']['rows'], 128)
        self.assertEqual(records['interface-messages']['sources'][1]['source'],
                         prior_records['interface-messages']['sources'][1])
        self.assertEqual(union.verify(root), records)

    def test_selection_conflicts_duplicates_language_and_url_reject_before_network(self):
        prior, _, _ = self.singleton(missing=True, message='family')
        self.base = prior
        cases = [([], 'sat'), (['family'], 'sat'), (['key-000'], 'sat'),
                 (['family/en', 'family/en'], 'sat'), (['family/yi', 'family/pl'], 'sat'),
                 (['Family/pl'], 'sat'), (['family|pl'], 'sat'),
                 ([f'x-{i:02d}' for i in range(51)], 'sat'), (['new-key'], 'de')]
        for i, (keys, language) in enumerate(cases):
            transport = Transport()
            args = SimpleNamespace(base=self.base, language=language, message=None, messages=keys,
                output=self.root / f'refused-{i}', delay=0, wall_seconds=60)
            with self.subTest(keys=keys, language=language), self.assertRaises(ValueError):
                union.capture(args, transport=transport)
            self.assertEqual(transport.calls, [])
            self.assertFalse(args.output.exists())
        with patch.object(legacy, 'MAX_URL', 1):
            with self.assertRaisesRegex(ValueError, 'URL'):
                self.batch('long-url')
        self.assertFalse((self.root / 'long-url').exists())

    def test_unrequested_duplicate_or_partial_batch_response_never_completes(self):
        mutations = [lambda v: v['query']['allmessages'].pop(),
                     lambda v: v['query']['allmessages'][0].update(name='unrequested'),
                     lambda v: v['query']['allmessages'].append(copy.deepcopy(v['query']['allmessages'][0]))]
        for i, change in enumerate(mutations):
            with self.subTest(i=i), self.assertRaises(ValueError):
                self.batch(f'bad-response-{i}', alter=change)
            self.assertFalse((self.root / f'bad-response-{i}' / union.COMPLETE).exists())

    def test_prior_response_tamper_is_not_accepted_by_outer_inventory_rebind(self):
        prior, _, _ = self.singleton(missing=True, message='family')
        self.base = prior
        root, _, _ = self.batch()
        name = union.PRIOR_PREFIX + 'language-messages.0001-01.raw.json'
        path = root / name
        value = json.loads(path.read_bytes())
        row = value['query']['allmessages'][0]
        row.pop('missing'); row['content'] = 'forged positive'
        path.write_bytes(union.evidence.encoded(value))
        self.rebind(root)
        with self.assertRaises(ValueError):
            union.verify(root)

    def test_prior_completion_and_evidence_inventory_are_required(self):
        prior, _, _ = self.singleton(message='family')
        self.base = prior
        root, _, _ = self.batch()
        (root / (union.PRIOR_PREFIX + union.COMPLETE)).unlink()
        self.rebind(root)
        with self.assertRaises((ValueError, OSError)):
            union.verify(root)
        root, _, _ = self.batch('extra-prior')
        (root / (union.PRIOR_PREFIX + 'unexpected.json')).write_text('{}')
        with self.assertRaisesRegex(ValueError, 'Unexpected'):
            union.verify(root)

    def test_batch_output_fallback_and_prior_scope_cannot_be_rebound(self):
        prior, _, _ = self.singleton(message='family')
        self.base = prior
        for i, kind in enumerate(union.KINDS):
            root, _, _ = self.batch(f'changed-{i}')
            path = root / (kind + '.tsv')
            path.write_bytes(path.read_bytes() + b'sat\tforged\tM\n')
            self.rebind(root)
            with self.assertRaisesRegex(ValueError, 'TSV differs'):
                union.verify(root)
        root, _, _ = self.batch('scope')
        self.rebind(root, lambda record: record['sources'][1]['source'].update(retrieved_utc='invented'))
        with self.assertRaisesRegex(ValueError, 'provenance'):
            union.verify(root)

    def test_access_refusal_and_long_retry_after_keep_one_transaction_evidence(self):
        for status, headers in [(403, {}), (429, {'Retry-After': '120'})]:
            calls, waits = [], []
            def transport(url, timeout):
                calls.append(url)
                return status, headers, b'{"error":{"code":"denied"}}'
            name = f'http-{status}'
            with self.subTest(status=status), self.assertRaises(ValueError):
                self.batch(name, transport=transport, sleep=waits.append)
            self.assertEqual(len(calls), 1)
            self.assertEqual(waits, [])
            self.assertFalse((self.root / name / union.COMPLETE).exists())
            receipt = json.loads((self.root / name / 'language-messages.0001-01.receipt.json').read_bytes())
            self.assertFalse(receipt['accepted'])
            self.assertEqual(receipt['status'], status)

    def test_normal_both_role_dispatch_and_flat_relocation_preserve_prior_evidence(self):
        prior, _, _ = self.singleton(message='family')
        self.base = prior
        root, records, _ = self.batch()
        for kind in union.KINDS:
            path = root / (kind + '.tsv')
            self.assertIs(builder.auxiliary_capture_helper(kind, path), union)
            self.assertEqual(builder.validated_auxiliary_capture(kind, path, WIKI, DATE)[0], records[kind])
        snapshots = {kind: root / (kind + '.tsv') for kind in union.KINDS}
        pinned = builder.pinned_auxiliary_snapshots(snapshots,
            {kind: union.evidence.digest(path.read_bytes()) for kind, path in snapshots.items()}, self.root / 'relocated')
        self.assertEqual(union.verify(pinned['interface-messages'].parent), records)
        with self.assertRaisesRegex(ValueError, 'edition/date'):
            union.validate_snapshot(pinned['interface-messages'], 'plwiktionary', DATE)

    def test_batch_base_is_explicitly_unsupported_before_output_or_network(self):
        prior, _, _ = self.batch()
        self.base = prior
        transport = Transport()
        with self.assertRaisesRegex(ValueError, 'original'):
            self.batch('no-history-wrapper', keys=['another-key'], transport=transport)
        self.assertEqual(transport.calls, [])
        self.assertFalse((self.root / 'no-history-wrapper').exists())


if __name__ == '__main__':
    unittest.main()
