import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest

import report_corpus_progress as report


class ReportingTests(unittest.TestCase):
    """Small self-contained metadata fixtures; no campaign checkout is required."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.docs = {}

        def put(name, value):
            path = self.root / name
            raw = report.encoded(value)
            path.write_bytes(raw)
            self.docs[str(path)] = copy.deepcopy(value)
            return report.ref(path, raw)
        self.put = put

        def row(edition, number, elapsed, passed=False):
            directory = self.root / (edition + '-attempt' + str(number))
            directory.mkdir()
            result = put(str(directory / 'result.json'), {'elapsed_seconds': elapsed})
            publication = put(edition + '-' + str(number) + '-complete.json', dict(edition=edition, date='20261001', input_pages=11, fallback_pages=2)) if passed else None
            outcome = 'passed-closed' if passed else 'failed-closed'
            source_fingerprint = 'qualified-' + edition
            configuration = put(edition + '-' + str(number) + '-driver.json', dict(
                edition=edition, date='20261001', attempt_number=number,
                attempt_directory=str(directory), source_fingerprint=source_fingerprint))
            owner = put(edition + '-' + str(number) + '-owner.json', dict(driver_configuration=configuration))
            closure = put(edition + '-' + str(number) + '-closure.json', dict(outcome=outcome, source_guard=True, cleanup_proven=True,
                configuration=owner, production_started=True, production_elapsed_seconds=elapsed, result=result))
            return dict(edition=edition, date='20261001', attempt_number=number, attempt_directory=str(directory),
                outcome=outcome, complete=publication, input_pages=11 if passed else None, elapsed_seconds=elapsed,
                closure_ref=closure, result=result, source_fingerprint=source_fingerprint, publication_status='built' if passed else None)

        def ledger(rows, excluded):
            known = sum(r['elapsed_seconds'] for r in rows)
            return dict(attempts=rows, excluded_closed_owners=excluded, aggregate=dict(closed_production_attempts=len(rows),
                mechanically_published_editions=1, unknown_production_attempt_durations=0,
                known_production_attempt_seconds=known, production_attempt_seconds=known,
                unique_successful_xml_input_pages=11, retry_inclusive_xml_input_pages_per_second=11/known))

        self.inventory = dict(edition_count=9, missing=[], rows=[dict(wiki=x) for x in 'abcdefghi'])
        self.before = ledger([row('b',1,2.5,True), row('c',1,3.0)], [])
        exclusions = [put('excluded'+str(i)+'.json', dict(cleanup_proven=True, production_started=False)) for i in range(2)]
        self.ledger = ledger(copy.deepcopy(self.before['attempts']) + [row('d',1,4.0),row('e',1,5.0),row('f',1,6.0)], exclusions)
        self.make_row = row
        before_ref = put('before.json', self.before)
        ledger_ref = put('ledger.json', self.ledger)
        old_ledger_ref = dict(before_ref, path=ledger_ref['path'])
        inventory_ref = put('inventory.json', self.inventory)
        historical_ref = put('historical.json', {'historical': True})
        reconciliation_ref = put('historical-inventory.json', {'inventory': True})
        self.baseline = dict(history=dict(attempted_editions=['a'], attempted_count=1, inventory=inventory_ref,
            historical_ledger=historical_ref, inventory_reconciliation=reconciliation_ref))
        baseline_ref = put('baseline.json', self.baseline)
        ingestion_ref = put('ingestion.json', dict(passed=True, ledger_after=ledger_ref))
        campaign_ref = put('prior-campaign.json', dict(source_ledger=old_ledger_ref, source_reconciliation=reconciliation_ref,
            aggregate={}, table={}, newly_mechanically_published_editions=1))
        ids = [{k:r[k] for k in ('edition','attempt_number','attempt_directory')} for r in self.before['attempts']]
        self.old = dict(sources=dict(campaign_ledger=old_ledger_ref, historical_ledger51=historical_ref,
                campaign_report=campaign_ref, latest_campaign_reconciliation=reconciliation_ref),
            progress=dict(requested_editions=9,initial_mechanical_editions=1,campaign_new_mechanical_editions=1,
                total_mechanical_publications=2,eligible_mechanical_publications=1),
            inventory_disposition=dict(mechanical_publications=2,attempted_unpublished=1,deferred_without_production=0,not_started_in_recorded_ledgers=6),
            deduplication=dict(identity_inventory=dict(campaign_logical_attempts=ids),historical_duration_rows=1),
            combined_build_clock=dict(sealed_historical_baseline_seconds=10,historical_known_attempt_seconds=7,
                whole_goal_pages_per_second=None,exact_retry_inclusive_seconds=None),
            campaign_only_rate={},per_timing_eligible_edition_with_recorded_work=[
                dict(edition=r['edition'],known_retry_inclusive_seconds=r['elapsed_seconds'],duration_complete=True,
                    unknown_duration_attempts=0,historical_closed_duration_rows=0,campaign_closed_production_attempts=1,
                    sealed_historical_baseline_seconds=0,semantic_acceptance=False,
                    current_campaign_selected_attempt=r['attempt_number'] if r['complete'] else None,
                    current_campaign_input_xml_pages=r['input_pages'],current_campaign_latest_successful_seconds=r['elapsed_seconds'] if r['complete'] else None,
                    current_mechanical_status=r['publication_status']) for r in self.before['attempts']],
            latest_first_publications=[{'edition':'b','historical':True}],latest_production_failures=[],
            current_normal_sequence_closure={'historical':True})
        old_ref = put('prior-report.json', self.old)
        self.refs = {'prior-report':old_ref,'prior-ledger':before_ref,'ledger':ledger_ref,
            'inventory':inventory_ref,'baseline':baseline_ref,'reconciliation':ingestion_ref}

    def derive(self):
        return report.derive(self.old,self.before,self.ledger,self.inventory,self.baseline,lambda ref:self.docs[ref['path']])


    def test_authenticated_external_result_path_accepted(self):
        row = self.ledger['attempts'][-1]
        external = self.put('carrier-commands-result.json', dict(elapsed_seconds=row['elapsed_seconds']))
        row['result'] = external
        self.docs[row['closure_ref']['path']]['result'] = external
        derived = self.derive()
        self.assertEqual(derived['deduplication']['campaign_production_rows'], 5)
        self.assertEqual(derived['combined_build_clock']['campaign_known_attempt_seconds'], 20.5)

    def test_wrong_authenticated_attempt_identity_rejected(self):
        row = self.ledger['attempts'][-1]
        leaf = self.docs[row['closure_ref']['path']]
        owner = self.docs[leaf['configuration']['path']]
        cfg = self.docs[owner['driver_configuration']['path']]
        for key, value in [('edition','different'),('date','20260901'),('attempt_number',2),
                           ('attempt_directory',str(self.root/'wrong')),('source_fingerprint','different')]:
            with self.subTest(key=key):
                original = cfg[key]
                cfg[key] = value
                with self.assertRaisesRegex(ValueError, 'attempt/configuration'): self.derive()
                cfg[key] = original

    def test_external_result_without_configuration_rejected(self):
        row = self.ledger['attempts'][-1]
        leaf = self.docs[row['closure_ref']['path']]
        external = self.put('unbound-result.json', dict(elapsed_seconds=row['elapsed_seconds']))
        row['result'] = external
        leaf['result'] = external
        del leaf['configuration']
        with self.assertRaises(KeyError): self.derive()

    def test_external_result_swap_still_rejected(self):
        row = self.ledger['attempts'][-1]
        row['result'] = self.put('swapped-result.json', dict(elapsed_seconds=row['elapsed_seconds']))
        with self.assertRaisesRegex(ValueError, 'attempt/result'): self.derive()

    def test_closed_delta_preserves_history_and_exclusions(self):
        new = self.derive()
        self.assertEqual([new['inventory_disposition'][k] for k in ('mechanical_publications','attempted_unpublished','not_started_in_recorded_ledgers')],[2,4,3])
        self.assertEqual(new['deduplication']['campaign_production_rows'],5)
        self.assertEqual([r['edition'] for r in new['report_refresh_delta']['production_attempts']],['d','e','f'])
        self.assertEqual(len(new['report_refresh_delta']['excluded_closed_owners']),2)
        self.assertEqual(new['latest_first_publications'],self.old['latest_first_publications'])
        self.assertEqual(new['current_normal_sequence_closure'],self.old['current_normal_sequence_closure'])
        self.assertIsNone(new['combined_build_clock']['exact_retry_inclusive_seconds'])
        self.assertFalse(new['report_refresh_delta']['semantic_acceptance'])

    def test_rewritten_production_prefix_rejected(self):
        self.ledger['attempts'][0]['source_fingerprint'] = 'changed'
        with self.assertRaisesRegex(ValueError,'prefix'): self.derive()

    def test_new_publication_counts_once_without_semantic_credit(self):
        self.ledger['attempts'][-1] = self.make_row('f',2,6.0,True)
        self.ledger['aggregate'].update(mechanically_published_editions=2,unique_successful_xml_input_pages=22,
            retry_inclusive_xml_input_pages_per_second=22/20.5)
        new = self.derive()
        self.assertEqual(new['inventory_disposition']['mechanical_publications'],3)
        self.assertEqual(new['latest_first_publication']['edition'],'f')
        self.assertEqual(new['latest_first_publication']['fallback_pages'],2)
        self.assertFalse(new['latest_first_publication']['semantic_acceptance'])

    def test_failed_repair_retains_previous_success_and_adds_time(self):
        self.ledger['attempts'].append(self.make_row('b',2,7.0))
        self.ledger['aggregate'].update(closed_production_attempts=6,known_production_attempt_seconds=27.5,
            production_attempt_seconds=27.5,retry_inclusive_xml_input_pages_per_second=11/27.5)
        new = self.derive()
        self.assertEqual(new['inventory_disposition']['mechanical_publications'],2)
        self.assertEqual(new['latest_first_publications'],self.old['latest_first_publications'])
        self.assertEqual(new['latest_production_failure']['edition'],'b')
        self.assertFalse(new['latest_production_failure']['automatic_retry'])
        entry = next(r for r in new['per_timing_eligible_edition_with_recorded_work'] if r['edition']=='b')
        self.assertEqual(entry['known_retry_inclusive_seconds'],9.5)
        self.assertEqual(entry['current_campaign_selected_attempt'],1)

    def test_truncated_exclusions_rejected(self):
        self.before['excluded_closed_owners'] = [self.ledger['excluded_closed_owners'][0]]
        self.ledger['excluded_closed_owners'] = []
        with self.assertRaisesRegex(ValueError,'exclusion prefix'): self.derive()

    def test_duplicate_attempt_rejected(self):
        self.ledger['attempts'].append(copy.deepcopy(self.ledger['attempts'][-1]))
        with self.assertRaisesRegex(ValueError,'duplicate attempt'): self.derive()

    def test_unknown_inventory_edition_rejected(self):
        self.ledger['attempts'][-1]['edition'] = 'unknown'
        with self.assertRaisesRegex(ValueError,'unknown edition'): self.derive()

    def test_changed_requested_inventory_rejected(self):
        self.inventory['rows'].pop(); self.inventory['edition_count'] -= 1
        with self.assertRaisesRegex(ValueError,'requested inventory'): self.derive()

    def test_prior_identity_join_rejected(self):
        self.old['deduplication']['identity_inventory']['campaign_logical_attempts'].pop()
        with self.assertRaisesRegex(ValueError,'identity mismatch'): self.derive()

    def test_failed_publication_credit_rejected(self):
        self.ledger['attempts'][-1]['complete'] = self.ledger['attempts'][0]['complete']
        with self.assertRaisesRegex(ValueError,'failed attempt'): self.derive()

    def test_wrong_aggregate_rejected(self):
        self.ledger['aggregate']['closed_production_attempts'] += 1
        with self.assertRaisesRegex(ValueError,'attempt aggregate'): self.derive()

    def test_rate_must_match_complete_duration_and_pages(self):
        editions = {r['wiki'] for r in self.inventory['rows']}
        self.ledger['aggregate']['retry_inclusive_xml_input_pages_per_second'] += 1
        with self.assertRaisesRegex(ValueError,'rate aggregate'): self.derive()
        elapsed = self.ledger['attempts'][-1]['elapsed_seconds']
        self.ledger['attempts'][-1]['elapsed_seconds'] = None
        agg = self.ledger['aggregate']; agg['known_production_attempt_seconds'] -= elapsed
        agg['unknown_production_attempt_durations'] = 1; agg['production_attempt_seconds'] = None
        with self.assertRaisesRegex(ValueError,'rate aggregate'): report.validate_ledger(self.ledger,editions)
        agg['retry_inclusive_xml_input_pages_per_second'] = None
        report.validate_ledger(self.ledger,editions)
        empty = dict(attempts=[],excluded_closed_owners=[],aggregate=dict(closed_production_attempts=0,
            mechanically_published_editions=0,unknown_production_attempt_durations=0,known_production_attempt_seconds=0,
            unique_successful_xml_input_pages=0,production_attempt_seconds=0,retry_inclusive_xml_input_pages_per_second=0))
        with self.assertRaisesRegex(ValueError,'rate aggregate'): report.validate_ledger(empty,editions)
        empty['aggregate']['retry_inclusive_xml_input_pages_per_second'] = None
        report.validate_ledger(empty,editions)

    def test_missing_cleanup_proof_rejected(self):
        self.docs[self.ledger['attempts'][-1]['closure_ref']['path']]['cleanup_proven'] = False
        with self.assertRaisesRegex(ValueError,'unproved production'): self.derive()

    def test_result_identity_swap_rejected(self):
        self.docs[self.ledger['attempts'][-1]['closure_ref']['path']]['result'] = self.ledger['attempts'][-2]['result']
        with self.assertRaisesRegex(ValueError,'attempt/result'): self.derive()

    def test_exclusion_cannot_hide_production(self):
        self.docs[self.ledger['excluded_closed_owners'][-1]['path']]['production_started'] = True
        with self.assertRaisesRegex(ValueError,'zero-production'): self.derive()

    def test_stale_live_ledger_hash_rejected(self):
        path = self.root/'stale.json'; raw = b'{"attempts": []}\n'; path.write_bytes(raw)
        pinned = report.ref(path,raw); path.write_bytes(b'{"attempts": [1]}\n')
        with self.assertRaisesRegex(ValueError,'stale input hash'): report.pinned(pinned,[])

    def test_cli_and_fresh_output_rule(self):
        args = []
        for key,pinned in self.refs.items(): args.extend(['--'+key,json.dumps(pinned)])
        outputs = {}
        for key in ('output','campaign-output','csv-output','markdown-output'):
            outputs[key] = self.root/key; args.extend(['--'+key,str(outputs[key])])
        with contextlib.redirect_stdout(io.StringIO()): report.main(args)
        new = json.loads(outputs['output'].read_text())
        self.assertEqual(new['sources']['campaign_ledger'],self.refs['ledger'])
        self.assertEqual(new['inventory_disposition']['not_started_in_recorded_ledgers'],3)
        self.assertEqual(len(new['deduplication']['identity_inventory']['campaign_logical_attempts']),5)
        with self.assertRaisesRegex(ValueError,'fresh and disjoint'): report.main(args)
        report.pinned(self.refs['ledger'],[])

    def test_wrong_prior_snapshot_hash_rejected(self):
        wrong = dict(self.refs['prior-ledger'],sha256='0'*64)
        with self.assertRaisesRegex(ValueError,'stale input hash'): report.pinned(wrong,[])


if __name__ == '__main__':
    unittest.main()
