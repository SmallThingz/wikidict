import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import prepare_figure_metadata as figure
import prepare_file_metadata_v2 as metadata
import test_prepare_figure_metadata as occurrence_tests
import build_wiktionaries as builder


class FigureFileTests(unittest.TestCase):
    setUp = occurrence_tests.FigureInputTests.setUp
    write_projection = occurrence_tests.FigureInputTests.write_projection
    stage = occurrence_tests.FigureInputTests.stage

    def stream_document(self, root):
        values = figure.stream_values(root/figure.ROLES['figure-sizing'], figure.FILES_STREAM_SCHEMA)
        header = next(values)
        return dict(header, records=list(values))

    def verify_changed_projection(self, root, document):
        path = root/figure.ROLES['figure-sizing']
        path.unlink()
        figure.write_projection_stream(path, document)
        return figure.verify_stream_document(path, root/figure.ROLES['figure-sizing-raw'],
            self.namespace.read_bytes(), self.wiki, self.date,
            (root/figure.ROLES['figure-sizing-site']).read_bytes())

    def response(self, title='ملف:Example.svg'):
        value = copy.deepcopy(self.api)
        value['query']['extensions'] = copy.deepcopy(self.site_api['query']['extensions'])
        page = value['query']['pages'][0]
        page['title'] = title
        page['imageinfo'][0]['canonicaltitle'] = title
        return value

    def project(self, batches, site=None):
        raw = figure.encoded({'schema': figure.RAW_BATCHES_SCHEMA, 'batches': batches})
        return figure.figure_file_document(raw, self.namespace.read_bytes(), self.wiki,
            self.date, figure.encoded(site or self.site_api))

    def batch(self, title='ملف:Example.svg', response=None):
        return {'requests': [title], 'response': figure.encoded(response or self.response(title)).decode()}

    def inventory(self, image=(), links=('Example.svg',)):
        status, paths = {'jobs': {}}, []
        for table, names in (('image', image), ('imagelinks', links)):
            field = 'img_name' if table == 'image' else 'il_to'
            sql = f'CREATE TABLE `{table}` (\n  `{field}` varbinary(255) NOT NULL\n);\n'
            if names:
                sql += f'INSERT INTO `{table}` VALUES '+','.join("('"+n+"')" for n in names)+';\n'
            raw = gzip.compress(sql.encode(), mtime=0)
            path = self.root / f'{self.wiki}-{self.date}-{table}.sql.gz'
            path.write_bytes(raw)
            status['jobs'][table+'table'] = {'status': 'done', 'files': {path.name: {
                'size': len(raw), 'sha1': hashlib.sha1(raw).hexdigest(),
                'url': f'/{self.wiki}/{self.date}/{path.name}'}}}
            paths.append(path)
        status_path = self.root / 'dumpstatus.json'
        status_path.write_bytes(figure.encoded(status))
        return paths, status_path

    def args(self, *, image=(), links=('Example.svg',), reuse=()):
        paths, status = self.inventory(image, links)
        return argparse.Namespace(wiki=self.wiki, date=self.date, defaults=self.root/'defaults',
            dumpstatus=status, sql=paths, output=self.root/'files', reuse=list(reuse),
            batch_size=50, delay=1, wall_seconds=30)

    def test_logical_axes_authority_preserves_exact_revision_and_negative_states(self):
        good = self.batch()
        missing = self.response('ملف:Missing.svg')
        missing['query']['pages'][0] = {'title': 'ملف:Missing.svg', 'ns': 6,
            'missing': True, 'imagerepository': ''}
        unsupported = self.response('ملف:Audio.ogg')
        unsupported['query']['pages'][0]['imageinfo'][0].update(mime='audio/ogg', mediatype='AUDIO', width=0, height=0)
        result = self.project([good, self.batch('ملف:Missing.svg', missing), self.batch('ملف:Audio.ogg', unsupported)])
        states = {row['requested_file']: row['state'] for row in result['records']}
        self.assertEqual(states, {'ملف:Example.svg': 'eligible', 'ملف:Missing.svg': 'missing', 'ملف:Audio.ogg': 'unsupported'})
        row = next(row for row in result['records'] if row['state'] == 'eligible')
        self.assertEqual((row['original_width'], row['original_height']), (800, 600))
        self.assertNotIn('width_px', row)
        self.assertNotIn('height_px', row)

    def test_each_response_owns_timestamp_and_raw_pages_are_accounted(self):
        early = self.response()
        early['curtimestamp'] = '2020-01-01T00:00:00Z'
        later = self.response('ملف:Later.svg')
        with self.assertRaises(ValueError):
            self.project([self.batch(response=early), self.batch('ملف:Later.svg', later)])
        for field, value in (('git-hash', '0'*40), ('wikiid', 'enwiktionary'), ('lang', 'en')):
            changed = self.response();changed['query']['general'][field] = value
            with self.assertRaises(ValueError):self.project([self.batch(response=changed)])
        changed = self.response();changed['query']['pages'].append(self.response('ملف:Unrequested.svg')['query']['pages'][0])
        with self.assertRaises(ValueError):self.project([self.batch(response=changed)])
        changed = self.response();changed['query']['extensions'][0]['vcs-version'] = '0'*40
        with self.assertRaises(ValueError):self.project([self.batch(response=changed)])

    def test_validated_aliases_share_identical_canonical_facts_only(self):
        def alias(name):
            response = self.response('ملف:Canonical.svg')
            response['query']['redirects'] = [{'from': name, 'to': 'ملف:Canonical.svg'}]
            return response
        a, c = alias('ملف:A.svg'), alias('ملف:C.svg')
        result = self.project([self.batch('ملف:A.svg', a), self.batch('ملف:C.svg', c)])
        self.assertEqual({row['canonical_file'] for row in result['records']}, {'ملف:Canonical.svg'})
        for field, value in (('width', 799), ('sha1', 'b'*40), ('timestamp', '2020-01-01T00:00:00Z'), ('mime', 'image/png')):
            self.assertNotEqual(c['query']['pages'][0]['imageinfo'][0][field], value)
            changed = copy.deepcopy(c);changed['query']['pages'][0]['imageinfo'][0][field] = value
            with self.assertRaises(ValueError):self.project([self.batch('ملف:A.svg', a), self.batch('ملف:C.svg', changed)])
        absent = self.response('ملف:Canonical.svg')
        absent['query']['pages'][0] = {'title': 'ملف:Canonical.svg', 'ns': 6, 'imagerepository': '', 'missing': True}
        with self.assertRaises(ValueError):self.project([self.batch('ملف:A.svg', a), self.batch('ملف:Canonical.svg', absent)])
        absent['query']['redirects'] = [{'from': 'ملف:C.svg', 'to': 'ملف:Canonical.svg'}]
        with self.assertRaises(ValueError):self.project([self.batch('ملف:A.svg', a), self.batch('ملف:C.svg', absent)])
        with self.assertRaises(ValueError):self.project([self.batch('ملف:A.svg', a), self.batch('ملف:A.svg', a)])
        cyclic = alias('ملف:A.svg');cyclic['query']['redirects'].append({'from': 'ملف:Canonical.svg', 'to': 'ملف:A.svg'})
        with self.assertRaises(ValueError):self.project([self.batch('ملف:A.svg', cyclic)])

    def test_tiff_without_single_page_proof_is_explicitly_unsupported(self):
        response = self.response('ملف:Example.tif')
        response['query']['pages'][0]['imageinfo'][0].update(mime='image/tiff', mediatype='BITMAP', pagecount=2)
        self.assertEqual(self.project([self.batch('ملف:Example.tif', response)])['records'][0]['state'], 'unsupported')

    def test_empty_dated_inventory_is_no_authority_without_http(self):
        args = self.args(links=())
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('empty inventory made HTTP')):
            result = figure.capture_files(args)
        self.assertEqual(result['coverage']['files'], 0)
        self.assertFalse(result['coverage']['whole_edition_occurrence_coverage'])
        document = self.stream_document(args.output)
        self.assertIsNone(document['source_profile'])
        self.assertEqual(document['records'], [])
        self.assertEqual(figure.verify(args.output), result)
        document['records'] = self.project([self.batch()])['records']
        with self.assertRaises(ValueError):
            self.verify_changed_projection(args.output, document)

    def test_reused_capture_avoids_http_and_preserves_original_inputs(self):
        self.api['query']['extensions'] = copy.deepcopy(self.site_api['query']['extensions'])
        self.write_projection()
        reused = self.stage()
        before = {p.name: p.read_bytes() for p in reused.iterdir()}
        args = self.args(reuse=[reused])
        result = figure.capture_files(args, transport=lambda *_: self.fail('retained file was recaptured'))
        self.assertEqual(result['coverage']['eligible'], 1)
        self.assertEqual(result['coverage']['files'], 1)
        self.assertEqual(before, {p.name: p.read_bytes() for p in reused.iterdir()})
        self.assertEqual(figure.verify(args.output), result)
        selected = result['source_dump_files']
        for role, name in figure.ROLES.items():
            builder._validate_captured_snapshot_context(role, args.output/name, {}, selected,
                                                       None, (result, {}))
        changed = copy.deepcopy(selected)
        changed[0]['sha1'] = '0'*40
        with self.assertRaisesRegex(ValueError, 'differs from selected dump'):
            builder._validate_captured_snapshot_context('figure-sizing', args.output/'figure-sizing.json',
                                                       {}, changed, None, (result, {}))
        (args.sql[1]).write_bytes(b'changed keeper')
        with self.assertRaises(ValueError):figure.verify(args.output)

    def test_missing_file_batch_uses_existing_transport_and_full_replay(self):
        args = self.args(links=('Example.svg', 'Second.svg'))
        args.batch_size = 1
        calls = []
        def transport(url, timeout):
            calls.append(url)
            self.assertIn('curtimestamp=1', url)
            self.assertIn('mime', url)
            title = parse_qs(urlsplit(url).query)['titles'][0]
            return 200, {}, figure.encoded(self.response(title))
        clock = [0.0]
        with patch.object(figure.time, 'monotonic', side_effect=lambda: clock[0]):
            result = figure.capture_files(args, transport=transport,
                                          sleep=lambda delay: clock.__setitem__(0, clock[0] + delay))
        self.assertEqual(len(calls), 2)
        self.assertEqual(result['coverage']['eligible'], 2)
        self.assertEqual(figure.verify(args.output), result)
        changed = self.stream_document(args.output)
        changed['records'][0]['original_width'] = 900
        with self.assertRaises(ValueError):
            self.verify_changed_projection(args.output, changed)

    def test_capture_rejects_unknown_source_before_next_batch_and_preserves_response(self):
        args = self.args(links=('Example.svg', 'Second.svg'));args.batch_size = 1
        changed = self.response();changed['query']['general']['git-hash'] = '0'*40
        calls = []
        def transport(url, timeout):
            calls.append(url)
            return 200, {}, figure.encoded(changed)
        with self.assertRaisesRegex(ValueError, 'different source versions'):
            figure.capture_files(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(len(calls), 1)
        self.assertEqual((args.output/'file-metadata.response-000001-01.raw.json').read_bytes(), figure.encoded(changed))
        failure = json.loads((args.output/'figure-failure-0001.json').read_text())
        self.assertEqual(failure['committed_batches'], 0)
        self.assertFalse((args.output/figure.COMPLETE).exists())


    def test_target_id_schema_joins_only_selected_namespace_six_rows(self):
        paths, status_path = self.inventory(links=())
        status = json.loads(status_path.read_text())
        def replace(table, sql):
            path = self.root/f'{self.wiki}-{self.date}-{table}.sql.gz'
            raw = gzip.compress(sql.encode(), mtime=0)
            path.write_bytes(raw)
            status['jobs'][table+'table'] = {'status': 'done', 'files': {path.name: {
                'size': len(raw), 'sha1': hashlib.sha1(raw).hexdigest(),
                'url': f'/{self.wiki}/{self.date}/{path.name}'}}}
            return path
        replace('imagelinks', 'CREATE TABLE `imagelinks` (\n  `il_target_id` bigint NOT NULL\n);\n'
            'INSERT INTO `imagelinks` VALUES (17),(17);\n')
        target = replace('linktarget', 'CREATE TABLE `linktarget` (\n  `lt_id` bigint NOT NULL,\n'
            '  `lt_namespace` int NOT NULL,\n  `lt_title` varbinary(255) NOT NULL\n);\n'
            "INSERT INTO `linktarget` VALUES (1,14,'Unused_category'),(17,6,'Example.svg');\n")
        result = figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                        figure.encoded(status), [*paths, target])
        self.assertEqual(result['titles'], ['ملف:Example.svg'])
        self.assertEqual(result['imagelinks_mode'], 'il_target_id-to-linktarget-namespace6')
        with self.assertRaisesRegex(ValueError, 'requires.*linktarget'):
            figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                    figure.encoded(status), paths)
        for rows in ("(17,14,'Example.svg')", "(18,6,'Example.svg')", "(17,6,'Example.svg'),(17,6,'Conflict.svg')"):
            sql = 'CREATE TABLE `linktarget` (\n  `lt_id` bigint NOT NULL,\n  `lt_namespace` int NOT NULL,\n  `lt_title` varbinary(255) NOT NULL\n);\n'
            replace('linktarget', sql+'INSERT INTO `linktarget` VALUES '+rows+';\n')
            with self.assertRaises(ValueError):
                figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                        figure.encoded(status), [*paths, target])

    def test_global_target_stream_exceeds_seed_row_limit_and_checks_late_rows(self):
        paths, status_path = self.inventory(links=())
        status = json.loads(status_path.read_text())
        def replace(table, fields, rows):
            path = self.root/f'{self.wiki}-{self.date}-{table}.sql.gz'
            sql = f'CREATE TABLE `{table}` (\n'+fields+'\n);\n'
            sql += f'INSERT INTO `{table}` VALUES '+rows+';\n'
            raw = gzip.compress(sql.encode(), mtime=0)
            path.write_bytes(raw)
            status['jobs'][table+'table'] = {'status': 'done', 'files': {path.name: {
                'size': len(raw), 'sha1': hashlib.sha1(raw).hexdigest(),
                'url': f'/{self.wiki}/{self.date}/{path.name}'}}}
            return path
        replace('imagelinks', '  `il_target_id` bigint NOT NULL', '(17),(17)')
        fields = ('  `lt_id` bigint NOT NULL,\n  `lt_namespace` int NOT NULL,\n'
                  '  `lt_title` varbinary(255) NOT NULL')
        good = "(17,6,'Example.svg'),(1,14,'Unused'),(2,0,'Unused'),(3,6,'Unreferenced.svg')"
        target = replace('linktarget', fields, good)
        original = figure.evidence.sql_rows
        observed = []
        def tracking_rows(path, wanted):
            for row in original(path, wanted):
                if Path(path) == target:
                    observed.append(row[0])
                yield row
        with patch.object(figure.evidence, 'MAX_SQL_ROWS', 2), patch.object(
                figure.evidence, 'sql_rows', side_effect=tracking_rows):
            result = figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                            figure.encoded(status), [*paths, target])
        self.assertEqual(result['titles'], ['ملف:Example.svg'])
        self.assertEqual(observed, [17, 1, 2, 3])
        # An identical late duplicate is invalid too; resolution is not an EOF.
        for rows in (good+",(17,6,'Example.svg')", good+",(17,6,'Conflict.svg')",
                     good+",(0,14,'Invalid')", "(18,6,'Absent.svg')",
                     "(17,14,'Not_a_file')"):
            replace('linktarget', fields, rows)
            with patch.object(figure.evidence, 'MAX_SQL_ROWS', 2):
                with self.assertRaises(ValueError):
                    figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                            figure.encoded(status), [*paths, target])

    def test_full_selected_sql_stream_keeps_late_identity_checks_without_row_ceiling(self):
        paths, status_path = self.inventory(links=())
        status = json.loads(status_path.read_text())
        def replace(table, fields, rows):
            path = self.root/f'{self.wiki}-{self.date}-{table}.sql.gz'
            sql = f'CREATE TABLE `{table}` (\n'+fields+'\n);\n'
            sql += f'INSERT INTO `{table}` VALUES '+rows+';\n'
            raw = gzip.compress(sql.encode(), mtime=0)
            path.write_bytes(raw)
            status['jobs'][table+'table'] = {'status': 'done', 'files': {path.name: {
                'size': len(raw), 'sha1': hashlib.sha1(raw).hexdigest(),
                'url': f'/{self.wiki}/{self.date}/{path.name}'}}}
            return path
        replace('imagelinks', '  `il_target_id` bigint NOT NULL', '(17),(18),(17),(18)')
        target = replace('linktarget', '  `lt_id` bigint NOT NULL,\n  `lt_namespace` int NOT NULL,\n'
            '  `lt_title` varbinary(255) NOT NULL', "(17,6,'One.svg'),(18,6,'Two.svg')")
        with patch.object(figure, 'MAX_TITLES', 1), patch.object(figure.evidence, 'MAX_SQL_ROWS', 1):
            result = figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                             figure.encoded(status), [*paths, target])
        self.assertEqual(len(result['titles']), 2)
        replace('imagelinks', '  `il_target_id` bigint NOT NULL', '(17),(18),(0)')
        with self.assertRaisesRegex(ValueError, 'Invalid imagelinks target'):
            figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                    figure.encoded(status), [*paths, target])
        self.assertFalse((self.root/'files'/figure.COMPLETE).exists())


    def test_encoded_stream_record_limit_stops_before_second_request_and_retains_response(self):
        args = self.args(links=('Example.svg', 'Second.svg'));args.batch_size = 1
        response = self.response()
        response['query']['pages'][0]['imageinfo'][0]['metadata'] = [
            {'name': 'description', 'value': '\\"' * 8192}]
        raw = figure.encoded(response)
        first_batch = {'requests': ['\u0645\u0644\u0641:Example.svg'], 'response': raw.decode()}
        limit = len(figure.stream_encoded(first_batch))-1
        self.assertLess(len(raw), limit)
        calls = []
        def transport(url, timeout):
            calls.append(url)
            return 200, {}, raw
        with patch.object(figure, 'STREAM_RAW_LINE_LIMIT', limit):
            with self.assertRaisesRegex(ValueError, 'response record exceeds'):
                figure.capture_files(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(len(calls), 1)
        self.assertEqual((args.output/'file-metadata.response-000001-01.raw.json').read_bytes(), raw)
        self.assertTrue((args.output/figure.FILE_REQUESTS).is_file())
        self.assertFalse((args.output/figure.COMPLETE).exists())


    def test_shared_batch_preserves_audio_positive_and_explicit_negative_provider_facts(self):
        args = self.args()
        log = self.root/'observed.log'
        log.write_text('warning: file metadata missing: title=ملف:Audio.ogg\n'
                       'warning: file metadata snapshot unavailable: title=ملف:Missing.svg\n')
        args.log = [log]
        calls = []
        def transport(url, timeout):
            calls.append(url)
            titles = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            response = self.response();response['query']['pages'] = []
            for title in titles:
                page = self.response(title)['query']['pages'][0]
                if title.endswith('Audio.ogg'):
                    page['imageinfo'][0].update(mime='audio/ogg', mediatype='AUDIO', width=0, height=0)
                elif title.endswith('Missing.svg'):
                    page = {'title': title, 'ns': 6, 'missing': True, 'imagerepository': ''}
                response['query']['pages'].append(page)
            return 200, {}, figure.encoded(response)
        result = figure.capture_files(args, transport=transport)
        self.assertEqual(len(calls), 1)
        raw = (args.output/figure.PROVIDER).read_bytes()
        self.assertTrue(raw.startswith(b'# wikidict-file-metadata-v2\n'))
        rows = {parts[0]: parts[1:] for parts in (line.split('\t') for line in raw.decode().splitlines()[1:])}
        self.assertEqual(rows['ملف:Audio.ogg'], ['1', '0', '0', 'AUDIO', 'ملف:Audio.ogg'])
        self.assertEqual(rows['ملف:Missing.svg'], ['0', '0', '0', '-', '-'])
        self.assertEqual(result['coverage']['unsupported'], 1)
        self.assertEqual(result['coverage']['provider'], {'header_version': 2, 'rows': 3,
            'positive_rows': 2, 'negative_rows': 1, 'sql_files': 1, 'observed_query_files': 2,
            'observed_only_files': 2, 'corpus_query_closure_proven': False})
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(json.loads((args.output/figure.INVENTORY).read_text())['titles'], ['ملف:Example.svg'])
        copied = json.loads((args.output/figure.QUERY_INPUTS).read_text())[0]
        self.assertEqual((args.output/copied['path']).read_bytes(), log.read_bytes())
        # Rehashing a dropped positive audio row cannot turn unsupported Figure
        # policy into an authoritative negative Lua existence result.
        changed = raw.replace('ملف:Audio.ogg\t1\t0\t0\tAUDIO\tملف:Audio.ogg'.encode(),
                              'ملف:Audio.ogg\t0\t0\t0\t-\t-'.encode())
        self.assertNotEqual(changed, raw)
        (args.output/figure.PROVIDER).write_bytes(changed)
        result['outputs']['file-metadata'] = figure.digest(changed)
        result['artifacts'] = figure.payload(args.output)
        (args.output/figure.MANIFEST).write_bytes(figure.encoded(result))
        (args.output/figure.COMPLETE).write_bytes(figure.encoded({'schema': figure.SCHEMA,
            'manifest_sha256': figure.digest((args.output/figure.MANIFEST).read_bytes())}))
        with self.assertRaisesRegex(ValueError, 'Provider TSV differs'):
            figure.verify(args.output)

    def test_shared_capture_normal_discovery_validation_and_single_copy(self):
        args = self.args()
        args.output = self.root/'figure-inputs'
        result = figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(self.response())))
        with patch.object(figure, 'verify', wraps=figure.verify) as replay:
            selected = builder.discover_auxiliary_generation(self.root, 'figure-inputs',
                tuple(figure.ROLES), self.wiki, self.date)
            self.assertEqual(replay.call_count, 1)
        self.assertEqual(set(selected), {*figure.ROLES, 'file-metadata'})
        with patch.object(figure, 'verify', wraps=figure.verify) as replay:
            hashes, captures = builder._validated_auxiliary_state(selected, self.wiki, self.date,
                captured_selection=({}, result['source_dump_files'], None))
            self.assertEqual(replay.call_count, 1)
        identities = builder._project_auxiliary_capture_identities(captures)
        target = self.root/'pinned'
        with patch.object(builder, 'copy_verified_snapshot', wraps=builder.copy_verified_snapshot) as copies:
            pinned = builder.pinned_auxiliary_snapshots(selected, hashes, target, *identities)
        self.assertEqual({path.parent for path in pinned.values()}, {target/'figure-inputs'})
        destinations = [call.args[1] for call in copies.call_args_list]
        self.assertEqual(len(destinations), len(set(destinations)))
        self.assertEqual(figure.verify(target/'figure-inputs'), result)
        self.assertEqual(builder.auxiliary_manifest_filename('file-metadata', pinned['file-metadata']), figure.MANIFEST)
        with self.assertRaisesRegex(ValueError, 'requires its Provider'):
            builder._validated_auxiliary_state({k: v for k, v in selected.items() if k != 'file-metadata'})
        changed = copy.deepcopy(result['source_dump_files']);changed[0]['sha1'] = '0'*40
        with self.assertRaisesRegex(ValueError, 'differs from selected dump'):
            builder._validated_auxiliary_state(selected, self.wiki, self.date,
                captured_selection=({}, changed, None))

    def test_observed_query_copy_cannot_change_under_rehashed_package(self):
        args = self.args()
        log = self.root/'queries.log'
        log.write_text('warning: file metadata missing: title=ملف:Example.svg\n')
        args.log = [log]
        result = figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(self.response())))
        query_path = args.output/json.loads((args.output/figure.QUERY_INPUTS).read_text())[0]['path']
        query_path.write_text('warning: file metadata missing: title=ملف:Unknown.svg\n')
        result['artifacts'] = figure.payload(args.output)
        (args.output/figure.MANIFEST).write_bytes(figure.encoded(result))
        with self.assertRaisesRegex(ValueError, 'Observed file query source changed'):
            figure.verify(args.output, require_complete=False)

    def test_retained_request_batch_is_replayed_once_without_recapture(self):
        args = self.args()
        donor = self.root/'retained-batch';donor.mkdir()
        (donor/metadata.NAMESPACE).write_bytes(self.namespace.read_bytes())
        registry = figure.evidence.Registry(self.namespace.read_bytes(), self.wiki, self.date)
        _, batch = metadata.request_batch(donor, 1, ['ملف:Example.svg'], registry,
            lambda *_: (200, {}, figure.encoded(self.response())), lambda _: None,
            figure.time.monotonic()+30, 1, figure_axes=True)
        artifacts = {path.name: {'size': path.stat().st_size, 'sha256': figure.digest(path.read_bytes())}
                     for path in donor.iterdir()}
        record = {'wiki': self.wiki, 'date': self.date, 'batch': batch, 'artifacts': artifacts}
        identity = donor/'selected-facts-result.json';identity.write_bytes(figure.encoded(record))
        args.reuse_batch = [identity]
        before = {path.name: path.read_bytes() for path in donor.iterdir()}
        result = figure.capture_files(args, transport=lambda *_: self.fail('retained facts were recaptured'))
        self.assertEqual(result['coverage']['provider']['positive_rows'], 1)
        self.assertEqual(before, {path.name: path.read_bytes() for path in donor.iterdir()})
        self.assertEqual(figure.verify(args.output), result)
        receipt_path = donor/batch['accepted_receipt']
        receipt = json.loads(receipt_path.read_text());receipt['status'] = 403
        receipt_path.write_bytes(figure.encoded(receipt))
        record['artifacts'][receipt_path.name] = {'size': receipt_path.stat().st_size,
                                                'sha256': figure.digest(receipt_path.read_bytes())}
        identity.write_bytes(figure.encoded(record))
        with self.assertRaisesRegex(ValueError, 'accepted receipt'):
            figure.retained_metadata_batch(identity, self.wiki, self.date, self.namespace.read_bytes())

    def test_unknown_query_result_never_becomes_negative_or_complete(self):
        args = self.args(links=())
        log = self.root/'queries.log'
        log.write_text('warning: file metadata missing: title=ملف:Unknown.svg\n')
        args.log = [log]
        response = self.response('ملف:Unknown.svg')
        response['query']['pages'][0]['filehidden'] = True
        with self.assertRaisesRegex(ValueError, 'inaccessible'):
            figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(response)))
        self.assertTrue((args.output/'file-metadata.response-000001-01.raw.json').is_file())
        self.assertTrue((args.output/figure.QUERY_INPUTS).is_file())
        self.assertFalse((args.output/figure.PROVIDER).exists())
        self.assertFalse((args.output/figure.COMPLETE).exists())

    def test_empty_shared_capture_is_header_only_and_legacy_stage_stays_four_roles(self):
        args = self.args(links=())
        result = figure.capture_files(args, transport=lambda *_: self.fail('empty inventory made HTTP'))
        self.assertEqual((args.output/figure.PROVIDER).read_bytes(), (metadata.HEADER+'\n').encode())
        self.assertEqual(result['coverage']['provider']['rows'], 0)
        self.assertFalse(result['coverage']['provider']['corpus_query_closure_proven'])
        self.write_projection()
        legacy = self.stage('legacy')
        self.assertFalse((legacy/figure.PROVIDER).exists())
        self.assertEqual(set(figure.verify(legacy)['outputs']), set(figure.ROLES))

    def test_observed_query_seed_bounds_and_duplicate_inputs_precede_http(self):
        args = self.args()
        log = self.root/'queries.log';log.write_bytes(b'ignored log row\n')
        args.log = [log, log]
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            figure.capture_files(args, transport=lambda *_: self.fail('invalid seeds made HTTP'))
        self.assertFalse(args.output.exists())
        args.log = [log]
        original = figure.evidence.stamp
        def oversized(path):
            value = original(path)
            return (*value[:2], figure.MAX_METADATA + 1, *value[3:]) if Path(path) == log else value
        with patch.object(figure.evidence, 'stamp', side_effect=oversized):
            with self.assertRaisesRegex(ValueError, 'exceed'):
                figure.capture_files(args, transport=lambda *_: self.fail('oversized seed made HTTP'))
        self.assertFalse(args.output.exists())

    def test_combined_sql_and_observed_queries_preserve_all_selected_names(self):
        args = self.args()
        log = self.root/'queries.log'
        log.write_text('warning: file metadata missing: title=\u0645\u0644\u0641:Other.svg\n')
        args.log = [log]
        def transport(url, timeout):
            titles = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            response = self.response();response['query']['pages'] = [self.response(t)['query']['pages'][0] for t in titles]
            return 200, {}, figure.encoded(response)
        with patch.object(figure, 'MAX_TITLES', 1), patch.object(figure.evidence, 'MAX_TITLES', 1):
            result = figure.capture_files(args, transport=transport)
        self.assertEqual(result['coverage']['files'], 2)
        self.assertEqual(result['coverage']['provider']['observed_only_files'], 1)
        self.assertEqual(figure.verify(args.output), result)


    def test_inventory_rejects_malformed_authority_and_changes_after_hashing(self):
        paths, status = self.inventory()
        for value in (None, {'jobs': None}, {'jobs': {'imagetable': []}},
                      {'jobs': {'imagetable': {'files': {paths[0].name: None}}}}):
            with self.assertRaises(ValueError):
                figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                        figure.encoded(value), paths)
        original = figure.evidence.sql_rows
        def changing_rows(path, fields):
            yield from original(path, fields)
            if Path(path) == paths[1]:
                with paths[0].open('ab') as stream:
                    stream.write(b'changed after authentication')
        with patch.object(figure.evidence, 'sql_rows', side_effect=changing_rows):
            with self.assertRaisesRegex(ValueError, 'changed during inventory'):
                figure.source_inventory(self.namespace.read_bytes(), self.wiki, self.date,
                                        status.read_bytes(), paths)

    def svg_observation(self, core=None):
        base = self.response()
        base['query']['general']['git-hash'] = core or figure.FIGURE_COMPATIBLE_CORE
        image = base['query']['pages'][0]['imageinfo'][0]
        image.update(width=103, height=94)
        observed = copy.deepcopy(base)
        observed['query']['pages'][0]['imageinfo'][0].update(
            url='https://upload.wikimedia.org/original.svg?utm_content=original',
            thumburl='https://thumb.wikimedia.org/rendered.png?utm_content=thumbnail',
            thumbwidth=250, thumbheight=228, thumbattribs={'width': 250, 'height': 228})
        supplement = self.batch(response=observed)
        supplement['observed_svg_width_px'] = 250
        return base, observed, supplement

    def test_observed_svg_width_is_corroborated_without_changing_base_identity(self):
        for core in (figure.FIGURE_COMPATIBLE_CORE, figure.FIGURE_CURRENT_CORE):
            with self.subTest(core=core):
                base, observed, supplement = self.svg_observation(core)
                document = self.project([self.batch(response=base), supplement], site=base)
                row = document['records'][0]
                self.assertEqual((row['batch'], row['observed_batch'], row['observed_svg_width_px']), (0, 1, 250))
                self.assertEqual((row['original_width'], row['original_height']), (103, 94))
                self.assertEqual(row['file_sha1'], base['query']['pages'][0]['imageinfo'][0]['sha1'])
                self.assertEqual(document['core_revision'], core)
                self.assertTrue(figure.figure_source_compatible(document['core_revision'], self.core))
                self.assertFalse(figure.figure_source_compatible(document['core_revision'], '0'*40))
                self.assertNotIn('observed_svg_width_px', self.project([self.batch(response=base)], site=base)['records'][0])
                raw = figure.encoded({'schema': figure.RAW_BATCHES_SCHEMA, 'batches': [self.batch(response=base), supplement]})
                self.assertEqual(figure.verify_figure_file_document(document, raw, self.namespace.read_bytes(), self.wiki, self.date, figure.encoded(base)), document)
                false_projection = copy.deepcopy(document);false_projection['records'][0]['observed_svg_width_px'] = 500
                with self.assertRaises(ValueError):
                    figure.verify_figure_file_document(false_projection, raw, self.namespace.read_bytes(), self.wiki, self.date, figure.encoded(base))

    def test_observed_svg_refuses_bitmap_native_url_wrong_axes_identity_and_ordinary_duplicates(self):
        base, observed, supplement = self.svg_observation()
        for key, value in (('thumbheight', 229), ('thumbwidth', 251), ('thumbattribs', {'width': 250, 'height': 229}),
                           ('thumburl', 'https://upload.wikimedia.org/original.svg?utm_content=thumbnail'),
                           ('thumburl', 'https://user@thumb.wikimedia.org/rendered.png'),
                           ('sha1', '0'*40), ('timestamp', '2020-01-01T00:00:00Z'), ('thumberror', 'failed')):
            changed = copy.deepcopy(observed)
            changed['query']['pages'][0]['imageinfo'][0][key] = value
            other = dict(supplement, response=figure.encoded(changed).decode())
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.project([self.batch(response=base), other], site=base)
        jpeg_base, jpeg_observed = copy.deepcopy(base), copy.deepcopy(observed)
        for response in (jpeg_base, jpeg_observed):
            response['query']['pages'][0]['imageinfo'][0].update(mime='image/jpeg', mediatype='BITMAP')
        with self.assertRaises(ValueError):
            self.project([self.batch(response=jpeg_base), dict(supplement, response=figure.encoded(jpeg_observed).decode())], site=base)
        with self.assertRaises(ValueError):self.project([supplement], site=base)
        with self.assertRaises(ValueError):self.project([self.batch(response=base), self.batch(response=observed)], site=base)
        with self.assertRaises(ValueError):self.project([self.batch(response=base), supplement, supplement], site=base)
        wrong_core = copy.deepcopy(observed);wrong_core['query']['general']['git-hash'] = self.core
        with self.assertRaises(ValueError):
            self.project([self.batch(response=base), dict(supplement, response=figure.encoded(wrong_core).decode())], site=base)

    def write_svg_observation(self, response):
        from urllib.parse import urlencode
        donor = self.root/'observed-svg';donor.mkdir()
        name = response['query']['pages'][0]['title']
        query = {'action': 'query', 'format': 'json', 'formatversion': '2', 'meta': 'siteinfo',
            'siprop': 'general|extensions', 'prop': 'imageinfo',
            'iiprop': 'size|sha1|timestamp|canonicaltitle|mediatype|mime|metadata|url',
            'iilimit': '1', 'redirects': '1', 'maxlag': '5', 'titles': name, 'curtimestamp': '1', 'iiurlwidth': '250'}
        request = {'fixed_verified_batch_contract': False, 'request_count': 1, 'titles': [name],
                   'query': query, 'url': figure.wiktionary_api(self.wiki)+'?'+urlencode(query)}
        raw = figure.encoded(response)
        receipt = {'accepted': True, 'status': 200, 'request_count': 1, 'response': 'response01.raw.json',
                   'response_bytes': len(raw), 'response_sha256': figure.digest(raw)}
        for filename, data in ((metadata.NAMESPACE, self.namespace.read_bytes()), ('request01.json', figure.encoded(request)),
                               ('receipt01.json', figure.encoded(receipt)), ('response01.raw.json', raw)):
            (donor/filename).write_bytes(data)
        record = {'wiki': self.wiki, 'date': self.date, 'observed_svg_width_px': 250,
                  'batch': {'request': 'request01.json', 'accepted_receipt': 'receipt01.json'},
                  'artifacts': {p.name: {'size': p.stat().st_size, 'sha256': figure.digest(p.read_bytes())} for p in donor.iterdir()}}
        path = donor/'retained-observation.json';path.write_bytes(figure.encoded(record))
        return path

    def test_observed_request_reuse_keeps_original_audio_negative_and_never_recaptures(self):
        base, observed, supplement = self.svg_observation()
        audio = 'ملف:Missing.ogg'
        base['query']['pages'].append({'title': audio, 'ns': 6, 'missing': True, 'imagerepository': ''})
        args = self.args(links=('Example.svg', 'Missing.ogg'))
        donor = self.root/'original-two-facts';donor.mkdir()
        (donor/metadata.NAMESPACE).write_bytes(self.namespace.read_bytes())
        registry = figure.evidence.Registry(self.namespace.read_bytes(), self.wiki, self.date)
        _, batch = metadata.request_batch(donor, 1, ['ملف:Example.svg', audio], registry,
            lambda *_: (200, {}, figure.encoded(base)), lambda _: None,
            figure.time.monotonic()+30, 1, figure_axes=True)
        record = {'wiki': self.wiki, 'date': self.date, 'batch': batch,
                  'artifacts': {p.name: {'size': p.stat().st_size, 'sha256': figure.digest(p.read_bytes())} for p in donor.iterdir()}}
        identity = donor/'selected-facts.json';identity.write_bytes(figure.encoded(record))
        observation = self.write_svg_observation(observed)
        args.reuse_batch = [observation, identity]  # Import order must not lose the base facts.
        before = {str(p): p.read_bytes() for directory in (donor, observation.parent) for p in directory.iterdir()}
        result = figure.capture_files(args, transport=lambda *_: self.fail('retained source was recaptured'))
        self.assertEqual(result['coverage']['provider']['positive_rows'], 1)
        self.assertEqual(result['coverage']['provider']['negative_rows'], 1)
        self.assertEqual(result['coverage']['observed_svg_files'], 1)
        self.assertEqual((args.output/figure.ROLES['figure-siteinfo']).read_bytes(), (self.root/'defaults'/figure.site_info.SNAPSHOT).read_bytes())
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(before, {str(p): p.read_bytes() for directory in (donor, observation.parent) for p in directory.iterdir()})
        projection = self.stream_document(args.output)
        self.assertEqual(projection['core_revision'], figure.FIGURE_COMPATIBLE_CORE)
        self.assertEqual(next(row for row in projection['records'] if row['requested_file'] == audio)['state'], 'missing')

    def test_observed_request_query_and_receipt_are_replayed_after_coherent_rehash(self):
        _, observed, _ = self.svg_observation()
        path = self.write_svg_observation(observed)
        original = json.loads(path.read_text())
        original_request = json.loads((path.parent/'request01.json').read_text())
        original_receipt = json.loads((path.parent/'receipt01.json').read_text())
        for mode in range(5):
            request, receipt = copy.deepcopy(original_request), copy.deepcopy(original_receipt)
            if mode == 0:request['query']['iiurlwidth'] = '251'
            if mode == 1:request['url'] += '&iiurlwidth=250'
            if mode == 2:receipt['status'] = 403
            if mode == 3:request['fixed_verified_batch_contract'] = True
            if mode == 4:request['url'] = request['url'].replace('ar.wiktionary.org', 'en.wiktionary.org')
            (path.parent/'request01.json').write_bytes(figure.encoded(request))
            (path.parent/'receipt01.json').write_bytes(figure.encoded(receipt))
            record = copy.deepcopy(original)
            for name in ('request01.json', 'receipt01.json'):
                data = (path.parent/name).read_bytes();record['artifacts'][name] = {'size': len(data), 'sha256': figure.digest(data)}
            path.write_bytes(figure.encoded(record))
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                figure.retained_metadata_batch(path, self.wiki, self.date, self.namespace.read_bytes())


    def test_stream_records_preserve_all_bytes_above_legacy_aggregate_limit(self):
        args = self.args(links=('Example.svg', 'Second.svg'));args.batch_size = 1
        responses = []
        def transport(url, timeout):
            title = parse_qs(urlsplit(url).query)['titles'][0]
            response = self.response(title)
            response['query']['pages'][0]['imageinfo'][0]['metadata'] = [{'name': 'description', 'value': 'x'*4096}]
            raw = figure.encoded(response);responses.append(raw)
            return 200, {}, raw
        with patch.object(figure, 'MAX_METADATA', 1), patch.object(figure, 'MAX_BATCHES', 1):
            result = figure.capture_files(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(result['coverage']['files'], 2)
        batches = list(figure.stream_values(args.output/figure.ROLES['figure-sizing-raw'], figure.RAW_STREAM_SCHEMA))[1:]
        self.assertEqual([b['response'].encode() for b in batches], responses)
        self.assertFalse(list(args.output.glob('file-metadata.response-*.raw.json')))
        self.assertEqual(len(list(args.output.glob('file-metadata.response-*.receipt.json'))), 2)
        self.assertTrue(all(row['url'].startswith('https://dumps.wikimedia.org/') for row in result['source_dump_files']))
        self.assertEqual(figure.verify(args.output), result)

    def test_stream_lf_counts_hash_and_exact_eof_are_required(self):
        for raw in (b'{"value":1e400}\n', b'{"value":-1e400}\n', b'{"value":NaN}\n', b'{"value":Infinity}\n'):
            with self.assertRaisesRegex(ValueError, 'Nonfinite'):
                figure.stream_decode(raw)
        self.assertEqual(figure.stream_decode(b'{"value":1.5}\n'), {'value': 1.5})
        args = self.args()
        figure.capture_files(args, transport=lambda *_: (200, {}, figure.encoded(self.response())))
        projection_path = args.output/figure.ROLES['figure-sizing']
        raw_path = args.output/figure.ROLES['figure-sizing-raw']
        original = projection_path.read_bytes()
        lines = original.splitlines(keepends=True)
        header = json.loads(lines[0])
        bad_headers = []
        for key, value in (('records_count', True), ('records_count', 1.0), ('records_count', 2),
                           ('base_batches', 0), ('observed_batches', 2), ('raw_bytes', raw_path.stat().st_size+1),
                           ('raw_sha256', '0'*64)):
            changed = dict(header);changed[key] = value;bad_headers.append(figure.stream_encoded(changed)+b''.join(lines[1:]))
        for invalid in [original[:-1], original+b'{}\n', original+b'\n', original.replace(b'\n',b'\r\n',1),
                        b'\xef\xbb\xbf'+original, *bad_headers]:
            with self.subTest(prefix=invalid[:30]):
                projection_path.write_bytes(invalid)
                with self.assertRaises((ValueError, StopIteration)):
                    figure.verify_stream_document(projection_path, raw_path, self.namespace.read_bytes(),
                        self.wiki, self.date, (args.output/figure.ROLES['figure-sizing-site']).read_bytes())
        projection_path.write_bytes(original)
        self.assertEqual(len(figure.verify_stream_document(projection_path, raw_path,
            self.namespace.read_bytes(), self.wiki, self.date,
            (args.output/figure.ROLES['figure-sizing-site']).read_bytes())['records']), 1)
        requests = args.output/figure.FILE_REQUESTS
        original_requests = requests.read_bytes()
        with patch.object(figure, 'STREAM_HEADER_LIMIT', len(original_requests.splitlines(keepends=True)[0])):
            requests.write_bytes(b' '+original_requests)
            with self.assertRaisesRegex(ValueError, 'header exceeds'):
                list(figure.source_records(requests, 1))
        requests.write_bytes(original_requests)

    def make_wall_stop(self):
        args = self.args(links=('Example.svg', 'Second.svg'));args.batch_size = 1;args.wall_seconds = 1
        clock, calls = [0.0], []
        def transport(url, timeout):
            calls.append(parse_qs(urlsplit(url).query)['titles'][0])
            return 200, {}, figure.encoded(self.response(calls[-1]))
        with patch.object(figure.time, 'monotonic', side_effect=lambda: clock[0]):
            with self.assertRaisesRegex(ValueError, 'Capture wall deadline reached'):
                figure.capture_files(args, transport=transport,
                    sleep=lambda delay: clock.__setitem__(0, clock[0]+delay))
        self.assertEqual(calls, ['\u0645\u0644\u0641:Example.svg'])
        self.assertFalse((args.output/'file-metadata.request-000002.json').exists())
        failure_path = args.output/'figure-failure-0001.json'
        failure = json.loads(failure_path.read_text())
        self.assertEqual(failure['committed_batches'], 1)
        descriptor = {'path': failure_path.name, 'bytes': failure_path.stat().st_size,
                      'sha256': figure.digest(failure_path.read_bytes())}
        plan = json.loads((args.output/figure.PLAN).read_text())
        closure = {'outcome': 'FAILED-PHYSICALLY-SOURCE-CLOSED', 'source_after': True, 'reaped': True,
            'dual_proc_absence': True, 'ps_absence': True, 'allocation_released': True, 'terminal': 1,
            'capture_failure': descriptor, 'capture_root': str(args.output.resolve()),
            'capture_plan_sha256': figure.digest(figure.encoded(plan))}
        raw = figure.encoded(closure)
        proof = {'schema': 'wikidict.figure-closed-wall-stop.v1', 'source_root': str(args.output.resolve()),
            'plan_sha256': closure['capture_plan_sha256'], 'failure': descriptor,
            'closure_raw': raw.decode(), 'closure': {'bytes': len(raw), 'sha256': figure.digest(raw)}}
        args.resume = args.output/figure.RESUME
        args.resume.write_bytes(figure.encoded(proof))
        args.wall_seconds = 30
        return args, proof

    def test_closed_pacing_wall_stop_resumes_without_refetch_and_preserves_prefix(self):
        args, _ = self.make_wall_stop()
        prefix = (args.output/figure.ROLES['figure-sizing-raw']).read_bytes()
        failure = (args.output/'figure-failure-0001.json').read_bytes()
        calls = []
        def transport(url, timeout):
            calls.append(parse_qs(urlsplit(url).query)['titles'][0])
            return 200, {}, figure.encoded(self.response(calls[-1]))
        result = figure.capture_files(args, transport=transport, sleep=lambda _: None)
        self.assertEqual(calls, ['\u0645\u0644\u0641:Second.svg'])
        self.assertTrue((args.output/figure.ROLES['figure-sizing-raw']).read_bytes().startswith(prefix))
        self.assertEqual((args.output/'figure-failure-0001.json').read_bytes(), failure)
        self.assertEqual(figure.verify(args.output), result)

    def test_resume_refuses_unclosed_changed_source_and_uncommitted_evidence(self):
        args, proof = self.make_wall_stop()
        original = args.resume.read_bytes()
        changed = copy.deepcopy(proof)
        closure = json.loads(changed['closure_raw']);closure['dual_proc_absence'] = False
        raw = figure.encoded(closure);changed['closure_raw'] = raw.decode()
        changed['closure'] = {'bytes': len(raw), 'sha256': figure.digest(raw)}
        args.resume.write_bytes(figure.encoded(changed))
        with self.assertRaisesRegex(ValueError, 'physical/source closure'):
            figure.capture_files(args, transport=lambda *_: self.fail('unclosed prefix made HTTP'))
        args.resume.write_bytes(original)
        with patch.object(figure, 'capture_source', return_value={'generator_sha256':'0'*64}):
            with self.assertRaisesRegex(ValueError, 'resume source'):
                figure.capture_files(args, transport=lambda *_: self.fail('changed source made HTTP'))
        (args.output/'uncommitted.raw').write_bytes(b'preserve me')
        with self.assertRaisesRegex(ValueError, 'uncommitted artifacts'):
            figure.capture_files(args, transport=lambda *_: self.fail('uncommitted prefix made HTTP'))
        self.assertEqual((args.output/'uncommitted.raw').read_bytes(), b'preserve me')

    def test_resume_never_turns_access_refusal_into_retry_permission(self):
        args, proof = self.make_wall_stop()
        failure_path = args.output/proof['failure']['path']
        failure = json.loads(failure_path.read_text());failure['error'] = 'API HTTP status 403'
        raw = figure.encoded(failure);failure_path.write_bytes(raw)
        proof['failure'].update(bytes=len(raw), sha256=figure.digest(raw))
        closure = json.loads(proof['closure_raw']);closure['capture_failure'] = proof['failure']
        raw = figure.encoded(closure);proof['closure_raw'] = raw.decode()
        proof['closure'] = {'bytes': len(raw), 'sha256': figure.digest(raw)}
        args.resume.write_bytes(figure.encoded(proof))
        with self.assertRaisesRegex(ValueError, 'closed wall-stop'):
            figure.capture_files(args, transport=lambda *_: self.fail('access refusal retried'))
        self.assertFalse((args.output/figure.COMPLETE).exists())


    def normal_build_inputs(self):
        args = self.args()
        downloads = self.root/'downloads'
        folder = downloads/self.wiki/self.date
        folder.mkdir(parents=True)
        sql = []
        selected = []
        from download_wiktionaries import BASE
        for source in args.sql:
            path = folder/source.name
            source.rename(path)
            sql.append(path)
            raw = path.read_bytes()
            selected.append(dict(wiki=self.wiki,date=self.date,name=path.name,
                url=BASE+'/'+self.wiki+'/'+self.date+'/'+path.name,size=len(raw),sha1=hashlib.sha1(raw).hexdigest()))
        xml = dict(wiki=self.wiki,date=self.date,name=self.wiki+'-'+self.date+'-pages-meta-current.xml.bz2',
            url=BASE+'/'+self.wiki+'/'+self.date+'/'+self.wiki+'-'+self.date+'-pages-meta-current.xml.bz2',size=1,sha1=hashlib.sha1(b'x').hexdigest())
        selected.append(xml)
        status = self.root/'pagetable-dumpstatus.raw.json'
        args.dumpstatus.rename(status)
        (self.root/'capture.complete.json').write_bytes(figure.encoded(dict(wiki=self.wiki,date=self.date,
            namespace_mismatches=[],source_xml=xml,artifacts={status.name:figure.digest(status.read_bytes())})))
        (self.root/'defaults').rename(self.root/'figure-defaults')
        return dict(capture_root=self.root,manifest={'files':selected,'requested_editions':[self.wiki],'failures':[]},
            selected_inputs=selected,downloads=downloads,namespace_registry=self.namespace)

    def normal_capture_result(self, call, selected):
        # Only the capture boundary is stubbed: SQL replay and defaults validation
        # are real. Full streamed capture/replay is qualified by its own controls.
        root=call.output
        root.mkdir(exist_ok=True)
        outputs={}
        for role,filename in {**figure.ROLES,'file-metadata':figure.PROVIDER}.items():
            data=('fixture '+role).encode();(root/filename).write_bytes(data);outputs[role]=figure.digest(data)
        source=[row for row in selected if row['name'].endswith('.sql.gz')]
        record=dict(schema=figure.SCHEMA,wiki=self.wiki,date=self.date,source_dump_files=source,
            namespace_registry_sha256=figure.digest(self.namespace.read_bytes()),outputs=outputs)
        (root/figure.MANIFEST).write_bytes(figure.encoded(record))
        (root/figure.COMPLETE).write_bytes(figure.encoded(dict(schema=figure.SCHEMA,
            manifest_sha256=figure.digest((root/figure.MANIFEST).read_bytes()))))
        return record

    def test_normal_preparation_uses_real_sql_and_defaults_with_one_private_inventory(self):
        inputs=self.normal_build_inputs()
        def capture(call):
            self.assertEqual(call.output,self.root/'figure-inputs')
            self.assertEqual((call.wiki,call.date),(self.wiki,self.date))
            self.assertEqual(call.defaults,self.root/'figure-defaults')
            self.assertEqual((call.reuse,call.reuse_batch,call.log),([],[],[]))
            self.assertEqual((call.batch_size,call.delay,call.wall_seconds),(50,1,86400))
            inventory,stamps=call.prepared_inventory
            self.assertEqual(inventory['namespace_registry_sha256'],figure.digest(self.namespace.read_bytes()))
            self.assertEqual(set(stamps),set(call.sql))
            self.assertEqual(set(inventory['titles']),{'ملف:Example.svg'})
            self.assertIsNone(call.resume)
            return self.normal_capture_result(call,inputs['selected_inputs'])
        with patch.object(figure,'capture_files',side_effect=capture) as collect,patch.object(figure.site_info,'capture') as defaults,patch.object(figure,'source_inventory',wraps=figure.source_inventory) as replay:
            selected=figure.prepare_for_build(**inputs,network=True)
        collect.assert_called_once();defaults.assert_not_called();self.assertEqual(replay.call_count,1)
        self.assertEqual(set(selected),{*figure.ROLES,'file-metadata'})
        self.assertEqual({path.parent for path in selected.values()},{self.root/'figure-inputs'})

    def test_normal_offline_cache_reuse_joins_selected_manifest_and_namespace(self):
        inputs=self.normal_build_inputs();root=self.root/'figure-inputs';root.mkdir()
        (root/figure.COMPLETE).write_text('published fixture marker')
        record=dict(source_dump_files=[row for row in inputs['selected_inputs'] if row['name'].endswith('.sql.gz')],
            namespace_registry_sha256=figure.digest(self.namespace.read_bytes()))
        verified={role:(record,{}) for role in {*figure.ROLES,'file-metadata'}}
        with patch.object(figure,'verify_tuple',return_value=verified) as verify,patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults:
            selected=figure.prepare_for_build(**inputs)
        verify.assert_called_once();collect.assert_not_called();defaults.assert_not_called()
        self.assertEqual(set(selected),set(verified))
        record['source_dump_files'][0]=dict(record['source_dump_files'][0],sha1='0'*40)
        with patch.object(figure,'verify_tuple',return_value=verified),patch.object(figure,'capture_files') as collect,self.assertRaisesRegex(ValueError,'official SQL'):
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_not_called()

    def test_normal_missing_or_changed_official_sql_never_makes_http(self):
        inputs=self.normal_build_inputs()
        for case in ('unselected','wrong-sha','changed-bytes'):
            with self.subTest(case=case):
                selected=copy.deepcopy(inputs['selected_inputs'])
                paths=sorted((inputs['downloads']/self.wiki/self.date).glob('*.sql.gz'))
                original=paths[0].read_bytes()
                if case=='unselected':selected=[row for row in selected if not row['name'].endswith('-image.sql.gz')]
                elif case=='wrong-sha':selected[0]['sha1']='0'*40
                else:paths[0].write_bytes(bytes([original[0]^1])+original[1:])
                selected_manifest=dict(inputs['manifest'],files=selected)
                with patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults,self.assertRaises((ValueError,OSError,EOFError)):
                    figure.prepare_for_build(**dict(inputs,manifest=selected_manifest,selected_inputs=selected),network=True)
                collect.assert_not_called();defaults.assert_not_called();paths[0].write_bytes(original)

    def test_normal_invalid_published_capture_and_unproved_prefix_never_fall_back(self):
        inputs=self.normal_build_inputs();root=self.root/'figure-inputs';root.mkdir()
        with patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults,self.assertRaisesRegex(ValueError,'resume proof'):
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_not_called();defaults.assert_not_called()
        (root/figure.COMPLETE).write_text('invalid')
        with patch.object(figure,'verify_tuple',side_effect=ValueError('invalid published source')),patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults,self.assertRaisesRegex(ValueError,'invalid published'):
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_not_called();defaults.assert_not_called()

    def test_normal_offline_missing_capture_and_wrong_edition_do_not_acquire(self):
        inputs=self.normal_build_inputs()
        with patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults:
            with self.assertRaisesRegex(ValueError,'offline'):
                figure.prepare_for_build(**inputs)
            selected=copy.deepcopy(inputs['selected_inputs']);selected[0]['wiki']='enwiktionary'
            with self.assertRaises(ValueError):figure.prepare_for_build(**dict(inputs,selected_inputs=selected),network=True)
        collect.assert_not_called();defaults.assert_not_called()

    def test_normal_resume_passes_exact_proof_and_cannot_fetch_new_defaults(self):
        inputs=self.normal_build_inputs();root=self.root/'figure-inputs';root.mkdir()
        (root/'figure-failure-0001.json').write_text('closed stop fixture')
        proof=root/'figure-resume.json';proof.write_text('callee passes existing proof to the capture verifier')
        def resume(call):
            self.assertEqual(call.resume,proof)
            return self.normal_capture_result(call,inputs['selected_inputs'])
        with patch.object(figure,'capture_files',side_effect=resume) as collect,patch.object(figure.site_info,'capture') as defaults:
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_called_once();defaults.assert_not_called()

    def test_normal_missing_reviewed_defaults_sources_refuses_before_capture(self):
        inputs=self.normal_build_inputs()
        (self.root/'figure-defaults').rename(self.root/'unselected-original-defaults')
        with patch.object(figure,'capture_files') as collect,patch.object(figure.site_info,'capture') as defaults,self.assertRaises((ValueError,OSError)):
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_not_called();defaults.assert_not_called()

    def test_normal_namespace_or_sql_drift_after_preflight_is_not_published(self):
        inputs=self.normal_build_inputs();original=self.namespace.read_bytes()
        def capture(call):
            result=self.normal_capture_result(call,inputs['selected_inputs'])
            self.namespace.write_bytes(original+b'\n')
            return result
        with patch.object(figure,'capture_files',side_effect=capture),self.assertRaisesRegex(ValueError,'changed before publication'):
            figure.prepare_for_build(**inputs,network=True)

    def test_normal_resume_uses_latest_failure_proof_without_old_fallback(self):
        inputs=self.normal_build_inputs();root=self.root/'figure-inputs';root.mkdir()
        (root/'figure-failure-0001.json').write_text('first closed stop')
        first=root/'figure-resume.json';first.write_text('first proof preserved')
        (root/'figure-failure-0002.json').write_text('second closed stop')
        with patch.object(figure,'capture_files') as collect,self.assertRaisesRegex(ValueError,'Latest Figure failure'):
            figure.prepare_for_build(**inputs,network=True)
        collect.assert_not_called()
        latest=root/'figure-resume-0002.json';latest.write_text('second proof')
        def resume(call):
            self.assertEqual(call.resume,latest)
            self.assertEqual(first.read_text(),'first proof preserved')
            return self.normal_capture_result(call,inputs['selected_inputs'])
        with patch.object(figure,'capture_files',side_effect=resume):
            figure.prepare_for_build(**inputs,network=True)

    def test_normal_acquires_defaults_from_existing_reviewed_leaves_without_new_source_copy(self):
        inputs=self.normal_build_inputs()
        (self.root/'figure-defaults').rename(self.root/'unselected-original-defaults')
        real_capture=figure.site_info.capture
        figure.site_info.capture(argparse.Namespace(wiki=self.wiki,date=self.date,namespace_registry=self.namespace,
            primary_sources=self.primary,output=self.root/'site-info',delay=0,wall_seconds=30,figure_defaults=False),
            transport=lambda *_:(200,{},figure.encoded(self.data)),sleep=lambda _:None)
        original={path.name:path.read_bytes()for path in (self.root/'site-info').iterdir()}
        def defaults(call):
            self.assertEqual(call.primary_sources,self.root/'site-info')
            self.assertEqual(call.primary_sources_prefix,'site-info.source-')
            self.assertEqual(call.namespace_registry,self.namespace)
            self.assertTrue(call.figure_defaults)
            return real_capture(call,transport=lambda *_:(200,{},figure.encoded(self.data)),sleep=lambda _:None)
        with patch.object(figure.site_info,'capture',side_effect=defaults) as default_capture,patch.object(figure,'capture_files',side_effect=lambda call:self.normal_capture_result(call,inputs['selected_inputs'])):
            figure.prepare_for_build(**inputs,network=True)
        default_capture.assert_called_once()
        self.assertEqual(original,{path.name:path.read_bytes()for path in (self.root/'site-info').iterdir()})
        prepared=figure.site_info.validate_snapshot(self.root/'figure-defaults'/figure.site_info.SNAPSHOT,self.wiki,self.date)
        self.assertEqual(prepared['profile'],figure.site_info.FIGURE_PROFILE)

    def test_normal_resolver_prepares_and_reuses_real_five_role_stream(self):
        inputs = self.normal_build_inputs()
        calls = []
        def transport(url, timeout):
            calls.append(url)
            return 200, {}, figure.encoded(self.response())
        with patch.object(figure.evidence, 'get_response', side_effect=transport):
            paths = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'],
                inputs['selected_inputs'], inputs['downloads'], self.namespace, {}, metadata_network='allow')
        self.assertEqual(len(calls), 1)
        self.assertEqual(set(paths), {*figure.ROLES, 'file-metadata'})
        result = figure.verify(self.root/'figure-inputs')
        self.assertEqual(result['coverage']['files'], 1)
        self.assertTrue(all(row['url'].startswith('https://dumps.wikimedia.org/') for row in result['source_dump_files']))
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('published capture recaptured')):
            reused = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'],
                inputs['selected_inputs'], inputs['downloads'], self.namespace, {}, metadata_network='offline')
        self.assertEqual(paths, reused)


    def write_normal_retained(self, name, response, titles, *, wiki=None, namespace=None):
        wiki = wiki or self.wiki
        namespace = namespace or self.namespace.read_bytes()
        donor = self.root/name;donor.mkdir()
        (donor/metadata.NAMESPACE).write_bytes(namespace)
        registry = figure.evidence.Registry(namespace, wiki, self.date)
        _, batch = metadata.request_batch(donor, 1, titles, registry,
            lambda *_: (200, {}, figure.encoded(response)), lambda _: None,
            figure.time.monotonic()+30, 1, figure_axes=True)
        record = {'wiki': wiki, 'date': self.date, 'batch': batch,
            'artifacts': {p.name: {'size': p.stat().st_size, 'sha256': figure.digest(p.read_bytes())} for p in donor.iterdir()}}
        path = donor/'selected-facts.json';path.write_bytes(figure.encoded(record))
        return path

    def test_normal_resolver_imports_base_and_observed_batch_without_refetch_and_checks_cached_plan(self):
        old_args = self.args
        with patch.object(self, 'args', side_effect=lambda: old_args(links=('Example.svg', 'Missing.ogg'))):
            inputs = self.normal_build_inputs()
        base, observation, _ = self.svg_observation()
        missing = '\u0645\u0644\u0641:Missing.ogg'
        base['query']['pages'].append({'title': missing, 'ns': 6, 'missing': True, 'imagerepository': ''})
        original = self.write_normal_retained('normal-retained', base, ['\u0645\u0644\u0641:Example.svg', missing])
        observed = self.write_svg_observation(observation)
        before = {str(p): p.read_bytes() for root in (original.parent, observed.parent) for p in root.iterdir()}
        selected = (observed, original)
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('retained batch was refetched')):
            paths = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                inputs['downloads'], self.namespace, {}, metadata_network='allow', figure_reuse_batches=selected)
        result = figure.verify(self.root/'figure-inputs')
        self.assertEqual(result['coverage']['observed_svg_files'], 1)
        self.assertEqual(result['coverage']['provider']['negative_rows'], 1)
        self.assertEqual(set(paths), {*figure.ROLES, 'file-metadata'})
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('cached capture made HTTP')):
            reused = builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                inputs['downloads'], self.namespace, {}, metadata_network='offline', figure_reuse_batches=selected)
        self.assertEqual(reused, paths)
        self.assertEqual(before, {str(p): p.read_bytes() for root in (original.parent, observed.parent) for p in root.iterdir()})
        # A different declared record is not silently ignored by a completed cache.
        different = original.with_name('other-declaration.json');different.write_bytes(original.read_bytes())
        with patch.object(figure.evidence, 'get_response', side_effect=AssertionError('cache mismatch made HTTP')):
            with self.assertRaisesRegex(ValueError, 'does not contain'):
                builder.resolve_figure_snapshot_options(self.root, inputs['manifest'], inputs['selected_inputs'],
                    inputs['downloads'], self.namespace, {}, metadata_network='allow', figure_reuse_batches=(different, observed))
        self.assertEqual(figure.verify(self.root/'figure-inputs'), result)

    def test_explicit_batch_selection_authenticates_unrelated_editions_and_rejects_wrong_or_duplicate_records(self):
        original = self.write_normal_retained('selection-base', self.response(), ['\u0645\u0644\u0641:Example.svg'])
        unrelated = self.response();unrelated['query']['general'].update(wikiid='dewiktionary', server='https://de.wiktionary.org')
        namespace = self.namespace.read_bytes().replace(('# wiki\t'+self.wiki).encode(), b'# wiki\tdewiktionary')
        foreign = self.write_normal_retained('selection-foreign', unrelated,
            ['\u0645\u0644\u0641:Example.svg'], wiki='dewiktionary', namespace=namespace)
        selected = figure.select_reuse_batches((foreign, original), self.wiki, self.date, self.namespace.read_bytes())
        self.assertEqual([row['path'] for row in selected], [str(original)])
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            figure.select_reuse_batches((original, original), self.wiki, self.date, self.namespace.read_bytes())
        alias_b = self.response('ملف:B.svg')
        alias_b['query']['redirects'] = [{'from': 'ملف:A.svg', 'to': 'ملف:B.svg'}]
        alias_c = self.response('ملف:C.svg')
        alias_c['query']['redirects'] = [{'from': 'ملف:B.svg', 'to': 'ملف:C.svg'}]
        first_alias = self.write_normal_retained('alias-b', alias_b, ['ملف:A.svg'])
        second_alias = self.write_normal_retained('alias-c', alias_c, ['ملف:B.svg'])
        with self.assertRaisesRegex(ValueError, 'canonical alias'):
            figure.select_reuse_batches((first_alias, second_alias), self.wiki, self.date, self.namespace.read_bytes())
        raw = original.read_bytes();record = json.loads(raw)
        record['date'] = '20260901';original.write_bytes(figure.encoded(record))
        with self.assertRaises(ValueError):
            figure.select_reuse_batches((original,), self.wiki, self.date, self.namespace.read_bytes())
        original.write_bytes(raw)
        foreign_record = json.loads(foreign.read_bytes())
        receipt_path = foreign.parent/foreign_record['batch']['accepted_receipt']
        receipt = json.loads(receipt_path.read_text());receipt['status'] = 403
        receipt_path.write_bytes(figure.encoded(receipt))
        foreign_record['artifacts'][receipt_path.name] = {'size': receipt_path.stat().st_size, 'sha256': figure.digest(receipt_path.read_bytes())}
        foreign.write_bytes(figure.encoded(foreign_record))
        with self.assertRaisesRegex(ValueError, 'accepted receipt'):
            figure.select_reuse_batches((foreign, original), self.wiki, self.date, self.namespace.read_bytes())

    def test_observed_basename_validation_preserves_fixed_batch_contract_and_rejects_paths(self):
        _, observation, _ = self.svg_observation()
        path = self.write_svg_observation(observation)
        original = json.loads(path.read_bytes())
        self.assertEqual(figure.retained_metadata_batch(path, self.wiki, self.date,
            self.namespace.read_bytes())['observed_svg_width_px'], 250)
        for name in ('../request01.json', '/request01.json', 'nested/request01.json', '..', 'request%2f01.json'):
            with self.subTest(name=name):
                changed = copy.deepcopy(original)
                changed['artifacts'][name] = changed['artifacts'].pop('request01.json')
                path.write_bytes(figure.encoded(changed))
                with self.assertRaisesRegex(ValueError, 'Unsafe observed'):
                    figure.retained_metadata_batch(path, self.wiki, self.date, self.namespace.read_bytes())
        path.write_bytes(figure.encoded(original))
        fixed = self.write_normal_retained('fixed-names', self.response(), ['\u0645\u0644\u0641:Example.svg'])
        record = json.loads(fixed.read_text())
        old_name = record['batch']['request']
        record['artifacts']['request01.json'] = record['artifacts'].pop(old_name)
        (fixed.parent/'request01.json').write_bytes((fixed.parent/old_name).read_bytes())
        record['batch']['request'] = 'request01.json'
        fixed.write_bytes(figure.encoded(record))
        with self.assertRaisesRegex(ValueError, 'Unsafe file metadata'):
            figure.retained_metadata_batch(fixed, self.wiki, self.date, self.namespace.read_bytes())


    def combined_response(self, titles, *, light=False):
        value = self.response(titles[0])
        value['query']['pages'] = [self.response(title)['query']['pages'][0] for title in titles]
        if light:
            for page in value['query']['pages']:
                info = page['imageinfo'][0]
                info.pop('metadata', None)
                info.update(mime='image/vnd.djvu', mediatype='BITMAP')
        return value

    def make_oversize_prefix(self, *, normal=False):
        names = ('A.svg', 'B.svg', 'C.djvu', 'D.svg')
        inputs = None
        if normal:
            old_args = self.args
            with patch.object(self, 'args', side_effect=lambda: old_args(links=names)):
                inputs = self.normal_build_inputs()
            args = argparse.Namespace(wiki=self.wiki, date=self.date, defaults=self.root/'figure-defaults',
                dumpstatus=self.root/'pagetable-dumpstatus.raw.json',
                sql=[inputs['downloads']/self.wiki/self.date/row['name'] for row in inputs['selected_inputs'] if row['name'].endswith('.sql.gz')],
                output=self.root/'figure-inputs', reuse=[], batch_size=2, delay=1, wall_seconds=30)
        else:
            args = self.args(links=names);args.batch_size = 2
        calls, clock = [], [0.0]
        def transport(url, timeout):
            titles = parse_qs(urlsplit(url).query)['titles'][0].split('|')
            calls.append(titles)
            if len(calls) == 2:
                return 200, {}, b'{' + b' ' * figure.MAX_RESPONSE
            return 200, {}, figure.encoded(self.combined_response(titles))
        with patch.object(figure.time, 'monotonic', side_effect=lambda:clock[0]):
            with self.assertRaisesRegex(ValueError, 'Oversized API response'):
                figure.capture_files(args, transport=transport, sleep=lambda d:clock.__setitem__(0,clock[0]+d))
        self.assertEqual(len(calls), 2)
        old_root = args.output
        failure_path = old_root/'figure-failure-0001.json'
        failure = json.loads(failure_path.read_text())
        self.assertEqual(failure['committed_batches'], 1)
        def descriptor(path):
            raw = path.read_bytes()
            return {'path':str(path.resolve()), 'bytes':len(raw), 'sha256':figure.digest(raw)}
        closure = {'outcome':'FAILED-PHYSICALLY-SOURCE-CLOSED', 'source_after':True, 'reaped':True,
            'dual_proc_absence':True, 'ps_absence':True, 'allocation_released':True, 'terminal':1,
            'capture_root':str(old_root.resolve()), 'capture_plan_sha256':failure['plan_sha256'],
            'capture_failure':descriptor(failure_path), 'committed_batches':1,
            'actual_request':descriptor(old_root/'file-metadata.request-000002.json'),
            'actual_receipt':descriptor(old_root/'file-metadata.response-000002-01.receipt.json'),
            'actual_response':descriptor(old_root/'file-metadata.response-000002-01.raw.json'),
            'raw_stream':descriptor(old_root/figure.ROLES['figure-sizing-raw'])}
        closure_path = self.root/'closed-prefix-closure.json';closure_path.write_bytes(figure.encoded(closure))
        kept = self.root/'closed-prefix-original';old_root.rename(kept)
        proof = {'schema':figure.CLOSED_PREFIX_SCHEMA, 'wiki':self.wiki, 'date':self.date,
            'source_root':str(kept.resolve()), 'original_root':str(old_root.resolve()),
            'closure':descriptor(closure_path), 'light_titles':['ملف:C.djvu']}
        proof_dir = self.root/'prefix-reference';proof_dir.mkdir()
        proof_path = proof_dir/'closed-prefix.json';proof_path.write_bytes(figure.encoded(proof))
        args.reuse_batch = [proof_path]
        return args, proof_path, inputs

    def test_closed_oversize_prefix_replays_before_http_and_keeps_exact_remaining_coverage(self):
        args, proof_path, _ = self.make_oversize_prefix()
        record = json.loads(proof_path.read_text())
        original = Path(record['source_root'])
        before = {p.name:p.read_bytes() for p in original.iterdir()}
        prefix = figure.read_closed_prefix(proof_path)
        self.assertEqual(len(prefix['document']['records']), 2)
        self.assertEqual(prefix['failed_titles'], ['ملف:C.djvu', 'ملف:D.svg'])
        calls, clock = [], [0.0]
        def transport(url, timeout):
            query = parse_qs(urlsplit(url).query)
            titles = query['titles'][0].split('|');light = 'metadata' not in query['iiprop'][0].split('|')
            calls.append((titles, light))
            return 200, {}, figure.encoded(self.combined_response(titles, light=light))
        with patch.object(figure.time, 'monotonic', side_effect=lambda:clock[0]):
            result = figure.capture_files(args, transport=transport, sleep=lambda d:clock.__setitem__(0,clock[0]+d))
        self.assertEqual(calls, [(['ملف:D.svg'], False), (['ملف:C.djvu'], True)])
        self.assertEqual(result['coverage']['files'], 4)
        document = self.stream_document(args.output)
        self.assertEqual({r['requested_file'] for r in document['records']}, {'ملف:A.svg','ملف:B.svg','ملف:C.djvu','ملف:D.svg'})
        self.assertEqual(next(r['state'] for r in document['records'] if r['requested_file']=='ملف:C.djvu'), 'unsupported')
        self.assertEqual(figure.verify(args.output), result)
        self.assertEqual(before, {p.name:p.read_bytes() for p in original.iterdir()})
        self.assertIn(b'C.djvu', (args.output/figure.PROVIDER).read_bytes())
        self.assertEqual(figure.select_reuse_batches((proof_path,), self.wiki, self.date, self.namespace.read_bytes())[0]['kind'], 'closed-prefix')

    def test_metadata_light_never_authorizes_tiff_supported_zero_axes_or_unknown_identity(self):
        for mime, media, width, height in [('image/tiff','BITMAP',800,600),('image/png','BITMAP',0,0),('image/svg+xml','DRAWING',800,600),('', 'BITMAP',800,600),('image/vnd.djvu','MULTIPAGE',800,600)]:
            with self.subTest(mime=mime):
                response = self.response('ملف:Candidate.bin')
                info = response['query']['pages'][0]['imageinfo'][0]
                info.pop('metadata', None);info.update(mime=mime,mediatype=media,width=width,height=height)
                with self.assertRaises(ValueError):
                    figure.validate_metadata_light(self.batch('ملف:Candidate.bin', response), self.namespace.read_bytes(), self.wiki, self.date)
        missing = self.response('ملف:Missing.bin')
        missing['query']['pages'][0] = {'title':'ملف:Missing.bin','ns':6,'missing':True,'imagerepository':''}
        self.assertEqual(figure.validate_metadata_light(self.batch('ملف:Missing.bin', missing), self.namespace.read_bytes(), self.wiki, self.date)['records'][0]['state'], 'missing')
        light = self.combined_response(['ملف:Candidate.djvu'], light=True)
        self.assertEqual(figure.validate_metadata_light(self.batch('ملف:Candidate.djvu', light), self.namespace.read_bytes(), self.wiki, self.date)['records'][0]['state'], 'unsupported')

    def test_closed_prefix_output_cannot_mutate_preserved_source_before_refusal(self):
        args, proof_path, _ = self.make_oversize_prefix()
        root = Path(json.loads(proof_path.read_text())['source_root'])
        before = {p.name:p.read_bytes() for p in root.iterdir()}
        args.output = root/'nested'/'new-capture'
        with self.assertRaisesRegex(ValueError, 'cannot modify its closed prefix'):
            figure.capture_files(args, transport=lambda *_:self.fail('nested output made HTTP'))
        self.assertEqual(before, {p.name:p.read_bytes() for p in root.iterdir()})
        self.assertFalse((root/'nested').exists())

    def test_closed_prefix_rejects_changed_plan_prefix_and_unclosed_receipt_before_http(self):
        args, proof_path, _ = self.make_oversize_prefix()
        proof = json.loads(proof_path.read_text());original = Path(proof['source_root'])
        for filename in (figure.PLAN, figure.ROLES['figure-sizing-raw'], figure.FILE_REQUESTS):
            path=original/filename;raw=path.read_bytes();path.write_bytes(raw+b' ')
            with self.assertRaises(ValueError):figure.read_closed_prefix(proof_path)
            path.write_bytes(raw)
        closure_path=Path(proof['closure']['path']);old=closure_path.read_bytes()
        closure=json.loads(old);closure['allocation_released']=False
        closure_path.write_bytes(figure.encoded(closure));proof['closure'].update(bytes=closure_path.stat().st_size,sha256=figure.digest(closure_path.read_bytes()))
        proof_path.write_bytes(figure.encoded(proof))
        with self.assertRaisesRegex(ValueError,'physical and source closure'):
            figure.capture_files(args,transport=lambda *_:self.fail('unclosed prefix made HTTP'))
        self.assertFalse((args.output/figure.COMPLETE).exists())

    def test_closed_prefix_rejects_omitted_members_and_access_refusal_even_when_rehashed(self):
        _, proof_path, _ = self.make_oversize_prefix()
        proof=json.loads(proof_path.read_text());root=Path(proof['source_root'])
        closure_path=Path(proof['closure']['path']);closure=json.loads(closure_path.read_text())
        failure_path=root/'figure-failure-0001.json';failure=json.loads(failure_path.read_text())
        request_path=root/Path(closure['actual_request']['path']).name
        receipt_path=root/Path(closure['actual_receipt']['path']).name
        original_request=request_path.read_bytes();original_receipt=receipt_path.read_bytes()
        def refresh(path, field):
            raw=path.read_bytes();identity={'bytes':len(raw),'sha256':figure.digest(raw)}
            failure['artifacts'][path.name]=identity;closure[field].update(identity)
            failure_path.write_bytes(figure.encoded(failure));raw=failure_path.read_bytes()
            closure['capture_failure'].update(bytes=len(raw),sha256=figure.digest(raw))
            closure_path.write_bytes(figure.encoded(closure));raw=closure_path.read_bytes()
            proof['closure'].update(bytes=len(raw),sha256=figure.digest(raw));proof_path.write_bytes(figure.encoded(proof))
        request=json.loads(original_request);request['titles']=['ملف:C.djvu']
        request['query']=metadata.query_for(self.wiki,request['titles'],figure_axes=True)
        request['url']=metadata.query_url(self.wiki,request['titles'],figure_axes=True)
        request_path.write_bytes(figure.encoded(request));refresh(request_path,'actual_request')
        with self.assertRaisesRegex(ValueError,'next uncommitted batch'):figure.read_closed_prefix(proof_path)
        request_path.write_bytes(original_request);refresh(request_path,'actual_request')
        receipt=json.loads(original_receipt);receipt['status']=403;receipt['error']='API HTTP status 403'
        receipt_path.write_bytes(figure.encoded(receipt));refresh(receipt_path,'actual_receipt')
        with self.assertRaisesRegex(ValueError,'oversized HTTP 200'):figure.read_closed_prefix(proof_path)

    def test_normal_resolver_consumes_closed_prefix_and_reuses_complete_plan_offline(self):
        args, proof_path, inputs = self.make_oversize_prefix(normal=True)
        calls=[]
        def transport(url, timeout):
            query=parse_qs(urlsplit(url).query);titles=query['titles'][0].split('|')
            light='metadata' not in query['iiprop'][0].split('|');calls.append((titles,light))
            return 200,{},figure.encoded(self.combined_response(titles,light=light))
        with patch.object(figure.evidence,'get_response',side_effect=transport):
            paths=builder.resolve_figure_snapshot_options(self.root,inputs['manifest'],inputs['selected_inputs'],
                inputs['downloads'],self.namespace,{},metadata_network='allow',figure_reuse_batches=(proof_path,))
        self.assertEqual(calls,[(['ملف:D.svg'],False),(['ملف:C.djvu'],True)])
        with patch.object(figure.evidence,'get_response',side_effect=AssertionError('complete prefix recaptured')):
            reused=builder.resolve_figure_snapshot_options(self.root,inputs['manifest'],inputs['selected_inputs'],
                inputs['downloads'],self.namespace,{},metadata_network='offline',figure_reuse_batches=(proof_path,))
        self.assertEqual(paths,reused)
        generation = self.root/'figure-inputs'
        plan_path = generation/figure.PLAN;old_plan=plan_path.read_bytes()
        manifest_path = generation/figure.MANIFEST;old_manifest=manifest_path.read_bytes()
        marker_path = generation/figure.COMPLETE;old_marker=marker_path.read_bytes()
        plan=json.loads(old_plan);plan['metadata_light_titles']=[]
        plan_path.write_bytes(figure.encoded(plan))
        manifest=json.loads(old_manifest)
        manifest['artifacts'][figure.PLAN]={'bytes':plan_path.stat().st_size,'sha256':figure.digest(plan_path.read_bytes())}
        manifest_path.write_bytes(figure.encoded(manifest))
        marker_path.write_bytes(figure.encoded({'schema':figure.SCHEMA,'manifest_sha256':figure.digest(manifest_path.read_bytes())}))
        with self.assertRaisesRegex(ValueError,'metadata-light scope'):
            figure.verify(generation)
        plan_path.write_bytes(old_plan);manifest_path.write_bytes(old_manifest);marker_path.write_bytes(old_marker)
        plan_path=self.root/'figure-inputs'/figure.PLAN;plan=json.loads(plan_path.read_text());plan['closed_prefixes']=[]
        plan_path.write_bytes(figure.encoded(plan))
        with self.assertRaises(ValueError):figure.require_reuse_coverage(self.root/'figure-inputs',figure.select_reuse_batches((proof_path,),self.wiki,self.date,self.namespace.read_bytes()))


if __name__ == '__main__':
    unittest.main()
