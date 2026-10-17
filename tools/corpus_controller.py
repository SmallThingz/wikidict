#!/usr/bin/env python3
"""Serial corpus queue over the tracked builder; durable receipts, never invented history.

A JSON configuration must explicitly be armed after current qualification and
resolution of the production diagnostic. Run --phase pilot first, then supply
its content-review receipt before --phase remaining. Failed editions can be
retried with --retry-failed; existing accepted outputs are not charged again.
The builder alone validates providers, resumes work, and verifies publication
payloads. --revalidate asks that same CLI to verify previously accepted output.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import resource
from build_artifact_root import validate_pipeline_paths
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
PILOT = ('aawiktionary', 'abwiktionary', 'afwiktionary', 'akwiktionary',
         'amwiktionary', 'angwiktionary', 'anwiktionary', 'arwiktionary')
EXCLUDED = frozenset(PILOT[:7])
WORKERS = (4, 2, 1)
MEMORY_INITIAL = 4 * 1024**3
MEMORY = 8 * 1024**3


def require(condition, message):
    if not condition:
        raise ValueError(message)


def utc():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for data in iter(lambda: f.read(1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()


def descriptor(path):
    path = Path(path).absolute()
    require(path.is_file() and not path.is_symlink(), f'Unsafe receipt: {path}')
    before = path.stat()
    result = dict(path=str(path), bytes=before.st_size, sha256=digest(path))
    after = path.stat()
    fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
    require(all(getattr(after, k) == getattr(before, k) for k in fields), f'Changed while reading: {path}')
    return result


def read_json(path):
    path = Path(path)
    require(path.stat().st_size <= 8 * 1024**2, f'Metadata exceeds bound: {path}')
    return json.loads(path.read_bytes())


def read_ref(ref):
    require(descriptor(ref['path']) == ref, 'Receipt bytes changed')
    return read_json(ref['path'])


def write_json(path, value, *, replace=False):
    path = Path(path)
    target = path.with_name(path.name + '.' + uuid.uuid4().hex + '.part') if replace else path
    with target.open('x') as f:
        json.dump(value, f, ensure_ascii=False, sort_keys=True, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    if replace:
        os.replace(target, path)
    return descriptor(path)


def edition_order(editions):
    require(len(editions) == len(set(editions)), 'Duplicate editions')
    return [x for x in (*PILOT, 'enwiktionary') if x in editions] + sorted(
        set(editions) - set(PILOT) - {'enwiktionary'})


def next_workers(current, watchdog, log_tail=''):
    # Page titles and semantic output can contain OOM-looking text. Only the
    # tracked watchdog's measured resident-limit event permits automatic retry.
    memory_failure = watchdog.get('termination_reason') == 'sampled_pss_limit'
    if not memory_failure or current not in WORKERS or current == 1:
        return None
    return WORKERS[WORKERS.index(current) + 1]



def next_resources(workers, memory_limit_bytes, watchdog):
    # Only this attempt's measured resident-cap event authorizes escalation.
    if (workers not in WORKERS or type(memory_limit_bytes) is not int
            or memory_limit_bytes not in (MEMORY_INITIAL, MEMORY)
            or watchdog.get('termination_reason') != 'sampled_pss_limit'
            or type(watchdog.get('memory_limit_bytes')) is not int
            or watchdog['memory_limit_bytes'] != memory_limit_bytes):
        return None
    if memory_limit_bytes == MEMORY_INITIAL:
        return workers, MEMORY
    reduced = next_workers(workers, watchdog)
    return (reduced, MEMORY) if reduced is not None else None


def phase_end(log_path, edition, date):
    found = []
    with Path(log_path).open(errors='replace') as f:
        for line in f:
            if not line.startswith('BUILD_PHASE '):
                continue
            try:
                row = json.loads(line[len('BUILD_PHASE '):])
            except ValueError:
                continue
            if (row.get('edition'), row.get('date'), row.get('phase'), row.get('event')) == (
                    edition, date, 'edition_build', 'end'):
                found.append(row)
    require(len(found) <= 1, 'More than one edition completion in a serial attempt')
    return found[0] if found else None


def load_preparations(cfg):
    """Authenticate explicitly selected production work, never diagnostics.

    Optional cfg.production_preparations contains accounting receipt descriptors.
    Each receipt pins an immutable actual result and independent owned closure;
    all production outcomes count, whether their artifacts were later reused.
    """
    unique = {}
    for ref in cfg.get('production_preparations', []):
        receipt = read_ref(ref)
        require(receipt['schema'] == 'wikidict.corpus-production-preparation.v1', 'Wrong preparation receipt')
        result, closed = read_ref(receipt['result']), read_ref(receipt['closure'])
        require(result['schema'] == 'wikidict.corpus-production-preparation-result.v1'
                and closed['schema'] == 'wikidict.corpus-production-preparation-closure.v1', 'Wrong preparation authority')
        require(result['accounting_scope'] == 'production-preparation', 'Diagnostics are not corpus preparation')
        require(result['outcome'] in ('passed', 'failed', 'superseded'), 'Preparation is not terminal')
        require(isinstance(result['preparation_id'], str) and result['preparation_id'], 'Missing preparation identity')
        transition = receipt.get('source_transition')
        if result['source'] != cfg['source']:
            require(isinstance(transition, dict)
                    and transition.get('from_source') == result['source']
                    and transition.get('to_source') == cfg['source']
                    and isinstance(transition.get('reason'), str) and transition['reason'].strip(),
                    'Older-source preparation needs an explicit source transition')
        elif transition is not None:
            require(False, 'Source transition does not change source')
        manifest_transition = receipt.get('manifest_transition')
        if result['manifest'] != cfg['manifest']:
            require(isinstance(manifest_transition, dict)
                    and manifest_transition.get('from_manifest') == result['manifest']
                    and manifest_transition.get('to_manifest') == cfg['manifest']
                    and manifest_transition.get('scope') == 'retained-production-time-only'
                    and manifest_transition.get('runtime_reuse_credit') is False
                    and isinstance(manifest_transition.get('reason'), str)
                    and manifest_transition['reason'].strip(),
                    'Older-input preparation needs an explicit time-only manifest transition')
            snapshot = manifest_transition.get('from_manifest_snapshot')
            require(isinstance(snapshot, dict)
                    and all(snapshot.get(key) == result['manifest'][key] for key in ('bytes', 'sha256')),
                    'Original manifest snapshot differs from preparation')
            before, after = read_ref(snapshot), read_ref(cfg['manifest'])
            require(isinstance(before, dict) and isinstance(after, dict), 'Invalid transition manifests')
            before, after = dict(before), dict(after)
            old_roots, new_roots = before.pop('auxiliary_capture_roots', None), after.pop('auxiliary_capture_roots', None)
            require(isinstance(old_roots, dict) and isinstance(new_roots, dict), 'Missing auxiliary capture roots')
            old_roots, new_roots = dict(old_roots), dict(new_roots)
            old_root, new_root = old_roots.pop(result['edition'], None), new_roots.pop(result['edition'], None)
            require(isinstance(old_root, str) and old_root and isinstance(new_root, str) and new_root
                    and old_root != new_root and before == after and old_roots == new_roots,
                    'Manifest transition must change only this edition auxiliary capture root')
        elif manifest_transition is not None:
            require(False, 'Manifest transition does not change manifest')
        for key in ('compiler', 'date', 'now_unix', 'expansion_timeout_ms'):
            require(result[key] == cfg[key], f'Preparation {key} differs from this run')
        seconds = result['elapsed_seconds']
        require(type(seconds) in (int, float) and math.isfinite(seconds) and seconds >= 0, 'Invalid preparation interval')
        require(closed['result'] == receipt['result']
                and closed['outcome'] == result['outcome'] + '-closed'
                and closed['cleanup_proven'] is True and closed['source_guard'] is True
                and closed['remaining_owned_processes'] == [], 'Preparation is not independently closed')
        row = dict(preparation_id=result['preparation_id'], edition=result['edition'],
            outcome=result['outcome'], elapsed_seconds=seconds, receipt=ref,
            original_source=result['source'], source_transition=transition,
            original_manifest=result['manifest'], manifest_transition=manifest_transition)
        key = row['preparation_id']
        require(key not in unique or unique[key] == row, 'Conflicting preparation identity')
        unique[key] = row
    return list(unique.values())


def summarize(attempt_results, editions, preparations=()):
    unique = {}
    for row in attempt_results:
        key = row['attempt_id']
        require(key not in unique or unique[key] == row, 'Conflicting attempt identity')
        unique[key] = row
    preparation_by_id = {}
    for prep in preparations:
        key = prep['preparation_id']
        require(key not in unique, 'Preparation interval is also an attempt')
        require(key not in preparation_by_id or preparation_by_id[key] == prep, 'Conflicting preparation identity')
        require(prep['edition'] in editions and prep['outcome'] in ('passed', 'failed', 'superseded'), 'Preparation outside configured corpus')
        seconds = prep['elapsed_seconds']
        require(type(seconds) in (int, float) and math.isfinite(seconds) and seconds >= 0, 'Invalid preparation interval')
        preparation_by_id[key] = prep
    latest, accepted = {}, {}
    for row in sorted(unique.values(), key=lambda x: x['sequence']):
        require(row['edition'] in editions, 'Attempt outside configured corpus')
        latest[row['edition']] = row
        if row.get('accepted') is not None:
            accepted[row['edition']] = row['accepted']
    rows = []
    unknown = []
    for edition in edition_order(editions):
        history = [x for x in unique.values() if x['edition'] == edition]
        measured = [x['elapsed_seconds'] for x in history if x.get('execution_mode') != 'existing_output']
        for seconds in measured:
            require(seconds is None or (type(seconds) in (int, float) and math.isfinite(seconds) and seconds >= 0), 'Invalid interval')
        timing_unknown = any(x is None for x in measured)
        own_preparations = [x for x in preparation_by_id.values() if x['edition'] == edition]
        preparation_seconds = sum(x['elapsed_seconds'] for x in own_preparations)
        accepted_value = accepted.get(edition)
        # A later failed revalidation cannot export an old acceptance as current.
        current = accepted_value if latest.get(edition, {}).get('accepted') is not None else None
        original_unknown = bool(current and not any(x.get('accepted') and x.get('execution_mode') != 'existing_output' for x in history))
        if edition not in EXCLUDED and (timing_unknown or original_unknown):
            unknown.append(edition)
        rows.append(dict(edition=edition, timing_excluded=edition in EXCLUDED,
            attempt_count=len(history), accepted=current,
            observed_build_seconds=None if edition in EXCLUDED or timing_unknown else sum(measured),
            production_preparations=own_preparations,
            observed_preparation_seconds=None if edition in EXCLUDED else preparation_seconds,
            observed_total_seconds=None if edition in EXCLUDED or timing_unknown else sum(measured) + preparation_seconds,
            verification_seconds=None if edition in EXCLUDED else sum(x['elapsed_seconds'] or 0 for x in history if x.get('execution_mode') == 'existing_output'),
            original_build_time_unknown=original_unknown, latest_outcome=latest.get(edition, {}).get('outcome')))
    cohort = [x for x in rows if not x['timing_excluded']]
    complete = len(rows) == 198 and len(cohort) == 191 and all(x['accepted'] is not None for x in rows)
    pages = sum(x['accepted']['input_pages'] for x in cohort if x['accepted'])
    build_elapsed = sum(x['observed_build_seconds'] or 0 for x in cohort)
    preparation_elapsed = sum(x['observed_preparation_seconds'] or 0 for x in cohort)
    elapsed = build_elapsed + preparation_elapsed
    return dict(schema='wikidict.corpus-controller-summary.v1', editions=rows,
        required_editions=len(editions), timing_cohort_editions=191, accepted_cohort_editions=sum(x['accepted'] is not None for x in cohort),
        final_cohort_complete=complete, accepted_cohort_input_pages=pages,
        observed_cohort_seconds=elapsed, observed_cohort_build_seconds=build_elapsed,
        observed_cohort_preparation_seconds=preparation_elapsed, unknown_timing_editions=unknown,
        final_observed_pages_per_second=pages / elapsed if complete and not unknown and elapsed > 0 else None,
        lost_historical_seconds=None, historical_timings_reconstructed=False,
        timing_scope='observed fresh-run intervals only; excludes lost historical work and seven original editions',
        residual_review_complete=False)


def process_identity(pid):
    try:
        raw = Path(f'/proc/{pid}/stat').read_text()
        fields = raw[raw.rindex(')') + 2:].split()
        return dict(pid=pid, start_time_ticks=int(fields[19]))
    except FileNotFoundError:
        return None


def watchdog_closed(watchdog):
    if (watchdog.get('termination_reason') in (None, 'starting', 'running', 'monitor_error', 'cleanup_error', 'guardian_lost')
            or watchdog.get('error') is not None or watchdog.get('guardian_exit_status') != 0
            or type(watchdog.get('child_exit_status')) is not int):
        return False
    for role in ('child', 'guardian'):
        pid, ticks = watchdog.get(role + '_pid'), watchdog.get(role + '_start_time_ticks')
        if type(pid) is not int or type(ticks) is not int:
            return False
        if process_identity(pid) == dict(pid=pid, start_time_ticks=ticks):
            return False
    return True


def publication_present(accepted):
    """Cheap resume guard; the builder/release performs complete byte hashes."""
    try:
        root = Path(accepted['root'])
        require(not any(p.is_symlink() for p in (root, *root.parents)), 'Unsafe publication root')
        require(Path(accepted['complete']['path']) == root / 'complete.json', 'Completion root changed')
        require(descriptor(accepted['complete']['path']) == accepted['complete'], 'Completion changed')
        require(all(accepted['complete'][k] == accepted['complete_snapshot'][k] for k in ('bytes', 'sha256')), 'Completion snapshot differs')
        complete = read_ref(accepted['complete_snapshot'])
        for name, recorded in complete['publication_files'].items():
            relative = Path(name)
            require(not relative.is_absolute() and '..' not in relative.parts, 'Escaped publication path')
            path = root / relative
            require(not any(p.is_symlink() for p in (path, *path.parents))
                    and path.is_file() and path.stat().st_size == recorded['size'], 'Missing or resized publication')
        return True
    except (OSError, ValueError, KeyError):
        return False


class Lock:
    """Controller owns one durable lock; tracked CLI owns the standard lock."""
    def __init__(self, path, own):
        self.path, self.own = Path(path), own

    def __enter__(self):
        require(not any(p.is_symlink() for p in self.path.parents), 'Unsafe lock parent')
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.parent_identity = (self.path.parent.stat().st_dev, self.path.parent.stat().st_ino)
        self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            if self.own:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.original = os.fstat(self.fd)
            self.check()
            return self
        except BaseException:
            os.close(self.fd)
            raise

    def check(self):
        held, live = os.fstat(self.fd), self.path.lstat()
        parent = self.path.parent.stat()
        require(not any(p.is_symlink() for p in self.path.parents)
                and (parent.st_dev, parent.st_ino) == self.parent_identity, 'Lock parent changed')
        require(not self.path.is_symlink() and held.st_nlink == live.st_nlink == 1
                and (held.st_dev, held.st_ino) == (live.st_dev, live.st_ino)
                == (self.original.st_dev, self.original.st_ino), 'Held lock path was removed or replaced')

    def __exit__(self, *_):
        os.close(self.fd)  # Never unlink a lock inode.


def source_guard(cfg):
    if cfg.get('artifact_root') is not None:
        validate_pipeline_paths(cfg, ROOT)
    import build_wiktionaries as builder
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT, text=True)
    require(not dirty and head == cfg['source']['head'], 'Qualified source must be clean and unchanged')
    require(builder.source_fingerprint() == cfg['source']['fingerprint'], 'Source fingerprint changed')
    require(descriptor(cfg['manifest']['path']) == cfg['manifest'], 'Input manifest changed')


def gate(ref, cfg, outcomes):
    value = read_ref(ref)
    require(value.get('outcome') in outcomes or (value.get('outcome') is None and value.get('passed') is True), 'Prerequisite has no successful disposition')
    require(value.get('source_head', value.get('head')) == cfg['source']['head']
            and value.get('source_fingerprint', value.get('fingerprint')) == cfg['source']['fingerprint'], 'Prerequisite belongs to another source')
    return value



REVIEW_METADATA_LIMIT = 8 * 1024**2
REVIEW_REPORT_NAMES = ('page-coverage.json', 'namespace-coverage.json', 'fallback-pages.jsonl')


def _review_file(reference, root, name):
    path = root / name
    require(isinstance(reference, dict) and set(reference) == {'path', 'bytes', 'sha256'} and
            reference['path'] == str(path) and type(reference['bytes']) is int and
            reference['bytes'] >= 0 and path.stat().st_size == reference['bytes'], 'Content review report path differs')
    require(descriptor(path) == reference, 'Content review report bytes differ')
    return path


def _review_evidence(values):
    require(isinstance(values, list) and 0 < len(values) <= 64, 'Source/output review evidence required')
    for reference in values:
        require(isinstance(reference, dict) and type(reference.get('bytes')) is int and
                0 < reference['bytes'] <= REVIEW_METADATA_LIMIT,
                'Use bounded source/output review evidence, not corpus payloads')
        require(Path(reference['path']).stat().st_size == reference['bytes'] and
                descriptor(reference['path']) == reference, 'Content review evidence changed')


def _review_fallbacks(path, expected_count, namespace_counts=None):
    # Stream every row, including errors after any possible sample prefix.
    before = path.stat(); count = 0; reason_counts = {}; namespaces = {}
    with path.open('rb') as stream:
        while True:
            raw = stream.readline(REVIEW_METADATA_LIMIT + 1)
            if not raw: break
            require(len(raw) <= REVIEW_METADATA_LIMIT, 'Fallback review row exceeds metadata limit')
            row = json.loads(raw)
            require(isinstance(row, dict) and type(row.get('namespace')) is int and row['namespace'] >= 0 and
                    isinstance(row.get('title'), str), 'Invalid fallback review identity')
            reasons = row.get('reasons')
            require(isinstance(reasons, list) and reasons and
                    all(isinstance(reason, str) and reason for reason in reasons) and len(set(reasons)) == len(reasons), 'Invalid fallback review reasons')
            for reason in reasons:
                require(reason.split(':', 1)[0] not in
                        ('expansion_error', 'missing_language_heading', 'unresolved_language_heading',
                         'rendered_lua_error', 'rendered_extension_error', 'render_limit',
                         'template_presentation', 'missing_template'),
                        'Positive expansion/language error remains unresolved: ' + row['title'] + ': ' + reason)
                reason_counts[reason] = reason_counts.get(reason, 0) + 1
            namespaces[row['namespace']] = namespaces.get(row['namespace'], 0) + 1
            count += 1
        after = os.fstat(stream.fileno())
    require(all(getattr(before, field) == getattr(after, field) == getattr(path.stat(), field)
                for field in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')),
            'Fallback review report changed while streaming')
    require(count == expected_count, 'Fallback review count differs from actual completion')
    if namespace_counts is not None: namespace_counts.update(namespaces)
    return reason_counts


def validate_content_review(value, source, rows, expected_editions, *, scope):
    """One content gate for exact current pilot/final output; never a diagnostic waiver."""
    expected_editions = set(expected_editions)
    require(scope in ('pilot', 'final') and
            ((scope == 'pilot' and expected_editions == set(PILOT)) or
             (scope == 'final' and len(expected_editions) == 198)), 'Invalid content review cohort')
    schema = 'wikidict.corpus-pilot-content-review.v1' if scope == 'pilot' else 'wikidict.corpus-final-semantic-review.v1'
    require(value.get('passed', True) is True and value.get('schema') == schema and value.get('outcome') in ('passed', 'passed-closed'),
            'Explicit current content review schema required')
    require(value.get('source_head') == source['head'] and value.get('source_fingerprint') == source['fingerprint'],
            'Content review belongs to another source')
    for key in ('pending_build_failures', 'unresolved_build_failures', 'pending_render_failures', 'unresolved_render_failures'):
        require(value.get(key) == [], 'Content review retains pending/unresolved build/render failures')
    require(len(rows) == len(expected_editions) and len({row['edition'] for row in rows}) == len(rows) and
            {row['edition'] for row in rows} == expected_editions and all(row.get('accepted') for row in rows),
            'Content review requires exact accepted edition cohort')
    expected = {row['edition']: row['accepted']['complete']['sha256'] for row in rows}
    require(value.get('accepted_completions') == expected, 'Content review completion map differs')
    reviews = value.get('editions')
    require(isinstance(reviews, list) and len(reviews) == len(expected_editions) and
            all(isinstance(row, dict) for row in reviews) and
            len({row.get('edition') for row in reviews}) == len(reviews) and
            {row.get('edition') for row in reviews} == expected_editions,
            'Explicit unique per-edition content dispositions required')
    by_edition = {row['edition']: row for row in reviews}
    for row in rows:
        accepted = row['accepted']; review = by_edition[row['edition']]; root = Path(accepted['root'])
        require(root.is_absolute() and root.is_dir() and not any(path.is_symlink() for path in (root, *root.parents)),
                'Unsafe accepted content review root')
        require(accepted['source'] == source and review.get('complete') == accepted['complete'],
                'Content review completion/source differs')
        require(all(type(accepted[key].get('bytes')) is int and 0 < accepted[key]['bytes'] <= REVIEW_METADATA_LIMIT
                    for key in ('complete', 'complete_snapshot')), 'Completion review metadata exceeds limit')
        complete = read_ref(accepted['complete']); snapshot = read_ref(accepted['complete_snapshot'])
        require(complete == snapshot and all(accepted['complete'][key] == accepted['complete_snapshot'][key]
                for key in ('bytes', 'sha256')) and complete['edition'] == row['edition'] and
                complete['date'] == root.name and complete['build_inputs'] == accepted['build_inputs'] and
                complete['build_inputs']['source'] == source['fingerprint'], 'Accepted completion identity differs')
        reports = accepted['reports']
        require(set(reports) == set(REVIEW_REPORT_NAMES) and review.get('reports') == reports,
                'Content review report inventory differs')
        files = complete['publication_files']
        for name in REVIEW_REPORT_NAMES:
            expected_ref = dict(path=str(root / name), bytes=files[name]['size'], sha256=files[name]['sha256'])
            require(reports[name] == expected_ref, 'Content report differs from completion inventory')
            path = _review_file(reports[name], root, name)
        require(type(complete.get('input_pages')) is int and complete['input_pages'] >= 0 and
                review.get('input_pages') == complete['input_pages'] and
                review.get('namespace_coverage_totals') == complete['namespace_coverage_totals'] and
                isinstance(review['namespace_coverage_totals'], dict) and
                all(type(n) is int and n >= 0 for n in review['namespace_coverage_totals'].values()),
                'Explicit observed input/namespace counts required')
        fallback_count = complete['fallback_pages']
        require(type(fallback_count) is int and fallback_count >= 0 and
                type(review.get('fallback_pages')) is int and review['fallback_pages'] == fallback_count,
                'Explicit fallback disposition count differs')
        fallback_namespaces = {}
        reasons = _review_fallbacks(root / 'fallback-pages.jsonl', fallback_count, fallback_namespaces)
        # Reuse the producer's exact bounded coverage/conservation validators.
        import build_wiktionaries as builder
        coverage = builder.validate_page_coverage(root, require_total=True)
        namespace_totals = builder.validate_namespace_coverage(root, coverage['pages_seen'], fallback_counts=fallback_namespaces)
        require(coverage['pages_seen'] == complete['input_pages'] == accepted['input_pages'] and
                namespace_totals == complete['namespace_coverage_totals'] and
                namespace_totals['fallback_pages'] == fallback_count,
                'Reviewed coverage/namespace totals differ from actual completion')
        require(review.get('fallback_reasons') == reasons and
                all(type(n) is int for n in review['fallback_reasons'].values()), 'Explicit fallback reason inventory differs')
        inventory = dict(path=str(root / 'languages.tsv'), bytes=files['languages.tsv']['size'],
                         sha256=files['languages.tsv']['sha256'])
        require(review.get('language_inventory') == inventory, 'Language inventory review differs')
        path = _review_file(inventory, root, 'languages.tsv')
        require(inventory['bytes'] <= REVIEW_METADATA_LIMIT, 'Language inventory exceeds metadata limit')
        with path.open('rb') as stream: inventory_bytes = stream.read(REVIEW_METADATA_LIMIT + 1)
        require(len(inventory_bytes) == inventory['bytes'] and
                hashlib.sha256(inventory_bytes).hexdigest() == inventory['sha256'], 'Language inventory changed while reading')
        headings = inventory_bytes.decode('utf-8').splitlines()
        require(headings and headings[0] == 'heading' and all(headings[1:]) and
                len(set(headings[1:])) == len(headings[1:]), 'Invalid authenticated language inventory')
        unclassified = 'Unclassified' in headings[1:]
        require(type(review.get('unclassified_present')) is bool and review['unclassified_present'] == unclassified,
                'Explicit Unclassified disposition differs')
        status = complete['status']
        blob_count = sum(name.endswith(('.wikblb', '.wikblb.xz')) for name in files)
        require(status in ('built', 'empty') and review.get('publication_status') == status and
                type(complete.get('blobs')) is int and complete['blobs'] == blob_count and
                ((status == 'empty' and blob_count == 0 and not headings[1:]) or
                 (status == 'built' and blob_count > 0)), 'Explicit empty-edition disposition differs')
        content = review.get('content_review')
        require(isinstance(content, dict) and content.get('edition') == row['edition'] and
                content.get('complete_sha256') == accepted['complete']['sha256'] and
                content.get('source_intent_verified') is True and
                content.get('native_output_checked') is True and
                content.get('build_inputs') == accepted['build_inputs'] and
                content.get('input_pages') == complete['input_pages'] and
                content.get('no_unresolved_language_declarations') is True and
                content.get('no_build_render_errors') is True and
                isinstance(content.get('explanation'), str) and content['explanation'].strip(),
                'Actual source intent and native output content review required')
        _review_evidence(content.get('source_evidence')); _review_evidence(content.get('output_evidence'))
        dispositions = review.get('dispositions')
        require(isinstance(dispositions, dict) and set(dispositions) == {'fallbacks', 'unclassified', 'empty'} and
                all(isinstance(item, dict) for item in dispositions.values()),
                'All three explicit residual dispositions required')
        expected_status = dict(fallbacks='source-verified' if fallback_count else 'none',
                               unclassified='source-verified' if unclassified else 'none',
                               empty='source-verified' if status == 'empty' else 'not-empty')
        source_reasons = dispositions['fallbacks'].get('source_verified_reasons')
        require(isinstance(source_reasons, dict) and set(source_reasons) == set(reasons) and
                all(isinstance(note, str) and note.strip() for note in source_reasons.values()),
                'Every actual fallback reason needs a source/output disposition')
        for kind, wanted in expected_status.items():
            disposition = dispositions[kind]
            require(isinstance(disposition, dict) and disposition.get('status') == wanted,
                    'Residual category is not explicitly source-verified/clear: ' + kind)
            if wanted == 'source-verified':
                require(isinstance(disposition.get('explanation'), str) and disposition['explanation'].strip(),
                        'Source-verified limitation needs actual source/output explanation: ' + kind)
    return value

def command(cfg, edition, workers, memory_limit_bytes=MEMORY_INITIAL):
    require(type(memory_limit_bytes) is int and memory_limit_bytes in (MEMORY_INITIAL, MEMORY),
            'Production memory budget must be 4 or 8 GiB')
    argv = [sys.executable, '-B', str(ROOT / 'tools/build_wiktionaries.py'),
        '--resource-mode', 'watchdog', '--watchdog-address-space', 'unlimited',
        '--watchdog-memory-limit-mib', str(memory_limit_bytes // 1024**2),
        '--cpu-admission', 'affinity', '--threads', str(workers), '--jobs', '1',
        '--expansion-workers', str(workers), '--build-timeout-seconds', str(cfg['build_timeout_seconds']),
        '--now-unix', str(cfg['now_unix']), '--expansion-timeout-ms', str(cfg['expansion_timeout_ms']),
        '--downloads', cfg['downloads'], '--output', cfg['output'], '--raw-shard-root', cfg['raw_shard_root'],
        '--zig', cfg['compiler']['path'], '--wikis', edition]
    if cfg.get('artifact_root') is not None:
        argv += ['--artifact-root-spec', json.dumps(cfg['artifact_root'], sort_keys=True, separators=(',', ':'))]
    return argv



CONTEXT_KEYS = ('source', 'compiler', 'manifest', 'downloads', 'output', 'raw_shard_root',
                'date', 'now_unix', 'expansion_timeout_ms')

def production_context(cfg):
    values = {key: cfg[key] for key in CONTEXT_KEYS}
    if cfg.get('artifact_root') is not None:
        values['artifact_root'] = cfg['artifact_root']
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()


def load_history_transition(cfg):
    transition = cfg.get('production_manifest_transition')
    if transition is None:
        return None
    require(isinstance(transition, dict) and set(transition) == {
            'scope', 'reason', 'from_configuration', 'from_manifest_snapshot', 'to_manifest'}
            and transition['scope'] == 'english-auxiliary-only-non-english-history'
            and isinstance(transition['reason'], str) and transition['reason'].strip(),
            'Explicit English-only history transition required')
    old = read_ref(transition['from_configuration'])
    require(old.get('armed') is True and old.get('production_manifest_transition') is None,
            'History transition requires one original armed configuration')
    for key in (*CONTEXT_KEYS, 'state_directory', 'artifact_root', 'build_timeout_seconds'):
        if key != 'manifest':
            require(old.get(key) == cfg.get(key), 'History transition changes ' + key)
    require(transition['to_manifest'] == cfg['manifest']
            and old['manifest']['path'] == cfg['manifest']['path'], 'History manifest target differs')
    snapshot = transition['from_manifest_snapshot']
    require(all(snapshot.get(k) == old['manifest'][k] for k in ('bytes', 'sha256')),
            'History original manifest snapshot differs')
    before, after = read_ref(snapshot), read_ref(cfg['manifest'])
    before, after = dict(before), dict(after)
    old_roots, new_roots = before.pop('auxiliary_capture_roots', None), after.pop('auxiliary_capture_roots', None)
    require(isinstance(old_roots, dict) and isinstance(new_roots, dict), 'History auxiliary roots missing')
    old_roots, new_roots = dict(old_roots), dict(new_roots)
    old_en, new_en = old_roots.pop('enwiktionary', None), new_roots.pop('enwiktionary', None)
    require(isinstance(old_en, str) and old_en and isinstance(new_en, str) and new_en
            and old_en != new_en and before == after and old_roots == new_roots,
            'History transition must change only English auxiliary root')
    old_context = production_context(old)
    require(old_context != production_context(cfg), 'History transition does not change context')
    return dict(context=old_context, configuration=old)


def validate_history_context(start, row, context, transition=None, cfg=None):
    old_context = transition is not None and start['context'] == transition['context']
    require(start['context'] == context or old_context,
            'Run directory has another source/input configuration')
    if not old_context:
        return
    require(all(start[k] == row[k] for k in ('attempt_id', 'sequence', 'edition')),
            'Transition attempt identity differs')
    require(start['edition'] != 'enwiktionary' or row.get('accepted') is None,
            'Prior English acceptance cannot cross its metadata transition')
    if row.get('accepted') is not None:
        accepted = row['accepted']
        complete = read_ref(accepted['complete_snapshot'])
        require((accepted['complete_snapshot']['bytes'], accepted['complete_snapshot']['sha256']) ==
                (accepted['complete']['bytes'], accepted['complete']['sha256']), 'Accepted completion snapshot differs')
        require((complete['edition'], complete['date'], complete['now_unix']) ==
                (start['edition'], cfg['date'], cfg['now_unix'])
                and accepted['root'] == str(Path(cfg['output']) / start['edition'] / cfg['date'])
                and accepted['source'] == cfg['source'] and accepted['input_pages'] == complete['input_pages']
                and accepted['build_inputs'] == complete['build_inputs'], 'Carried publication identity differs')
        inputs = complete['build_inputs']
        selected = [item for item in read_ref(cfg['manifest'])['files'] if item['wiki'] == start['edition']]
        expected = sorted([[x['wiki'], x['date'], x['name'], x['size'], x['sha1']] for x in selected])
        require(inputs['files'] == expected and inputs['source'] == cfg['source']['fingerprint']
                and inputs['zig_sha256'] == cfg['compiler']['sha256']
                and inputs['expansion_timeout_ms'] == cfg['expansion_timeout_ms'],
                'Carried publication build inputs differ')


def selected_phase_editions(editions, phase, defer_english=False):
    require(phase in ('pilot', 'remaining'), 'Unknown production phase')
    require(not defer_english or phase == 'remaining', 'English deferral is only a remaining-phase selection')
    selected = list(PILOT) if phase == 'pilot' else [x for x in edition_order(editions) if x not in PILOT]
    return [x for x in selected if not (defer_english and x == 'enwiktionary')]


def history(state, context, cfg=None):
    rows = []
    attempts = state / 'attempts'
    transition = load_history_transition(cfg) if cfg is not None else None
    for folder in sorted(attempts.iterdir()):
        if not folder.is_dir():
            continue
        start = read_json(folder / 'start.json')
        require(start['context'] == context or (transition is not None and start['context'] == transition['context']),
                'Run directory has another source/input configuration')
        terminal = folder / 'result.json'
        if not terminal.exists():
            launch = read_json(folder / 'launch.json') if (folder / 'launch.json').exists() else None
            require(process_identity(start['controller']['pid']) != start['controller'], 'Another controller still owns an unfinished attempt')
            if launch:
                require(process_identity(launch['identity']['pid']) != launch['identity'], 'Tracked builder still active')
            wdpath = folder / '.tmp/build-watchdog-report.json'
            require(wdpath.exists(), f'Unresolved attempt; no actual watchdog terminal: {folder}')
            wd = read_json(wdpath)
            require(wd.get('termination_reason') not in ('starting', 'running', None), 'Watchdog terminal missing')
            require(watchdog_closed(wd), 'Incomplete owned cleanup prevents recovery admission')
            # Lost parent elapsed/exit are unknown. Re-run the real CLI to validate
            # any publication; a saved child exit alone is not new acceptance.
            write_json(terminal, dict(attempt_id=start['attempt_id'], sequence=start['sequence'], edition=start['edition'],
                outcome='interrupted', elapsed_seconds=None, exit_code=None, execution_mode=None,
                watchdog=descriptor(wdpath), watchdog_elapsed_seconds=wd.get('elapsed_seconds'),
                accepted=None, timing_authority='parent terminal missing; elapsed unknown', recovered=True))
        row = read_json(terminal)
        validate_history_context(start, row, context, transition, cfg)
        if row.get('accepted'):
            read_ref(row['accepted']['complete_snapshot'])
        rows.append(row)
    return rows


def accept(cfg, edition, folder, phase, log_ref):
    require(phase and phase['status'] == 'success', 'Actual edition completion event missing')
    root = Path(cfg['output']) / edition / cfg['date']
    complete = read_json(root / 'complete.json')
    require((complete['edition'], complete['date'], complete['now_unix']) == (edition, cfg['date'], cfg['now_unix']), 'Publication context mismatch')
    import build_wiktionaries as builder
    items = builder.select_manifest_files(read_ref(cfg['manifest']), [edition])
    expected_files = sorted([[x['wiki'], x['date'], x['name'], x['size'], x['sha1']] for x in items])
    require(complete['build_inputs']['files'] == expected_files, 'Publication dump identity mismatch')
    require(complete['build_inputs']['expansion_timeout_ms'] == cfg['expansion_timeout_ms'], 'Publication deadline mismatch')
    require(complete['build_inputs']['source'] == cfg['source']['fingerprint']
            and complete['build_inputs']['zig_sha256'] == cfg['compiler']['sha256'], 'Publication source/compiler mismatch')
    live = descriptor(root / 'complete.json')
    snapshot = folder / 'complete.json'
    with snapshot.open('xb') as f:
        f.write(Path(live['path']).read_bytes())
    snap = descriptor(snapshot)
    require((snap['bytes'], snap['sha256']) == (live['bytes'], live['sha256']), 'Completion changed during snapshot')
    require(type(complete['input_pages']) is int and complete['input_pages'] >= 0, 'Invalid accepted page count')
    reports = {name: dict(path=str(root / name), bytes=value['size'], sha256=value['sha256'])
               for name, value in complete['publication_files'].items()
               if name in ('page-coverage.json', 'namespace-coverage.json', 'fallback-pages.jsonl')}
    require(len(reports) == 3, 'Required publication reports absent')
    accepted = dict(root=str(root), input_pages=complete['input_pages'], complete=live, complete_snapshot=snap,
                    source=cfg['source'], build_inputs=complete['build_inputs'], reports=reports, build_log=log_ref)
    write_json(folder / 'residual-review.json', dict(schema='wikidict.corpus-residual-review-item.v1',
        edition=edition, date=cfg['date'], accepted=accepted, verdict=None,
        fallback_pages=complete['fallback_pages'], namespace_coverage_totals=complete['namespace_coverage_totals']))
    return accepted


def execute(cfg, edition, workers, folder, sequence, context, locks, memory_limit_bytes=MEMORY_INITIAL):
    from build_resource_limits import _signal_owned
    folder.mkdir()
    start = dict(attempt_id=folder.name, sequence=sequence, edition=edition, date=cfg['date'],
        workers_requested=workers, memory_limit_bytes=memory_limit_bytes, address_space='unlimited', context=context,
        controller=process_identity(os.getpid()), started_utc=utc(), argv=command(cfg, edition, workers, memory_limit_bytes))
    write_json(folder / 'start.json', start)
    started = time.monotonic()
    error, process, rc = None, None, None
    interrupted = False
    try:
        with (folder / 'build.log').open('xb') as log:
            process = subprocess.Popen(start['argv'], cwd=folder, stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            identity = process_identity(process.pid)
            require(identity is not None, 'Could not record tracked CLI identity')
            write_json(folder / 'launch.json', dict(identity=identity, private_session=process.pid))
            while process.poll() is None:
                for lock in locks:
                    lock.check()
                time.sleep(1)
            rc = process.wait()
    except BaseException as exc:
        error = f'{type(exc).__name__}: {exc}'
        interrupted = isinstance(exc, (KeyboardInterrupt, SystemExit))
        if process and process.poll() is None:
            identity = process_identity(process.pid)
            if identity:
                _signal_owned({process.pid: identity['start_time_ticks']}, signal.SIGTERM)
            try:
                rc = process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                if identity:
                    _signal_owned({process.pid: identity['start_time_ticks']}, signal.SIGKILL)
                rc = process.wait(timeout=5)
    elapsed = time.monotonic() - started
    wdpath = folder / '.tmp/build-watchdog-report.json'
    wd = read_json(wdpath) if wdpath.exists() else {}
    log_ref = descriptor(folder / 'build.log') if (folder / 'build.log').exists() else None
    phase = phase_end(folder / 'build.log', edition, cfg['date']) if log_ref else None
    accepted = None
    cleanup_proven = process is not None and process.poll() is not None and watchdog_closed(wd)
    try:
        for lock in locks:
            lock.check()
        source_guard(cfg)
        if wd:
            require(type(wd.get('memory_limit_bytes')) is int and wd['memory_limit_bytes'] == memory_limit_bytes,
                    'Actual watchdog memory budget differs from the requested attempt')
        if error is None and rc == 0:
            require(cleanup_proven, 'Tracked watchdog cleanup is unproven')
            require(wd.get('child_exit_status') == wd.get('guardian_exit_status') == 0
                    and wd.get('termination_reason') == 'child_exit', 'Successful watchdog terminal missing')
            accepted = accept(cfg, edition, folder, phase, log_ref)
    except (OSError, ValueError) as exc:
        error = f'{type(exc).__name__}: {exc}'
    row = dict(attempt_id=folder.name, sequence=sequence, edition=edition, workers_requested=workers,
        memory_limit_bytes=memory_limit_bytes, outcome='passed' if accepted else 'failed', exit_code=rc, error=error, elapsed_seconds=elapsed,
        controller_interrupted=interrupted, cleanup_proven=cleanup_proven,
        timing_authority='actual controller monotonic interval around joined tracked CLI', ended_utc=utc(),
        execution_mode=phase.get('execution_mode') if phase else None, edition_build=phase,
        watchdog=descriptor(wdpath) if wdpath.exists() else None, build_log=log_ref, accepted=accepted)
    write_json(folder / 'result.json', row)
    return row, wd


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--phase', choices=('pilot', 'remaining'), default='pilot')
    parser.add_argument('--retry-failed', action='store_true')
    parser.add_argument('--revalidate', action='store_true')
    parser.add_argument('--defer-english', action='store_true', help='Remaining phase: preserve English as pending while its capture completes')
    args = parser.parse_args(argv)
    cfg = read_json(args.config)
    require(cfg.get('armed') is True, 'Configuration remains unarmed')
    require(resource.getrlimit(resource.RLIMIT_AS) == (resource.RLIM_INFINITY, resource.RLIM_INFINITY), 'Controller requires inherited unlimited AS')
    validate_pipeline_paths(cfg, ROOT)
    state = Path(cfg['state_directory'])
    require(not state.is_relative_to(Path(cfg['output'])) and not state.is_relative_to(Path(cfg['raw_shard_root'])), 'Receipts must be separate from build artifacts')
    require(descriptor(cfg['compiler']['path']) == cfg['compiler'], 'Pinned compiler changed')
    manifest = read_ref(cfg['manifest'])
    require(Path(cfg['manifest']['path']) == Path(cfg['downloads']) / 'manifest.json', 'Manifest selection differs')
    editions = manifest['requested_editions']
    require(len(editions) == len(set(editions)) == 198 and set(PILOT) <= set(editions), 'Exactly the selected 198 editions required')
    require({x['date'] for x in manifest['files']} == {cfg['date']} == {'20261001'}, 'Dump date selection changed')
    source_guard(cfg)
    gate(cfg['qualification'], cfg, ('passed-closed',))
    gate(cfg['diagnostic_disposition'], cfg, ('resolved', 'passed-closed'))
    context = production_context(cfg)
    state.mkdir(parents=True, exist_ok=True)
    (state / 'attempts').mkdir(exist_ok=True)
    with ExitStack() as stack:
        locks = [stack.enter_context(Lock(ROOT / 'data/build-resources/corpus-controller.lock', True)),
                 stack.enter_context(Lock(ROOT / '.tmp/build-resources.lock', False))]
        rows = history(state, context, cfg)
        preparations = load_preparations(cfg)
        current = summarize(rows, editions, preparations)
        if args.phase == 'remaining':
            review = gate(cfg['pilot_review'], cfg, ('passed', 'passed-closed'))
            pilot_rows = [row for row in current['editions'] if row['edition'] in PILOT]
            validate_content_review(review, cfg['source'], pilot_rows, PILOT, scope='pilot')
        selected = selected_phase_editions(editions, args.phase, args.defer_english)
        sequence = max((x['sequence'] for x in rows), default=0)
        for edition in selected:
            prior = [x for x in rows if x['edition'] == edition]
            if prior and prior[-1].get('accepted') and not args.revalidate:
                accepted = prior[-1]['accepted']
                if publication_present(accepted):
                    continue
            if prior and not prior[-1].get('accepted') and prior[-1]['outcome'] != 'interrupted' and not args.retry_failed:
                continue
            workers = next(x for x in WORKERS if x <= len(os.sched_getaffinity(0)))
            memory_limit_bytes = MEMORY_INITIAL
            while workers:
                for lock in locks:
                    lock.check()
                source_guard(cfg)
                sequence += 1
                folder = state / 'attempts' / f'{sequence:06d}-{edition}-w{workers}-{uuid.uuid4().hex[:12]}'
                row, wd = execute(cfg, edition, workers, folder, sequence, context, locks, memory_limit_bytes)
                rows.append(row)
                write_json(state / 'summary.json', summarize(rows, editions, preparations), replace=True)
                if row['controller_interrupted']:
                    return 130
                require(row['cleanup_proven'], 'Owned cleanup is unproven; no next edition admitted')
                if row['accepted']:
                    break
                following = next_resources(workers, memory_limit_bytes, wd)
                if following is None:
                    break
                workers, memory_limit_bytes = following
        summary = summarize(rows, editions, preparations)
        write_json(state / 'summary.json', summary, replace=True)
        print(json.dumps(dict(summary=str(state / 'summary.json'), remaining=[x['edition'] for x in summary['editions'] if not x['accepted']], deferred=['enwiktionary'] if args.defer_english else [])))
    return 0 if all(x['accepted'] for x in summary['editions'] if x['edition'] in selected) else 1


if __name__ == '__main__':
    raise SystemExit(main())
