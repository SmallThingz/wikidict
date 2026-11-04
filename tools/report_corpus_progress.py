"""Reusable report derivation, extracted from the retained report-refresh producer.
No ingestion, workload, acceptance decision, generated-code wrapper or ReportN literals.
Historical producers/reports stay immutable. Explicit outputs must be fresh.
"""
import argparse
import copy
import csv
import hashlib
import io
import json
import math
from pathlib import Path


def check(ok, message):
    if not ok:
        raise ValueError(message)


def ref(path, raw):
    return dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())


def same_bytes(a, b):
    return (a['bytes'], a['sha256']) == (b['bytes'], b['sha256'])


def pinned(d, observed):
    p = Path(d['path'])
    check(p.is_absolute() and not any(q.is_symlink() for q in (p, *p.parents)), 'unsafe input path')
    a = p.stat()
    check(a.st_size <= 8 * 1024 * 1024, 'metadata input exceeds bound')
    raw = p.read_bytes(); z = p.stat()
    check((a.st_dev, a.st_ino, a.st_size, a.st_mtime_ns) == (z.st_dev, z.st_ino, z.st_size, z.st_mtime_ns), 'input changed during read')
    check(ref(p, raw) == d, 'stale input hash')
    observed.append(d)
    return raw


def latest_success(rows):
    result = {}
    for r in rows:
        if r['outcome'] == 'passed-closed' and (r['edition'] not in result or r['attempt_number'] > result[r['edition']]['attempt_number']):
            result[r['edition']] = r
    return result


def seconds(rows):
    values = [r['elapsed_seconds'] for r in rows if r['elapsed_seconds'] is not None]
    check(all(type(x) in (int, float) and math.isfinite(x) and x >= 0 for x in values), 'invalid duration')
    return sum(values)


def validate_ledger(ledger, editions):
    rows = ledger['attempts']; exclusions = ledger['excluded_closed_owners']; agg = ledger['aggregate']
    check(len({(r['edition'], r['attempt_number']) for r in rows}) == len(rows), 'duplicate attempt')
    check(len({r['attempt_directory'] for r in rows}) == len(rows), 'duplicate attempt directory')
    check(len({r['path'] for r in exclusions}) == len(exclusions), 'duplicate excluded owner')
    check(not ({r['path'] for r in exclusions} & {r['closure_ref']['path'] for r in rows}), 'production also excluded')
    for r in rows:
        check(r['edition'] in editions and type(r['attempt_number']) is int and r['attempt_number'] > 0, 'unknown edition/attempt')
        check(r['outcome'] in ('passed-closed', 'failed-closed'), 'unclosed attempt')
        if r['outcome'] == 'passed-closed':
            check(isinstance(r['complete'], dict) and type(r['input_pages']) is int and r['input_pages'] >= 0, 'publication authority missing')
        else:
            check(r['complete'] is None, 'failed attempt has publication credit')
    successes = latest_success(rows); unknown = sum(r['elapsed_seconds'] is None for r in rows)
    check(agg['closed_production_attempts'] == len(rows), 'attempt aggregate mismatch')
    check(agg['mechanically_published_editions'] == len(successes), 'publication aggregate mismatch')
    check(agg['unknown_production_attempt_durations'] == unknown, 'unknown duration mismatch')
    check(math.isclose(agg['known_production_attempt_seconds'], seconds(rows), rel_tol=1e-12, abs_tol=1e-8), 'duration aggregate mismatch')
    check(agg['unique_successful_xml_input_pages'] == sum(r['input_pages'] for r in successes.values()), 'page aggregate mismatch')
    check(agg['production_attempt_seconds'] is None if unknown else math.isclose(agg['production_attempt_seconds'], seconds(rows), rel_tol=1e-12, abs_tol=1e-8), 'duration completeness mismatch')
    total = seconds(rows)
    expected_rate = agg['unique_successful_xml_input_pages'] / total if not unknown and total else None
    rate = agg['retry_inclusive_xml_input_pages_per_second']
    check(rate is None if expected_rate is None else type(rate) in (int, float) and math.isfinite(rate) and
          math.isclose(rate, expected_rate, rel_tol=1e-12, abs_tol=1e-12), 'rate aggregate mismatch')
    return successes


def derive(old, before, ledger, inventory, baseline, load):
    """Same report join, generalized to any append-only closed ledger delta."""
    editions = {r['wiki'] for r in inventory['rows']}
    check(len(editions) == len(inventory['rows']) == inventory['edition_count'] and not inventory['missing'], 'inventory mismatch')
    check(inventory['edition_count'] == old['progress']['requested_editions'], 'requested inventory changed')
    history = baseline['history']; historical = set(history['attempted_editions'])
    check(len(historical) == history['attempted_count'] and historical <= editions, 'historical inventory mismatch')
    previous = validate_ledger(before, editions); current = validate_ledger(ledger, editions)
    check(ledger['attempts'][:len(before['attempts'])] == before['attempts'], 'production prefix changed')
    check(ledger['excluded_closed_owners'][:len(before['excluded_closed_owners'])] == before['excluded_closed_owners'], 'exclusion prefix changed')
    old_ids = [{k:r[k] for k in ('edition', 'attempt_number', 'attempt_directory')} for r in before['attempts']]
    check(old['deduplication']['identity_inventory']['campaign_logical_attempts'] == old_ids, 'prior report/ledger identity mismatch')
    check(old['progress']['campaign_new_mechanical_editions'] == len(previous), 'prior publication mismatch')
    attempted_before = historical | {r['edition'] for r in before['attempts']}
    attempted = historical | {r['edition'] for r in ledger['attempts']}
    check(old['inventory_disposition']['deferred_without_production'] == 0, 'deferred inventory needs explicit authority')
    check(old['inventory_disposition']['not_started_in_recorded_ledgers'] == len(editions-attempted_before), 'prior inventory join mismatch')
    added = ledger['attempts'][len(before['attempts']):]
    excluded = ledger['excluded_closed_owners'][len(before['excluded_closed_owners']):]
    publications = {}
    for r in added:
        leaf = load(r['closure_ref'])
        check(leaf['source_guard'] is True and leaf['cleanup_proven'] is True and leaf['outcome'] == r['outcome'], 'unproved production closure')
        check(leaf['production_started'] is True and leaf['production_elapsed_seconds'] == r['elapsed_seconds'], 'production timing join mismatch')
        check(leaf['result'] == r['result'], 'attempt/result join mismatch')
        owner = load(leaf['configuration'])
        configuration = load(owner['driver_configuration'])
        identity = ('edition', 'date', 'attempt_number', 'attempt_directory', 'source_fingerprint')
        check(tuple(configuration[k] for k in identity) == tuple(r[k] for k in identity),
              'attempt/configuration join mismatch')
        result = load(r['result'])
        check(result['elapsed_seconds'] == r['elapsed_seconds'], 'result timing join mismatch')
        if r['complete'] is not None:
            p = load(r['complete'])
            check((p['edition'],p['date'],p['input_pages']) == (r['edition'],r['date'],r['input_pages']), 'publication identity mismatch')
            publications[(r['edition'],r['attempt_number'])] = p
    for d in excluded:
        value = load(d)
        check(value['cleanup_proven'] is True and value['production_started'] is False, 'excluded owner lacks zero-production proof')
    new = copy.deepcopy(old); agg = ledger['aggregate']; initial = old['progress']['initial_mechanical_editions']
    published = initial + len(current)
    check(published <= len(attempted), 'published exceeds attempted inventory')
    check(old['inventory_disposition']['mechanical_publications'] == initial + len(previous), 'prior mechanical count mismatch')
    check(old['inventory_disposition']['attempted_unpublished'] == len(attempted_before)-initial-len(previous), 'prior failed count mismatch')
    new['progress'].update(campaign_new_mechanical_editions=len(current), total_mechanical_publications=published,
        unpublished_editions=len(editions)-published, eligible_mechanical_publications=old['progress']['eligible_mechanical_publications']+len(set(current)-set(previous)),
        whole_corpus_complete=(published == len(editions)), whole_corpus_semantic_acceptance=False,
        note='Mechanical publication only; historical timing exclusions and unknown durations retain their original scope.')
    new['inventory_disposition'].update(mechanical_publications=published, attempted_unpublished=len(attempted)-published,
        not_started_in_recorded_ledgers=len(editions-attempted), deferred_without_production=0)
    dedup = new['deduplication']
    dedup['identity_inventory']['campaign_logical_attempts'] = [{k:r[k] for k in ('edition','attempt_number','attempt_directory')} for r in ledger['attempts']]
    dedup['campaign_production_rows'] = len(ledger['attempts'])
    dedup['combined_duration_rows_excluding_sealed_baseline'] = dedup['historical_duration_rows']+len(ledger['attempts'])
    clock = new['combined_build_clock']; clock['campaign_known_attempt_seconds'] = agg['known_production_attempt_seconds']
    clock['known_seconds_subtotal'] = clock['sealed_historical_baseline_seconds']+clock['historical_known_attempt_seconds']+clock['campaign_known_attempt_seconds']
    new['campaign_only_rate'].update(scope=f"{len(current)} mechanical campaign publications; {len(ledger['attempts'])} production attempts. Not semantic throughput.",
        unique_successful_xml_pages=agg['unique_successful_xml_input_pages'], retry_inclusive_production_seconds=agg['production_attempt_seconds'],
        xml_pages_per_second=agg['retry_inclusive_xml_input_pages_per_second'], prechild_exclusion_count=len(ledger['excluded_closed_owners']))
    entries = {r['edition']:r for r in new['per_timing_eligible_edition_with_recorded_work']}
    seen_success = set(previous)
    for r in added:
        edition = r['edition']
        if edition not in entries:
            entries[edition] = dict(edition=edition,known_retry_inclusive_seconds=0,duration_complete=True,unknown_duration_attempts=0,
                historical_closed_duration_rows=0,campaign_closed_production_attempts=0,sealed_historical_baseline_seconds=0,
                semantic_acceptance=False,current_campaign_selected_attempt=None,current_campaign_input_xml_pages=None,
                current_campaign_latest_successful_seconds=None,current_mechanical_status=None)
        e = entries[edition]; e['campaign_closed_production_attempts'] += 1
        if r['elapsed_seconds'] is None:
            e['unknown_duration_attempts'] += 1; e['duration_complete'] = False
        else: e['known_retry_inclusive_seconds'] += r['elapsed_seconds']
        if r['outcome'] == 'passed-closed':
            e.update(current_campaign_selected_attempt=r['attempt_number'],current_campaign_input_xml_pages=r['input_pages'],
                current_campaign_latest_successful_seconds=r['elapsed_seconds'],current_mechanical_status=r['publication_status'])
            if edition not in seen_success:
                publication = publications[(edition,r['attempt_number'])]
                first = dict(edition=edition,attempt_number=r['attempt_number'],closure=r['closure_ref'],complete=r['complete'],
                    input_pages=r['input_pages'],production_seconds=r['elapsed_seconds'],fallback_pages=publication['fallback_pages'],
                    semantic_acceptance=False,reader_review_pending=True,first_successful_publication=True,cohort_still_active=False)
                new['latest_first_publications'].append(first); new['latest_first_publication'] = first
                seen_success.add(edition)
        else:
            failure = dict(edition=edition,attempt_number=r['attempt_number'],closure=r['closure_ref'],production_seconds=r['elapsed_seconds'],
                input_pages=None,automatic_retry=False,failure_cause='unclassified',failure_cause_scope='Ledger outcome only; no inferred diagnosis.',semantic_acceptance=False)
            new['latest_production_failures'].append(failure); new['latest_production_failure'] = failure
    new['per_timing_eligible_edition_with_recorded_work'] = [entries[k] for k in sorted(entries)]
    # No invented batch/latest-runtime role: retain historical scoped narratives.
    new['report_refresh_delta'] = dict(production_attempts=added,excluded_closed_owners=excluded,
        newly_mechanically_published_editions=sorted(set(current)-set(previous)),latest_runtime_boundary_selected=False,semantic_acceptance=False)
    check(clock['whole_goal_pages_per_second'] is None and clock['exact_retry_inclusive_seconds'] is None, 'historical unknown duration erased')
    return new


def table_bytes(ledger):
    header = ['edition','date','input_xml_pages','latest_successful_attempt','latest_successful_build_seconds',
        'retry_inclusive_production_seconds','production_attempts','failed_or_interrupted_production_attempts','unknown_duration_attempts','latest_mechanical_status']
    out = io.StringIO(); writer = csv.writer(out,lineterminator='\n'); writer.writerow(header)
    for edition in sorted({r['edition'] for r in ledger['attempts']}):
        rows = [r for r in ledger['attempts'] if r['edition']==edition]; latest = latest_success(rows).get(edition)
        unknown = sum(r['elapsed_seconds'] is None for r in rows)
        writer.writerow([edition,rows[-1]['date'],latest['input_pages'] if latest else '',latest['attempt_number'] if latest else '',
            format(latest['elapsed_seconds'],'.17g') if latest and latest['elapsed_seconds'] is not None else '',
            format(seconds(rows),'.17g') if not unknown else '',len(rows),sum(r['outcome']!='passed-closed' for r in rows),unknown,
            latest['publication_status'] if latest else 'unpublished'])
    return out.getvalue().encode()


def encoded(value):
    return (json.dumps(value,indent=2,ensure_ascii=False)+'\n').encode()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('prior-report','prior-ledger','ledger','inventory','baseline','reconciliation'):
        parser.add_argument('--'+name,type=json.loads,required=True,help='Exact JSON path/bytes/sha256 descriptor')
    for name in ('output','campaign-output','csv-output','markdown-output'):
        parser.add_argument('--'+name,type=Path,required=True)
    args = parser.parse_args(argv); observed = []
    def load(d): return json.loads(pinned(d,observed))
    old = load(args.prior_report); before = load(args.prior_ledger); ledger = load(args.ledger)
    inventory = load(args.inventory); baseline = load(args.baseline); reconciliation = load(args.reconciliation)
    check(same_bytes(args.prior_ledger,old['sources']['campaign_ledger']), 'prior ledger snapshot mismatch')
    check(args.inventory==baseline['history']['inventory'], 'immutable inventory authority mismatch')
    check(old['sources']['historical_ledger51']==baseline['history']['historical_ledger'], 'historical source join mismatch')
    load(baseline['history']['historical_ledger']); load(baseline['history']['inventory_reconciliation'])
    check(reconciliation['passed'] is True and reconciliation['ledger_after']==args.ledger, 'latest ingestion/ledger join mismatch')
    campaign = load(old['sources']['campaign_report'])
    check(campaign['source_ledger']==old['sources']['campaign_ledger'], 'campaign report join mismatch')
    new = derive(old,before,ledger,inventory,baseline,load)
    outputs = [args.output,args.campaign_output,args.csv_output,args.markdown_output]
    check(len(set(map(str,outputs)))==len(outputs), 'duplicate output path')
    for p in outputs:
        check(p.is_absolute() and str(p) not in {d['path'] for d in observed} and not p.exists() and
              not any(q.is_symlink() for q in (p,*p.parents)), 'output must be fresh and disjoint')
    table = table_bytes(ledger); agg = ledger['aggregate']
    campaign['newly_mechanically_published_editions'] = agg['mechanically_published_editions']
    campaign['aggregate'].update(unique_xml_input_pages=agg['unique_successful_xml_input_pages'],retry_inclusive_production_seconds=agg['production_attempt_seconds'],
        retry_inclusive_xml_input_pages_per_second=agg['retry_inclusive_xml_input_pages_per_second'],closed_production_attempts=len(ledger['attempts']),
        unknown_production_attempt_durations=agg['unknown_production_attempt_durations'])
    campaign.update(preceding_reconciliation=campaign['source_reconciliation'],source_reconciliation=args.reconciliation,
        source_ledger=args.ledger,table=ref(args.csv_output,table),excluded_closed_owners=ledger['excluded_closed_owners'])
    campaign_raw = encoded(campaign); sources = new['sources']
    sources.update(preceding_campaign_reconciliation=sources['latest_campaign_reconciliation'],latest_campaign_reconciliation=args.reconciliation,
        prior_campaign_snapshot=args.prior_ledger,campaign_ledger=args.ledger,campaign_report=ref(args.campaign_output,campaign_raw))
    new['previous_derived_version'] = args.prior_report
    new['report_refresh_inputs'] = dict(inventory=args.inventory,baseline=args.baseline,prior_report=args.prior_report,
        prior_ledger=args.prior_ledger,ledger=args.ledger,reconciliation=args.reconciliation)
    combined = encoded(new); inv = new['inventory_disposition']
    markdown = (f"# Current corpus progress\n\n{inv['mechanical_publications']}/{inventory['edition_count']} mechanically published; "
        f"{inv['attempted_unpublished']} attempted without publication; {inv['not_started_in_recorded_ledgers']} unstarted.\n\n"
        f"{len(ledger['attempts'])} production attempts; {len(ledger['excluded_closed_owners'])} excluded owners. "
        f"Known production time: {agg['known_production_attempt_seconds']:.12f} seconds.\n\n"
        "Mechanical publication is not semantic acceptance. Historical unknown durations remain unknown. "
        "Prior scoped narratives, failures and timing exclusions remain in the linked reports.\n\n"
        f"Combined report: {args.output}\n\nPrevious report: {args.prior_report['path']}\n").encode()
    for d in list(observed): pinned(d,[])  # Includes the mutable ledger immediately before writing.
    payloads = [combined,campaign_raw,table,markdown]
    for p,raw in zip(outputs,payloads):
        with p.open('xb') as stream: stream.write(raw)
    print(json.dumps(dict(passed=True,outputs=[ref(p,raw) for p,raw in zip(outputs,payloads)],inventory=inv,
        production_attempts=len(ledger['attempts']),excluded_owners=len(ledger['excluded_closed_owners']),ledger_ingested=False,runtime_started=False,semantic_acceptance=False)))


if __name__=='__main__':
    main()
