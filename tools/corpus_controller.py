#!/usr/bin/env python3
"""Serial corpus queue over the tracked builder; durable receipts, never invented history.

A JSON configuration must explicitly be armed after current qualification and
resolution of the production diagnostic. Run --phase pilot first, then supply
its content-review receipt before --phase remaining. --phase all instead queues
all selected editions smallest-first without the historical pilot prerequisite;
qualification and publication/semantic checks remain unchanged. Failed editions can be
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
from build_artifact_root import validate_pipeline_paths, execution_paths, refuse_execution_destinations
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
    # A measured cap event may reduce workers, never raise the fixed job budget.
    if (workers not in WORKERS or type(memory_limit_bytes) is not int
            or memory_limit_bytes != MEMORY
            or watchdog.get('termination_reason') != 'sampled_pss_limit'
            or type(watchdog.get('memory_limit_bytes')) is not int
            or watchdog['memory_limit_bytes'] != memory_limit_bytes):
        return None
    reduced = next_workers(workers, watchdog)
    return (reduced, MEMORY) if reduced is not None else None


def phase_evidence(log_path, edition, date, *, strict=False):
    starts, ends = [], []
    with Path(log_path).open(errors='replace') as stream:
        for line in stream:
            if not line.startswith('BUILD_PHASE '):
                continue
            try:
                row = json.loads(line[len('BUILD_PHASE '):])
            except ValueError:
                require(not strict, 'Malformed edition phase record')
                continue
            require(isinstance(row, dict), 'Malformed edition phase object')
            if (row.get('edition'), row.get('date'), row.get('phase')) != (edition, date, 'edition_build'):
                continue
            if strict:
                require(row.get('event') in ('start', 'end'), 'Unknown edition phase event')
                require(not ends, 'Edition phase follows terminal')
                if row['event'] == 'end':
                    require(len(starts) == 1, 'Edition terminal has no preceding start')
                    require(type(row.get('seconds')) in (int, float) and math.isfinite(row['seconds'])
                            and row['seconds'] >= 0, 'Invalid edition phase duration')
            if row.get('event') == 'start': starts.append(row)
            if row.get('event') == 'end': ends.append(row)
    require(len(starts) <= 1 and len(ends) <= 1, 'More than one edition completion in a serial attempt')
    return dict(production_started=bool(starts or ends), end=ends[0] if ends else None)


def phase_end(log_path, edition, date):
    return phase_evidence(log_path, edition, date)['end']



def _validate_unrelated_registry_appends(before, after, edition, date, changes):
    """Append proofs authenticate historical time only; no native reuse credit."""
    require(date == '20261001' and isinstance(changes, list) and 0 < len(changes) <= 4,
            'Registry append timing proof has invalid scope')
    if len(changes) == 4:
        require(all(isinstance(change, dict) and isinstance(change.get('edition'), str)
                    for change in changes)
                and {change.get('edition') for change in changes}
                    == {'arwiktionary', 'afwiktionary', 'amwiktionary', 'anwiktionary'},
                'Fourth registry timing proof requires the reviewed Arabic/Afrikaans/Amharic/Aragonese lineage')
    old_rows, new_rows = before.get('language_registries'), after.get('language_registries')
    require(isinstance(old_rows, list) and isinstance(new_rows, list)
            and len(old_rows) == len(new_rows)
            and all(isinstance(row, dict) for row in old_rows + new_rows),
            'Registry append inventory differs')
    expected = dict(before, language_registries=list(old_rows))
    seen = set()
    for change in changes:
        require(isinstance(change, dict)
                and set(change) in ({'edition', 'original_registry', 'derived_registry', 'aliases'},
                    {'edition', 'original_registry', 'derived_registry', 'aliases', 'local_headings'}),
                'Registry append proof fields differ')
        wiki = change['edition']
        require(isinstance(wiki, str) and wiki not in seen and wiki != edition,
                'Registry append timing cannot change the preparation edition or duplicate it')
        seen.add(wiki)
        selected = [i for i, row in enumerate(old_rows)
                    if row.get('wiki') == wiki and row.get('date') == date]
        require(len(selected) == 1, 'Exactly one selected registry row required')
        index = selected[0]; row = old_rows[index]
        refs = [change[key] for key in ('original_registry', 'derived_registry')]
        data = []
        for item in refs:
            require(isinstance(item, dict) and set(item) == {'path', 'bytes', 'sha256'}
                    and type(item['bytes']) is int and 0 < item['bytes'] <= 1024**2
                    and descriptor(item['path']) == item, 'Registry append bytes differ')
            raw = Path(item['path']).read_bytes()
            require(len(raw) == item['bytes'] and hashlib.sha256(raw).hexdigest() == item['sha256'],
                    'Registry append changed while reading')
            data.append(raw)
        original, derived = data
        language = row.get('content_language')
        require(row.get('name') == 'language-registry.tsv' and isinstance(language, str)
                and original.startswith(b'# wikidict-language-registry-v2\n')
                and ('# content-language\t' + language + '\n').encode() in original
                and original.endswith(b'\n'), 'Registry append original identity differs')
        codes = {line.split('\t', 1)[0] for line in original.decode('utf-8').splitlines()
                 if line and not line.startswith('#')}
        aliases = change['aliases']; headings = change.get('local_headings', [])
        keys = set(); folded_owners = {}; directives = []
        require(isinstance(aliases, list) and isinstance(headings, list)
                and 0 < len(aliases) + len(headings) <= 32,
                'Registry append needs explicit finite directives')
        for kind, pairs in (('local-alias', aliases), ('local-heading', headings)):
            for pair in pairs:
                require(isinstance(pair, list) and len(pair) == 2
                        and all(isinstance(value, str) for value in pair),
                        'Registry append directive fields differ')
                code, label = pair; key = label.casefold()
                require(code in codes and label and label == label.strip() and len(label) <= 1024
                        and all(ord(ch) >= 32 and not 127 <= ord(ch) < 160 for ch in label)
                        and label not in keys and (key not in folded_owners or folded_owners[key] == code),
                        'Registry append directive code or label invalid')
                keys.add(label)
                folded_owners[key] = code
                directive = ('# ' + kind + '\t' + code + '\t' + label + '\n').encode('utf-8')
                require(directive not in original, 'Registry append repeats an existing directive')
                directives.append(directive)
        require(derived == original + b''.join(directives),
                'Registry append must preserve every original byte and only declared aliases')
        require(all(row.get(key) == refs[0][field]
                    for key, field in (('size', 'bytes'), ('sha256', 'sha256'))),
                'Registry append original inventory does not match bytes')
        expected['language_registries'][index] = dict(row, size=refs[1]['bytes'], sha256=refs[1]['sha256'])
    old_roots, new_roots = before.get('auxiliary_capture_roots'), after.get('auxiliary_capture_roots')
    require(isinstance(old_roots, dict) and isinstance(new_roots, dict)
            and isinstance(old_roots.get(edition), str) and old_roots[edition]
            and isinstance(new_roots.get(edition), str) and new_roots[edition],
            'Registry append preparation capture roots missing')
    expected['auxiliary_capture_roots'] = dict(old_roots)
    expected['auxiliary_capture_roots'][edition] = new_roots[edition]
    require(expected == after, 'Registry append changes other manifest fields')

def validate_preparation_manifest_transition(cfg, manifest, edition, date, manifest_transition):
    """Authenticate only existing time-only input carries; no runtime eligibility."""
    if manifest != cfg['manifest']:
        require(isinstance(manifest_transition, dict)
                and manifest_transition.get('from_manifest') == manifest
                and manifest_transition.get('to_manifest') == cfg['manifest']
                and manifest_transition.get('scope') == 'retained-production-time-only'
                and manifest_transition.get('runtime_reuse_credit') is False
                and isinstance(manifest_transition.get('reason'), str)
                and manifest_transition['reason'].strip(),
                'Older-input preparation needs an explicit time-only manifest transition')
        snapshot = manifest_transition.get('from_manifest_snapshot')
        require(isinstance(snapshot, dict)
                and all(snapshot.get(key) == manifest[key] for key in ('bytes', 'sha256')),
                'Original manifest snapshot differs from preparation')
        before, after = read_ref(snapshot), read_ref(cfg['manifest'])
        require(isinstance(before, dict) and isinstance(after, dict), 'Invalid transition manifests')
        registry_change = manifest_transition.get('unrelated_arabic_registry')
        registry_appends = manifest_transition.get('unrelated_registry_appends')
        require(registry_change is None or registry_appends is None,
                'Registry timing proof variants cannot be mixed')
        if all(manifest[key] == cfg['manifest'][key] for key in ('bytes', 'sha256')):
            require(manifest_transition.get('identical_manifest_content') is True
                    and registry_change is None and registry_appends is None and before == after,
                    'Manifest location carry needs explicit identical-content proof')
            return manifest_transition
        require(manifest_transition.get('identical_manifest_content') is None,
                'Identical-content manifest carry cannot change bytes')
        if registry_appends is not None:
            _validate_unrelated_registry_appends(before, after, edition, date, registry_appends)
        elif registry_change is not None:
            # Accounting only: a source-grounded Arabic TSV addition cannot
            # invalidate or grant runtime credit to another edition's work.
            require(edition != 'arwiktionary' and date == '20261001'
                    and isinstance(registry_change, dict)
                    and set(registry_change) == {'original_registry', 'derived_registry'},
                    'Arabic registry timing transition applies only to another edition')
            registry_refs = [registry_change[key] for key in ('original_registry', 'derived_registry')]
            for registry_ref in registry_refs:
                require(isinstance(registry_ref, dict) and set(registry_ref) == {'path', 'bytes', 'sha256'}
                        and type(registry_ref['bytes']) is int and 0 < registry_ref['bytes'] <= 1024**2
                        and descriptor(registry_ref['path']) == registry_ref,
                        'Arabic registry timing bytes differ')
            original_registry, derived_registry = [Path(ref['path']).read_bytes() for ref in registry_refs]
            directive = '# local-alias\tmul\tمتفق عليه دوليا\n'.encode('utf-8')
            require(original_registry.startswith(b'# wikidict-language-registry-v2\n')
                    and b'# content-language\tar\n' in original_registry
                    and original_registry.endswith(b'\n') and directive not in original_registry
                    and derived_registry == original_registry + directive,
                    'Arabic registry timing transition must append only the exact local alias')
            old_rows, new_rows = before.get('language_registries'), after.get('language_registries')
            require(isinstance(old_rows, list) and isinstance(new_rows, list)
                    and len(old_rows) == len(new_rows)
                    and all(isinstance(row, dict) for row in old_rows + new_rows),
                    'Arabic registry inventory differs')
            selected = [i for i, row in enumerate(old_rows)
                        if row.get('wiki') == 'arwiktionary' and row.get('date') == '20261001']
            require(len(selected) == 1, 'Exactly one Arabic registry inventory required')
            index = selected[0]
            original_row, derived_row = old_rows[index], new_rows[index]
            require(original_row.get('name') == 'language-registry.tsv'
                    and original_row.get('content_language') == 'ar'
                    and all(original_row.get(key) == registry_refs[0][field]
                            and derived_row.get(key) == registry_refs[1][field]
                            for key, field in (('size', 'bytes'), ('sha256', 'sha256'))),
                    'Arabic registry inventory does not authenticate selected TSVs')
            expected = dict(before, language_registries=list(old_rows))
            expected['language_registries'][index] = dict(original_row,
                size=registry_refs[1]['bytes'], sha256=registry_refs[1]['sha256'])
            # Preserve the already-supported own-edition capture-root carry
            # when older intervals predate that independent input update.
            old_roots, new_roots = before.get('auxiliary_capture_roots'), after.get('auxiliary_capture_roots')
            require(isinstance(old_roots, dict) and isinstance(new_roots, dict)
                    and isinstance(old_roots.get(edition), str) and old_roots[edition]
                    and isinstance(new_roots.get(edition), str) and new_roots[edition],
                    'Missing original or current preparation capture root')
            expected['auxiliary_capture_roots'] = dict(old_roots)
            expected['auxiliary_capture_roots'][edition] = new_roots[edition]
            require(expected == after,
                    'Arabic registry timing transition changes unrelated manifest inputs')
        else:
            before, after = dict(before), dict(after)
            old_roots, new_roots = before.pop('auxiliary_capture_roots', None), after.pop('auxiliary_capture_roots', None)
            require(isinstance(old_roots, dict) and isinstance(new_roots, dict), 'Missing auxiliary capture roots')
            old_roots, new_roots = dict(old_roots), dict(new_roots)
            old_root, new_root = old_roots.pop(edition, None), new_roots.pop(edition, None)
            require(isinstance(old_root, str) and old_root and isinstance(new_root, str) and new_root
                    and old_root != new_root and before == after and old_roots == new_roots,
                    'Manifest transition must change only this edition auxiliary capture root')
    elif manifest_transition is not None:
        require(False, 'Manifest transition does not change manifest')
    return manifest_transition


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
        manifest_transition = validate_preparation_manifest_transition(
            cfg, result['manifest'], result['edition'], result['date'], receipt.get('manifest_transition'))
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


def attempt_phase_seconds(row):
    # Older noncampaign rows stored controller wall time in elapsed_seconds.
    # Their retained edition event is the production/verification authority.
    if 'edition_build' in row:
        phase = row['edition_build']
        if phase is not None:
            require(isinstance(phase, dict) and phase.get('edition') == row['edition']
                    and phase.get('phase') == 'edition_build' and phase.get('event') == 'end',
                    'Invalid edition timing authority')
            seconds = phase.get('seconds')
        else:
            seconds = 0.0 if row.get('production_started') is False else None
    elif row.get('timing_authority') == 'actual controller monotonic interval around joined tracked CLI':
        seconds = None
    else:
        seconds = row['elapsed_seconds']
    require(seconds is None or (type(seconds) in (int, float) and math.isfinite(seconds) and seconds >= 0),
            'Invalid interval')
    return seconds


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
        measured = [attempt_phase_seconds(x) for x in history if x.get('execution_mode') != 'existing_output']
        for seconds in measured:
            require(seconds is None or (type(seconds) in (int, float) and math.isfinite(seconds) and seconds >= 0), 'Invalid interval')
        timing_unknown = any(x is None for x in measured)
        known_build_seconds = sum(seconds for seconds in measured if seconds is not None)
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
            known_production_seconds=None if edition in EXCLUDED else known_build_seconds,
            observed_build_seconds=None if edition in EXCLUDED or timing_unknown else known_build_seconds,
            production_preparations=own_preparations,
            observed_preparation_seconds=None if edition in EXCLUDED else preparation_seconds,
            observed_total_seconds=None if edition in EXCLUDED or timing_unknown else known_build_seconds + preparation_seconds,
            verification_seconds=None if edition in EXCLUDED else sum(attempt_phase_seconds(x) or 0 for x in history if x.get('execution_mode') == 'existing_output'),
            original_build_time_unknown=original_unknown, latest_outcome=latest.get(edition, {}).get('outcome')))
    cohort = [x for x in rows if not x['timing_excluded']]
    complete = len(rows) == 198 and len(cohort) == 191 and all(x['accepted'] is not None for x in rows)
    pages = sum(x['accepted']['input_pages'] for x in cohort if x['accepted'])
    build_elapsed = sum(x['known_production_seconds'] or 0 for x in cohort)
    preparation_elapsed = sum(x['observed_preparation_seconds'] or 0 for x in cohort)
    elapsed = build_elapsed + preparation_elapsed
    return dict(schema='wikidict.corpus-controller-summary.v1', editions=rows,
        required_editions=len(editions), timing_cohort_editions=191, accepted_cohort_editions=sum(x['accepted'] is not None for x in cohort),
        final_cohort_complete=complete, accepted_cohort_input_pages=pages,
        known_cohort_seconds=elapsed, known_cohort_build_seconds=build_elapsed,
        observed_cohort_seconds=None if unknown else elapsed,
        observed_cohort_build_seconds=None if unknown else build_elapsed,
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
    if 'cleanup_complete' in watchdog:
        if watchdog['cleanup_complete'] is not True:
            return False
    elif (watchdog.get('termination_reason') in (None, 'starting', 'running', 'monitor_error', 'cleanup_error', 'guardian_lost')
            or watchdog.get('error') is not None):
        return False
    if (watchdog.get('termination_reason') in (None, 'starting', 'running', 'cleanup_error', 'guardian_lost')
            or watchdog.get('guardian_exit_status') != 0
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


def bound_directory(spec, role):
    require(isinstance(spec, dict) and set(spec) == {'path', 'device', 'inode', 'uid', 'mode'},
            role + ' directory identity fields differ')
    require(isinstance(spec['path'], str) and all(type(spec[key]) is int for key in ('device', 'inode', 'uid', 'mode')),
            role + ' directory identity types differ')
    path = Path(spec['path'])
    require(path.is_absolute() and str(path) == os.path.normpath(str(path))
            and not any(node.is_symlink() for node in (path, *path.parents)) and path.is_dir(),
            role + ' directory is not canonical and regular')
    actual = path.stat()
    require((actual.st_dev, actual.st_ino, actual.st_uid, actual.st_mode & 0o7777)
            == tuple(spec[key] for key in ('device', 'inode', 'uid', 'mode'))
            and actual.st_uid == os.geteuid(), role + ' directory identity changed')
    return path


def source_roots(cfg):
    frozen = cfg.get('source', {}).get('root')
    if frozen is None:
        require('workspace_root' not in cfg, 'Workspace override requires a bound retained source')
        return ROOT, ROOT
    source = bound_directory(frozen, 'Producer source')
    workspace = bound_directory(cfg.get('workspace_root'), 'Workspace')
    require(source == ROOT and Path(__file__).resolve().parents[1] == source,
            'Controller must execute from the bound producer source')
    require(source != workspace and source.is_relative_to(workspace / '.tmp'),
            'Retained source must be inside the bound workspace temporary directory')
    return source, workspace


def resource_lock_paths(cfg):
    _, workspace = source_roots(cfg)
    execution = execution_layout(cfg)
    if execution is not None:
        return (execution['root'] / 'controller.lock', execution['root'] / 'build-resources.lock')
    return (workspace / 'data/build-resources/corpus-controller.lock',
            workspace / '.tmp/build-resources.lock')


def execution_layout(cfg):
    source, workspace = source_roots(cfg)
    options = cfg.get('edition_options', {})
    require(isinstance(options, dict) and all(isinstance(row, dict) for row in options.values()),
            'Invalid edition options for execution ownership')
    caches = [row['extraction_cache_root']['path'] for row in options.values()
              if 'extraction_cache_root' in row]
    spec = cfg.get('execution_root')
    if spec is None:
        refuse_execution_destinations(workspace, [cfg.get(name) for name in
            ('state_directory', 'output', 'raw_shard_root')] + caches)
        return None
    require(isinstance(spec, dict), 'Invalid execution root binding')
    require(Path(__file__).resolve().parents[1] == source,
            'Execution controller must run from its bound producer source')
    require(isinstance(options, dict) and len(options) == 1 and len(caches) == 1,
            'Execution root requires one explicit private extraction cache')
    edition, selected = next(iter(options.items()))
    require(selected['extraction_cache_root'] == spec.get('cache'),
            'Execution cache directory identity differs')
    layout = execution_paths(spec, workspace, source, artifact_spec=cfg.get('artifact_root'),
        state=cfg['state_directory'], output=cfg['output'], raw=cfg['raw_shard_root'],
        cache=caches[0], downloads=cfg['downloads'], manifest=cfg['manifest']['path'],
        manifest_sha256=cfg['manifest']['sha256'])
    require(layout['edition'] == edition, 'Execution edition options differ from manifest')
    return layout


def retained_source_membership(root):
    """Enumerate source, excluding only ordinary generated runtime directories."""
    names = set()
    for parent, directories, files in os.walk(root, followlinks=False):
        parent = Path(parent)
        excluded = {'.tmp', '.zig-cache', 'zig-out'} if parent == root else set()
        directories[:] = [name for name in directories if name not in excluded]
        require('__pycache__' not in directories, 'Retained producer contains a Python bytecode cache')
        require(not any((parent / name).is_symlink() for name in directories),
                'Retained producer contains a source-directory symlink')
        for name in files:
            path = parent / name
            require(not path.is_symlink() and path.is_file(), 'Retained producer contains an unsafe source file')
            require(path.suffix not in ('.pyc', '.pyo'), 'Retained producer contains Python bytecode')
            names.add(path.relative_to(root).as_posix())
    return names


def retained_bytecode_guard(path):
    if path.suffix == '.py':
        # -B prevents writes, not reads. Include an external pycache_prefix and
        # helpers imported only by the future builder child, not this process.
        from importlib.util import cache_from_source
        cached = Path(cache_from_source(str(path)))
        require(not cached.exists() and not cached.is_symlink(),
                'Retained producer can consume unbound Python bytecode: ' + str(cached))


def loaded_module_origins():
    return {name: getattr(module, '__file__', None) for name, module in tuple(sys.modules.items())
            if getattr(module, '__file__', None) is not None}


def retained_import_guard(source, workspace, files, builder):
    require(Path(builder.__file__).resolve() == source / 'tools/build_wiktionaries.py'
            and builder.PROJECT == source, 'Builder import belongs to another producer root')
    helper_names = {Path(name).stem for name in files
                    if Path(name).parent.as_posix() == 'tools' and name.endswith('.py')}
    for name, origin in loaded_module_origins().items():
        path = Path(origin).absolute()
        if name in helper_names or path.is_relative_to(workspace):
            require(path.is_relative_to(source) and path.relative_to(source).as_posix() in files,
                    'Loaded project helper is outside the bound producer inventory: ' + name)


def source_guard(cfg):
    source, workspace = source_roots(cfg)
    execution_layout(cfg)
    frozen = source != workspace
    if cfg.get('artifact_root') is not None or frozen:
        validate_pipeline_paths(cfg, workspace)
    if frozen:
        require(descriptor(cfg['compiler']['path']) == cfg['compiler'], 'Pinned compiler changed')
    import build_wiktionaries as builder
    timing = None
    try:
        if os.environ.get("WIKIDICT_PHASE_TIMING") == "1":
            from extraction_cache import optional_phase_timing
            timing = optional_phase_timing(lambda name, status, fields: builder.phase_event(
                "__controller__", cfg.get("date"), name, "end",
                scope="controller-source-guard", status=status, **fields))
    except Exception:
        pass
    completed = False
    try:
        if timing is not None: timing.switch("source_guard_baseline")
        head = None if frozen else subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        inventory_ref = cfg['source'].get('inventory')
        require(not frozen or inventory_ref is not None, 'Retained producer requires a qualified source inventory')
        if inventory_ref is None:
            dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT, text=True)
            require(not dirty and head == cfg['source']['head'], 'Qualified source must be clean and unchanged')
        else:
            inventory = read_ref(inventory_ref)
            require(inventory['head'] == cfg['source']['head'], 'Producer inventory belongs to another qualification')
            files, modes = inventory['files'], inventory['modes']
            require(isinstance(files, dict) and isinstance(modes, dict) and files and set(files) == set(modes),
                    'Producer inventory and modes differ')
            if frozen:
                require(retained_source_membership(source) == set(files), 'Retained producer inventory changed')
                retained_import_guard(source, workspace, files, builder)
            else:
                tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
                producer_paths = {name for name in tracked if name and not name.startswith('apps/')}
                require(producer_paths == set(files), 'Tracked producer inventory changed')
                untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
                require(not any(name and not name.startswith('apps/') for name in untracked),
                        'Untracked producer input requires explicit source qualification')
            if timing is not None: timing.switch("source_guard_inventory")
            verified_files = verified_bytes = 0
            for name, reference in files.items():
                relative = Path(name)
                require(not relative.is_absolute() and '..' not in relative.parts and relative.as_posix() == name,
                        'Invalid producer inventory path')
                path = source / relative
                require(not any(node.is_symlink() for node in (path, *path.parents)) and path.is_file(),
                        'Producer input is not a regular non-symlink file')
                require(not frozen or path.stat().st_nlink == 1,
                        'Retained producer input shares a writable inode: ' + name)
                if frozen:
                    retained_bytecode_guard(path)
                require(reference['path'] == str(path) and descriptor(path) == reference,
                        'Producer input bytes changed: ' + name)
                require(type(modes[name]) is int and path.stat().st_mode & 0o7777 == modes[name],
                        'Producer input mode changed: ' + name)
                if timing is not None:
                    verified_files += 1
                    verified_bytes += reference['bytes']
                    timing.count(files=verified_files, bytes=verified_bytes)
        if timing is not None: timing.switch("source_guard_fingerprint")
        require(builder.source_fingerprint() == cfg['source']['fingerprint'], 'Source fingerprint changed')
        if timing is not None: timing.switch("source_guard_manifest")
        require(descriptor(cfg['manifest']['path']) == cfg['manifest'], 'Input manifest changed')
        if timing is not None: timing.count(files=1, bytes=cfg['manifest']['bytes'])
        result = dict(qualified_head=cfg['source']['head'], current_head=head,
                    producer_inventory=inventory_ref, apps_acceptance=False)
        if frozen:
            result.update(source_root=cfg['source']['root'], workspace_root=cfg['workspace_root'],
                          source_mode='retained-inventory', current_head=None,
                          canonical_worktree_consumed=False)
        completed = True
        return result
    finally:
        if timing is not None: timing.finish("success" if completed else "failure")


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


def _review_query_commands(output_review, output_evidence, accepted, title):
    """Join saved normal batch commands to their actual completed lifecycle."""
    closure_ref = output_review.get('query_closure')
    if closure_ref is None:
        return None  # Retain the original run_command evidence contract.
    require(closure_ref in output_evidence, 'Query closure evidence missing')
    closure = read_ref(closure_ref)
    require(closure.get('schema') == 'wikidict.bounded-reader-queries-independent-closure.v1' and
            all(closure.get(k) is True for k in ('passed', 'cleanup_proven',
                'all_recorded_identities_absent', 'all_owned_groups_and_sessions_empty')) and
            closure.get('remaining_owned_processes') == [], 'Normal query lifecycle is not closed')
    result = read_ref(closure['result']); binding = read_ref(closure['binding'])
    execution = read_ref(closure['execution']); transport = read_ref(closure['transport'])
    require(result.get('passed') is True and result.get('error') is None and
            execution.get('exit_code') == 0 and execution.get('worker_result') == closure['result'] and
            execution.get('binding') == closure['binding'] and transport.get('exit_code') == 0 and
            transport.get('reaped') is True and transport.get('error') is None,
            'Normal query result/terminal differs')
    reader = closure['reader']
    require(reader == binding.get('reader') == result.get('reader') and reader in binding['inputs'],
            'Normal query Reader identity differs')
    qualification_ref = output_review.get('reader_qualification')
    require(qualification_ref in output_evidence and qualification_ref in binding['inputs'],
            'Normal query Reader qualification missing')
    qualification = read_ref(qualification_ref)
    require(qualification.get('schema') == 'wikidict.durable-fresh-qualification-result.v1' and
            qualification.get('passed') is True and qualification.get('source_guard') is True and
            qualification.get('installed_reader') == reader, 'Normal query Reader was not qualified')
    # Both the published complete and an immutable same-byte snapshot must have been selected.
    require(accepted['complete'] in binding['inputs'] and
            any(ref != accepted['complete'] and ref.get('bytes') == accepted['complete']['bytes'] and
                ref.get('sha256') == accepted['complete']['sha256'] for ref in binding['inputs']),
            'Normal query accepted completion/snapshot differs')
    complete = read_ref(accepted['complete'])
    requests = [row for row in binding['requests'] if row.get('edition') == complete['edition'] and
                row.get('title') == title and row.get('root') == accepted['root']]
    rows = [row for row in result['rows'] if row.get('edition') == complete['edition'] and row.get('title') == title]
    require(len(requests) == len(rows) == 1, 'Normal query selected page is missing or ambiguous')
    row = rows[0]
    require(row.get('inventory') == output_review.get('language_inventory') and
            row.get('inventory_command') == output_review.get('inventory_command') and
            row.get('owners') == [dict(owner=x['owner'], command=x['command'], export=x['lookup'])
                                  for x in output_review.get('owner_exports', [])],
            'Normal query exports differ from its saved result')
    commands = [row['inventory_command']] + [x['command'] for x in row['owners']]
    for command_ref in commands:
        require(command_ref in closure['commands'], 'Normal query command omitted from closure')
        command = read_ref(command_ref)
        require(command.get('exit_code') == 0 and command.get('reaped') is True and
                command.get('identity') in closure['recorded_identities'] and
                command.get('argv', [None])[0] == reader['path'],
                'Normal query command identity/terminal differs')
    return commands



def _review_command_closed(command, reference, query_commands):
    if query_commands is not None:
        return reference in query_commands and command.get('exit_code') == 0 and command.get('reaped') is True
    return (command.get('exit_code') == 0 and command.get('error') is None and
            command.get('remaining_owned_processes') == [])



def _review_owner_exports(output_review, output_evidence, accepted, title):
    """Exact normal title exports shared by the two bounded source-review paths."""
    query_commands = _review_query_commands(output_review, output_evidence, accepted, title)
    inventory_ref = output_review.get('language_inventory')
    require(inventory_ref in output_evidence, 'Source limitation owner inventory evidence missing')
    inventory_command_ref = output_review.get('inventory_command')
    require(inventory_command_ref in output_evidence, 'Normal inventory command evidence missing')
    inventory_command = read_ref(inventory_command_ref); inventory_argv = inventory_command.get('argv', [])
    require(_review_command_closed(inventory_command, inventory_command_ref, query_commands) and inventory_command.get('stdout') == inventory_ref and
            inventory_argv[1:3] == ['languages', title] and '--root' in inventory_argv and
            inventory_argv[inventory_argv.index('--root') + 1] == accepted['root'],
            'Owner inventory is not from the selected accepted payload')
    inventory = read_ref(inventory_ref)
    require(inventory.get('schema') == 'dict.languages.v1' and inventory.get('query') == title,
            'Source limitation language inventory differs')
    owners = {row['heading']: row['records'] for row in inventory['accounting'] if row['records'] > 0}
    require(len(owners) == sum(row['records'] > 0 for row in inventory['accounting']),
            'Source limitation owner inventory is ambiguous')
    exports = output_review.get('owner_exports')
    require(isinstance(exports, list) and len(exports) == len(owners) and
            {row.get('owner') for row in exports} == set(owners), 'Source limitation owner exports incomplete')
    bodies = {}
    for export in exports:
        require(export['lookup'] in output_evidence and export['command'] in output_evidence,
                'Source limitation owner export evidence missing')
        command = read_ref(export['command']); argv = command.get('argv', [])
        require(_review_command_closed(command, export['command'], query_commands) and command.get('stdout') == export['lookup'] and
                '--root' in argv and argv[argv.index('--root') + 1] == accepted['root'] and
                '--language' in argv and argv[argv.index('--language') + 1] == export['owner'] and
                len(argv) >= 3 and argv[1:3] == ['lookup', title],
                'Source limitation output is not from the selected published payload')
        body = read_ref(export['lookup'])
        # Reader store count includes aliases; inventory records count only language definitions.
        # Exact lookup returns one title, independently of either whole-store count.
        require(body.get('schema') == 'dict.results.v1' and body.get('query') == title and
                body.get('language') == export['owner'] and body.get('operation') == 'lookup' and
                body.get('offset') == 0 and type(body.get('record_count')) is int and
                body['record_count'] >= owners[export['owner']] and
                type(body.get('total_matches')) is int and body['total_matches'] == 1 and
                body.get('has_more') is False and len(body.get('entries', [])) == 1 and
                all(entry.get('title') == title and entry.get('language') == export['owner'] for entry in body['entries']),
                'Source limitation output owner/record completeness differs')
        bodies[export['owner']] = body
    return bodies



def _review_source_limitations(review, accepted, complete):
    """Authenticate explicit source limitations; diagnostic pages cannot authorize a final output."""
    references = review.get('source_authored_unresolved_declarations', [])
    require(isinstance(references, list) and len(references) <= 4096, 'Invalid source limitation inventory')
    result = {}
    for reference in references:
        _review_evidence([reference]); item = read_ref(reference)
        require(item.get('schema') == 'wikidict.source-authored-unresolved-declaration.v1' and
                item.get('edition') == complete['edition'] and item.get('date') == complete['date'] and
                item.get('complete') == accepted['complete'] and item.get('build_inputs') == complete['build_inputs'],
                'Source limitation belongs to another accepted publication')
        title = item.get('title'); label = item.get('label')
        require(type(item.get('namespace')) is int and item['namespace'] == 0 and isinstance(title, str) and title and
                isinstance(label, str) and label.strip() == label and label and
                not any(char in label for char in '{}[]<>|=\r\n') and
                type(item.get('page_id')) is int and item['page_id'] > 0 and
                type(item.get('revision_id')) is int and item['revision_id'] > 0,
                'Source limitation page/declaration identity missing')
        key = (0, title)
        require(key not in result, 'Duplicate source limitation page')
        evidence = item.get('source_evidence'); _review_evidence(evidence)
        for name in ('raw_source', 'producer_row', 'registry', 'declaration_convention'):
            require(item.get(name) in evidence, 'Source limitation authority omitted from source evidence')
        producer = read_ref(item['producer_row'])
        require(all(producer.get(k) == item[k] for k in ('namespace', 'title', 'page_id', 'revision_id')) and
                producer.get('build_inputs') == complete['build_inputs'] and
                producer.get('raw_source') == item['raw_source'] and
                producer.get('source_input') in complete['build_inputs']['files'], 'Source limitation producer identity differs')
        raw = Path(item['raw_source']['path']).read_bytes(); declaration = item.get('declaration', {})
        start, end = declaration.get('start'), declaration.get('end')
        require(type(start) is int and type(end) is int and 0 <= start < end <= len(raw) and
                raw[start:end].decode('utf-8') == declaration.get('text') and
                declaration['text'] == '{{اللغة|' + label + '}}', 'Exact authored declaration differs')
        line_start = raw.rfind(b'\n', 0, start) + 1
        line_end = raw.find(b'\n', end)
        if line_end < 0: line_end = len(raw)
        before = raw[line_start:start].strip(); after = raw[end:line_end].strip()
        require(2 <= len(before) <= 6 and before == b'=' * len(before) and after == before,
                'Source limitation declaration is not an actual language heading')
        registry_ref = item['registry']
        require(registry_ref['sha256'] == complete['build_inputs']['auxiliary_snapshot_sha256']['language-registry'],
                'Source limitation resolver registry differs from actual build')
        registry = Path(registry_ref['path']).read_text(encoding='utf-8')
        require(registry.startswith('# wikidict-language-registry-v2\n') and
                '# content-language\tar\n' in registry, 'Unsupported source declaration convention')
        # Extra conservative collision veto only; this is not an implementation of the normal resolver.
        aliases = set()
        for line in registry.splitlines():
            if not line: continue
            if line.startswith('# local-alias\t'): aliases.update(line.split('\t')[1:])
            elif not line.startswith('#'): aliases.update(line.split('\t'))
        normalized = lambda value: value.removeprefix('ال').casefold()
        require(not any(normalized(label) == normalized(alias) for alias in aliases),
                'Known language alias cannot be treated as a source limitation')
        convention = read_ref(item['declaration_convention'])
        require(convention.get('label') == label and convention.get('canonical_language') is None and
                convention.get('source_authored_unsupported_declaration') is True and
                convention.get('known_language_alias_omission') is False,
                'Unsupported source declaration review missing')
        _review_evidence(convention.get('evidence'))
        require(convention.get('actual_producer_classification_observed') is True and
                convention.get('normal_registry_source_reviewed') is True and convention.get('no_new_resolver_query') is True and
                convention.get('source_snapshot') in convention['evidence'] and
                convention.get('resolver_source') in convention['evidence'], 'Normal registry/source review authority missing')
        source_snapshot = read_ref(convention['source_snapshot'])
        require(dict(head=source_snapshot['head'], fingerprint=source_snapshot['fingerprint']) == accepted['source'] and
                source_snapshot['fingerprint'] == complete['build_inputs']['source'] and
                source_snapshot['files']['tools/language_registry.zig'] == convention['resolver_source'],
                'Normal resolver source differs from the accepted producer')
        output_evidence = item.get('output_evidence'); _review_evidence(output_evidence)
        require(item.get('output_review') in output_evidence, 'Source limitation output review missing')
        output_review = read_ref(item['output_review'])
        require(output_review.get('schema') == 'wikidict.manual-page-review.v1' and
                output_review.get('verdict') == 'pass-with-documented-source-defect' and
                output_review.get('complete') == accepted['complete'] and
                output_review.get('raw_source') == item['raw_source'] and
                output_review.get('producer_row') == item['producer_row'] and
                output_review.get('label') == label and
                all(output_review.get(k) is True for k in ('all_positive_owners_accounted',
                    'whole_page_payload_conserved', 'known_owners_preserved')),
                'Source limitation whole-page/owner conservation review differs')
        bodies = _review_owner_exports(output_review, output_evidence, accepted, title)
        require('Unclassified' in bodies, 'Source limitation owner inventory is ambiguous')
        unclassified = bodies['Unclassified']
        require(any(section.get('title') == label for entry in unclassified['entries'] for section in entry.get('sections', [])),
                'Original unsupported declaration label was not retained')
        require(output_review.get('fallback') == dict(namespace=0, title=title, reasons=['unresolved_language_heading']),
                'Source limitation fallback disposition differs')
        result[key] = dict(namespace=0, title=title, reasons=['unresolved_language_heading'])
    return result



def _review_unsectioned_notices(review, accepted, complete):
    """Authenticate nonlexical notices; never infer a language or waive lexical errors."""
    references = review.get('source_authored_unsectioned_notices', [])
    require(isinstance(references, list) and len(references) <= 4096, 'Invalid unsectioned notice inventory')
    result = {}
    for reference in references:
        _review_evidence([reference]); item = read_ref(reference)
        require(item.get('schema') == 'wikidict.source-authored-unsectioned-notice.v1' and
                item.get('edition') == complete['edition'] and item.get('date') == complete['date'] and
                item.get('complete') == accepted['complete'] and item.get('build_inputs') == complete['build_inputs'],
                'Unsectioned notice belongs to another accepted publication')
        title = item.get('title')
        require(type(item.get('namespace')) is int and item['namespace'] == 0 and isinstance(title, str) and title and
                type(item.get('page_id')) is int and item['page_id'] > 0 and
                type(item.get('revision_id')) is int and item['revision_id'] > 0,
                'Unsectioned notice page identity missing')
        key = (0, title); require(key not in result, 'Duplicate unsectioned notice page')
        evidence = item.get('source_evidence'); _review_evidence(evidence)
        for name in ('raw_source', 'producer_row', 'source_review'):
            require(item.get(name) in evidence, 'Unsectioned notice source authority missing')
        producer = read_ref(item['producer_row'])
        require(all(producer.get(k) == item[k] for k in ('namespace', 'title', 'page_id', 'revision_id')) and
                producer.get('build_inputs') == complete['build_inputs'] and
                producer.get('raw_source') == item['raw_source'] and
                producer.get('source_input') in complete['build_inputs']['files'],
                'Unsectioned notice producer identity differs')
        authority = read_ref(item['source_review'])
        require(authority.get('schema') == 'wikidict.nonlexical-notice-source-review.v1' and
                authority.get('raw_source') == item['raw_source'] and authority.get('producer_row') == item['producer_row'] and
                all(authority.get(k) is True for k in ('whole_source_reviewed', 'nonlexical_notice',
                    'no_authored_language_declaration', 'no_authored_lexical_sections', 'producer_default_owner_observed')) and
                isinstance(authority.get('explanation'), str) and authority['explanation'].strip(),
                'Unsectioned notice source intent not established')
        _review_evidence(authority.get('evidence'))
        require(authority.get('source_snapshot') in authority['evidence'] and
                authority.get('classifier_source') in authority['evidence'], 'Unsectioned notice classifier authority missing')
        snapshot = read_ref(authority['source_snapshot'])
        require(dict(head=snapshot['head'], fingerprint=snapshot['fingerprint']) == accepted['source'] and
                snapshot['fingerprint'] == complete['build_inputs']['source'] and
                snapshot['files']['src/encoder/blob_builder.zig'] == authority['classifier_source'],
                'Unsectioned notice source review belongs to another producer')
        expected = authority.get('expected_entries_by_owner')
        require(isinstance(expected, dict) and expected and all(isinstance(owner, str) and owner and
                isinstance(entries, list) and entries for owner, entries in expected.items()),
                'Unsectioned notice exact source-derived presentation missing')
        output_evidence = item.get('output_evidence'); _review_evidence(output_evidence)
        require(item.get('output_review') in output_evidence, 'Unsectioned notice output review missing')
        output = read_ref(item['output_review'])
        require(output.get('schema') == 'wikidict.manual-page-review.v1' and
                output.get('verdict') == 'pass-with-documented-source-limitation' and
                output.get('complete') == accepted['complete'] and output.get('raw_source') == item['raw_source'] and
                output.get('producer_row') == item['producer_row'] and
                all(output.get(k) is True for k in ('all_positive_owners_accounted', 'whole_page_payload_conserved',
                    'known_owners_preserved', 'notice_text_actions_styles_and_rules_conserved')),
                'Unsectioned notice whole-page conservation review differs')
        bodies = _review_owner_exports(output, output_evidence, accepted, title)
        require({owner: body['entries'] for owner, body in bodies.items()} == expected,
                'Unsectioned notice source-derived body/action/style/rule contract differs')
        row = dict(namespace=0, title=title, reasons=['missing_language_heading'])
        require(output.get('fallback') == row, 'Unsectioned notice fallback differs')
        result[key] = row
    return result


def _review_lua_spans(bodies):
    """Enumerate actual semantic error spans, including repeated equal messages."""
    result = []
    def visit(value, owner, path):
        if isinstance(value, dict):
            if 'scribunto-error' in value.get('classes', '').split():
                require(value.get('kind') == 'text' and isinstance(value.get('text'), str) and
                        value['text'].startswith('Lua error in '), 'Unexpected Lua error span shape')
                result.append(dict(owner=owner, path=path, message=value['text']))
            for key, child in value.items(): visit(child, owner, path + [key])
        elif isinstance(value, list):
            for index, child in enumerate(value): visit(child, owner, path + [index])
    for owner, body in bodies.items(): visit(body, owner, [])
    return result



def _review_source_lua_defects(review, accepted, complete):
    """Only exact captured-source Lua defects with full saved output review qualify."""
    references = review.get('source_authored_lua_defects', [])
    require(isinstance(references, list) and len(references) <= 4096, 'Invalid source Lua defect inventory')
    result = {}; message_count = 0
    for reference in references:
        _review_evidence([reference]); item = read_ref(reference)
        require(item.get('schema') == 'wikidict.source-authored-lua-defect.v1' and
                item.get('edition') == complete['edition'] and item.get('date') == complete['date'] and
                item.get('complete') == accepted['complete'] and item.get('build_inputs') == complete['build_inputs'],
                'Source Lua defect belongs to another accepted publication')
        title = item.get('title'); key = (0, title)
        require(type(item.get('namespace')) is int and item['namespace'] == 0 and
                isinstance(title, str) and title and key not in result and
                type(item.get('page_id')) is int and item['page_id'] > 0 and
                type(item.get('revision_id')) is int and item['revision_id'] > 0,
                'Invalid or duplicate source Lua page identity')
        evidence = item.get('source_evidence'); _review_evidence(evidence)
        require(all(item.get(k) in evidence for k in ('raw_source', 'producer_row', 'source_trace', 'source_snapshot')),
                'Source Lua authority omitted')
        producer = read_ref(item['producer_row'])
        require(all(producer.get(k) == item[k] for k in ('namespace', 'title', 'page_id', 'revision_id')) and
                producer.get('raw_source') == item['raw_source'] and producer.get('build_inputs') == complete['build_inputs'] and
                producer.get('source_input') in complete['build_inputs']['files'], 'Source Lua producer identity differs')
        snapshot = read_ref(item['source_snapshot'])
        require(dict(head=snapshot['head'], fingerprint=snapshot['fingerprint']) == accepted['source'] and
                snapshot['fingerprint'] == complete['build_inputs']['source'], 'Source Lua producer source differs')
        trace = read_ref(item['source_trace'])
        require(trace.get('schema') == 'wikidict.manual-lua-source-trace.v1' and
                all(trace.get(k) == item[k] for k in ('edition', 'date', 'namespace', 'title', 'page_id', 'revision_id',
                    'raw_source', 'producer_row', 'source_snapshot', 'complete', 'build_inputs')) and
                trace.get('captured_source_defect') is True and trace.get('product_runtime_defect') is False and
                isinstance(trace.get('explanation'), str) and trace['explanation'].strip(),
                'Captured Lua source cause is not established')
        _review_evidence(trace.get('evidence'))
        dependencies = trace.get('captured_dependencies')
        require(isinstance(dependencies, list) and dependencies, 'Captured Lua dependency identities missing')
        for dependency_ref in dependencies:
            require(dependency_ref in trace['evidence'], 'Captured Lua dependency evidence omitted')
            dependency = read_ref(dependency_ref)
            require(type(dependency.get('page_id')) is int and dependency['page_id'] > 0 and
                    type(dependency.get('revision_id')) is int and dependency['revision_id'] > 0 and
                    dependency.get('source_input') in complete['build_inputs']['files'] and
                    dependency.get('raw_source') in trace['evidence'], 'Captured Lua dependency source differs')
        output_evidence = item.get('output_evidence'); _review_evidence(output_evidence)
        require(item.get('output_review') in output_evidence, 'Full Lua page output review missing')
        output = read_ref(item['output_review'])
        require(output.get('schema') == 'wikidict.manual-page-review.v1' and
                output.get('verdict') == 'pass-with-documented-source-defect' and
                output.get('complete') == accepted['complete'] and output.get('raw_source') == item['raw_source'] and
                output.get('producer_row') == item['producer_row'] and output.get('independent_limitations') == [] and
                all(output.get(k) is True for k in ('all_positive_owners_accounted', 'full_payload_reviewed',
                    'all_non_error_content_conserved', 'known_owners_preserved', 'all_actions_reviewed')),
                'Full Lua page content/owner review is not established')
        require(output.get('query_closure') is not None, 'Closed normal Reader query evidence required for Lua review')
        bodies = _review_owner_exports(output, output_evidence, accepted, title)
        errors = _review_lua_spans(bodies)
        require(errors and errors == output.get('lua_error_spans') == trace.get('lua_error_spans'),
                'Source Lua error spans differ or have extra/missing errors')
        causes = trace.get('causes')
        require(isinstance(causes, list) and len(causes) == len(errors), 'Every actual Lua span needs its source cause')
        for cause, error in zip(causes, errors):
            require(cause.get('span') == error and cause.get('kind') in
                    ('captured-missing-module', 'captured-module-api-mismatch', 'authored-argument-mismatch') and
                    isinstance(cause.get('explanation'), str) and cause['explanation'].strip() and
                    isinstance(cause.get('evidence'), list) and cause['evidence'] and
                    all(ref in trace['evidence'] for ref in cause['evidence']), 'Exact captured Lua cause evidence missing')
        fallback = dict(namespace=0, title=title, reasons=['rendered_lua_error'])
        require(output.get('fallback') == fallback, 'Lua-only fallback disposition differs')
        result[key] = fallback; message_count += len(errors)
    return result, message_count



def _review_fallbacks(path, expected_count, namespace_counts=None, source_limitations=None, source_lua_defects=None, unsectioned_notices=None):
    # Stream every row, including errors after any possible sample prefix.
    before = path.stat(); count = 0; reason_counts = {}; namespaces = {}; used = set()
    source_limitations = source_limitations or {}
    source_lua_defects = source_lua_defects or {}
    unsectioned_notices = unsectioned_notices or {}
    require(not (set(source_limitations) & set(source_lua_defects) or
                 set(unsectioned_notices) & (set(source_limitations) | set(source_lua_defects))),
            'Overlapping source dispositions')
    dispositions = dict(source_limitations)
    dispositions.update(source_lua_defects)
    dispositions.update(unsectioned_notices)
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
            key = (row['namespace'], row['title'])
            source_limited = key in dispositions
            if source_limited:
                require(key not in used and row == dispositions[key], 'Source limitation fallback row differs or repeats')
                used.add(key)
            for reason in reasons:
                require((source_limited and ((key in source_limitations and reason == 'unresolved_language_heading') or
                        (key in source_lua_defects and reason == 'rendered_lua_error') or
                        (key in unsectioned_notices and reason == 'missing_language_heading'))) or reason.split(':', 1)[0] not in
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
    require(set(dispositions) == used, 'Unused source limitation disposition')
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
        source_limitations = _review_source_limitations(review, accepted, complete)
        unsectioned_notices = _review_unsectioned_notices(review, accepted, complete)
        source_lua_defects, source_lua_messages = _review_source_lua_defects(review, accepted, complete)
        fallback_namespaces = {}
        reasons = _review_fallbacks(root / 'fallback-pages.jsonl', fallback_count, fallback_namespaces, source_limitations, source_lua_defects, unsectioned_notices)
        # Reuse the producer's exact bounded coverage/conservation validators.
        import build_wiktionaries as builder
        coverage = builder.validate_page_coverage(root, require_total=True)
        site_info_ref = review.get('site_info_snapshot')
        site_info_path = None
        if site_info_ref is not None:
            require(isinstance(site_info_ref, dict) and type(site_info_ref.get('bytes')) is int and
                    0 < site_info_ref['bytes'] <= 1024 * 1024,
                    'Site-info review authority exceeds bound')
            site_info = read_ref(site_info_ref)
            require(site_info_ref['sha256'] == complete['build_inputs'].get('auxiliary_snapshot_sha256', {}).get('site-info') and
                    site_info.get('schema') == 'wikidict.site-info.v2' and
                    site_info.get('wiki') == row['edition'] and site_info.get('date') == complete['date'],
                    'Site-info review authority differs from accepted build inputs')
            site_info_path = Path(site_info_ref['path'])
        if complete['build_inputs'].get('reviewed_nonlexical_sha256') is not None:
            builder.nonlexical.check_publication(root)
        namespace_totals = builder.validate_namespace_coverage(root, coverage['pages_seen'],
            fallback_counts=fallback_namespaces, site_info_snapshot=site_info_path)
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
                ((not source_limitations and content.get('no_unresolved_language_declarations') is True) or
                 (bool(source_limitations) and content.get('no_unresolved_language_declarations') is False and
                  content.get('source_unresolved_declarations_present') is True and
                  content.get('product_unresolved_language_errors') is False and
                  type(content.get('source_limitation_count')) is int and
                  content['source_limitation_count'] == len(source_limitations))) and
                ((not source_lua_defects and content.get('no_build_render_errors') is True) or
                 (source_lua_defects and content.get('no_build_render_errors') is False and
                  content.get('no_product_build_render_errors') is True and
                  content.get('source_authored_lua_defects_present') is True and
                  type(content.get('source_lua_defect_count')) is int and
                  content['source_lua_defect_count'] == len(source_lua_defects) and
                  type(content.get('source_lua_error_message_count')) is int and
                  content['source_lua_error_message_count'] == source_lua_messages)) and
                isinstance(content.get('explanation'), str) and content['explanation'].strip(),
                'Actual source intent and native output content review required')
        notice_fields = ('source_unsectioned_notices_present', 'source_unsectioned_notice_count',
                         'no_product_missing_language_errors')
        if unsectioned_notices or any(key in content for key in notice_fields):
            require(content.get('source_unsectioned_notices_present') is bool(unsectioned_notices) and
                    type(content.get('source_unsectioned_notice_count')) is int and
                    content['source_unsectioned_notice_count'] == len(unsectioned_notices) and
                    content.get('no_product_missing_language_errors') is True,
                    'Explicit source-authored unsectioned notice disposition required')
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


def campaign_selection(cfg, manifest):
    """Reconcile a selected normal manifest against pinned campaign history."""
    request = cfg.get('campaign')
    if request is None:
        return None
    require(isinstance(request, dict) and set(request) <= {'report', 'ledger', 'retry_failed', 'held'},
            'Unknown campaign selection field')
    report = read_ref(request['report']); ledger = read_ref(request['ledger'])
    require(report['sources']['campaign_ledger'] == request['ledger'], 'Stale campaign report/ledger join')
    inputs = report['report_refresh_inputs']
    inventory = read_ref(inputs['inventory']); baseline = read_ref(inputs['baseline'])
    require(baseline['history']['inventory'] == inputs['inventory'], 'Campaign inventory authority differs')
    inventory_rows = {row['wiki']: row for row in inventory['rows']}
    require(len(inventory_rows) == inventory['edition_count'] == 198 and not inventory['missing'],
            'Campaign requires the original complete inventory')
    attempts = ledger['attempts']
    identities = [{key: row[key] for key in ('edition', 'attempt_number', 'attempt_directory')} for row in attempts]
    require(report['deduplication']['identity_inventory']['campaign_logical_attempts'] == identities,
            'Campaign attempt identity join differs')
    require(len({row['attempt_directory'] for row in attempts}) == len(attempts), 'Duplicate campaign attempt')
    historical = set(baseline['history']['attempted_editions'])
    require(len(historical) == baseline['history']['attempted_count'] and historical <= set(inventory_rows),
            'Historical campaign inventory differs')
    attempted = historical | {row['edition'] for row in attempts}
    latest = {}; published = {}
    for row in attempts:
        require(row['edition'] in inventory_rows and type(row['attempt_number']) is int,
                'Invalid campaign edition/attempt')
        key = row['edition']
        if key not in latest or row['attempt_number'] > latest[key]['attempt_number']:
            latest[key] = row
        if row['outcome'] == 'passed-closed' and (key not in published or row['attempt_number'] > published[key]['attempt_number']):
            published[key] = row
    disposition = report['inventory_disposition']
    require(disposition['not_started_in_recorded_ledgers'] == len(set(inventory_rows) - attempted)
            and disposition['mechanical_publications'] == report['progress']['initial_mechanical_editions'] + len(published)
            and ledger['aggregate']['closed_production_attempts'] == len(attempts), 'Campaign aggregate join differs')
    selected = manifest['requested_editions']
    require(len(selected) == len(set(selected)) and set(selected) <= set(inventory_rows),
            'Selected editions are outside campaign inventory')
    retries = request.get('retry_failed', {}); held = request.get('held', {})
    require(isinstance(retries, dict) and isinstance(held, dict)
            and set(retries) <= set(selected) and set(held) <= set(selected), 'Campaign selection outside selected inputs')
    require(all(isinstance(reason, str) and reason.strip() for reason in held.values()), 'Held editions need explicit reasons')
    ready = []; dispositions = []
    for edition in selected_phase_editions(selected, 'all', manifest=manifest):
        items = [row for row in manifest['files'] if row['wiki'] == edition]
        xml = [{key: row[key] for key in ('name', 'size', 'sha1', 'url', 'date')} for row in items if '.xml' in row['name']]
        require(sorted(xml, key=lambda row: row['name']) == sorted(inventory_rows[edition]['members'], key=lambda row: row['name']),
                'Selected XML differs from original inventory')
        if edition in held:
            dispositions.append(dict(edition=edition, status='held', reason=held[edition])); continue
        if edition in published:
            row = published[edition]; closure = read_ref(row['closure_ref'])
            require(closure['cleanup_proven'] is True and closure['source_guard'] is True
                    and closure['outcome'] == 'passed-closed' and closure['production_started'] is True
                    and closure['result'] == row['result'], 'Published campaign closure differs')
            owner = read_ref(closure['configuration']); driver = read_ref(owner['driver_configuration'])
            require(all(driver[key] == row[key] for key in ('edition', 'date', 'attempt_number', 'attempt_directory', 'source_fingerprint')),
                    'Published campaign configuration differs')
            result = read_ref(row['result']); complete = read_ref(row['complete'])
            require(result['accepted'] is True and result['complete'] == row['complete']
                    and result['elapsed_seconds'] == row['elapsed_seconds'] == closure['production_elapsed_seconds']
                    and result['input_pages'] == row['input_pages'] == complete['input_pages']
                    and (complete['edition'], complete['date']) == (edition, cfg['date']), 'Published campaign result differs')
            expected = sorted([[v['wiki'], v['date'], v['name'], v['size'], v['sha1']] for v in items])
            require(complete['build_inputs']['files'] == expected
                    and complete['build_inputs']['source'] == row['source_fingerprint'], 'Published campaign input/source differs')
            accepted = dict(root=str(Path(row['complete']['path']).parent), complete=row['complete'], complete_snapshot=row['complete'])
            require(publication_present(accepted), 'Published campaign files are unavailable; explicit reconciliation required')
            dispositions.append(dict(edition=edition, status='skipped-published', closure=row['closure_ref'],
                                     complete=row['complete'], semantic_acceptance=False)); continue
        if edition in latest:
            row = latest[edition]
            if retries.get(edition) != row['closure_ref']:
                dispositions.append(dict(edition=edition, status='held-prior-failure', reason='No exact selected retry authority', closure=row['closure_ref'])); continue
            closure = read_ref(row['closure_ref'])
            require(closure['cleanup_proven'] is True and closure['source_guard'] is True and closure['production_started'] is True
                    and closure['outcome'] == row['outcome'] and closure['result'] == row['result']
                    and closure['production_elapsed_seconds'] == row['elapsed_seconds'],
                    'Prior failed production has unresolved source, cleanup or identity')
            failed_result = read_ref(row['result'])
            require(failed_result['elapsed_seconds'] == row['elapsed_seconds'] and failed_result.get('accepted') is False,
                    'Prior failed production result differs')
            old_driver = read_ref(read_ref(closure['configuration'])['driver_configuration'])
            require(all(old_driver[key] == row[key] for key in ('edition', 'date', 'attempt_number', 'attempt_directory', 'source_fingerprint')),
                    'Retry attempt identity differs')
            old_manifest = read_ref(old_driver['manifest'])
            registry = lambda value: [v for v in value.get('language_registries', []) if v['wiki'] == edition and v['date'] == cfg['date']]
            require(cfg['source']['fingerprint'] != row['source_fingerprint'] or registry(manifest) != registry(old_manifest),
                    'Identical failed producer/input retry is not selected')
        elif edition in attempted:
            dispositions.append(dict(edition=edition, status='held-historical', reason='Historical attempt requires its exact existing reconciliation route')); continue
        ready.append(edition)
    return dict(report=request['report'], ledger=request['ledger'], ready=ready, dispositions=dispositions,
                original_inventory_count=198, unstarted_count=len(set(inventory_rows) - attempted),
                historical_timing_imported=False, semantic_acceptance=False)


def edition_cli_options(cfg, edition):
    """Forward existing canonical options, authenticating each selected input."""
    from build_wiktionaries import AUXILIARY_SNAPSHOT_NAMES
    options = cfg.get('edition_options', {}).get(edition, {})
    require(isinstance(options, dict) and set(options) <= {'extraction_cache_root', 'staged_input_root', 'auxiliary_snapshots', 'interwiki_snapshot'},
            'Unknown edition option')
    argv = []
    if 'llvm_workers' in cfg:
        value = cfg['llvm_workers']
        require(type(value) is int and 1 <= value <= 4, 'LLVM workers must be 1 through 4')
        argv += ['--llvm-workers', str(value)]
    snapshots = options.get('auxiliary_snapshots', {})
    require(isinstance(snapshots, dict) and set(snapshots) <= set(AUXILIARY_SNAPSHOT_NAMES), 'Unknown auxiliary snapshot')
    for name, reference in sorted(snapshots.items()):
        require(descriptor(reference['path']) == reference and not any(p.is_symlink() for p in Path(reference['path']).parents),
                'Edition snapshot identity differs')
        argv += ['--' + name + '-snapshot', reference['path']]
    if 'interwiki_snapshot' in options:
        reference = options['interwiki_snapshot']
        require(descriptor(reference['path']) == reference and not any(p.is_symlink() for p in Path(reference['path']).parents),
                'Interwiki snapshot identity differs')
        argv += ['--interwiki-map-snapshot', reference['path']]
    if 'extraction_cache_root' in options:
        record = options['extraction_cache_root']; path = Path(record['path'])
        require(path.is_absolute() and not any(p.is_symlink() for p in (path, *path.parents)) and path.is_dir(), 'Unsafe extraction cache')
        st = path.stat()
        require((st.st_dev, st.st_ino, st.st_uid, st.st_mode & 0o777) == tuple(record[k] for k in ('device', 'inode', 'uid', 'mode'))
                and st.st_uid == os.geteuid() and st.st_mode & 0o200, 'Extraction cache identity or ownership differs')
        argv += ['--extraction-cache-root', str(path)]
    if 'staged_input_root' in options:
        record = options['staged_input_root']
        require(isinstance(record,dict) and set(record)=={'path','device','inode','uid','mode','completion'},
                'Invalid borrowed staged input record')
        require(isinstance(record['path'],str) and all(type(record[k]) is int for k in ('device','inode','uid','mode')),
                'Invalid borrowed staged input identity fields')
        path = Path(record['path'])
        require(path.is_absolute() and path.resolve()==path and not any(p.is_symlink() for p in (path,*path.parents))
                and path.is_dir(), 'Unsafe borrowed staged input')
        st = path.stat()
        require((st.st_dev,st.st_ino,st.st_uid,st.st_mode & 0o777)==tuple(record[k] for k in ('device','inode','uid','mode'))
                and st.st_uid==os.geteuid(), 'Borrowed staged input identity or ownership differs')
        reference=record['completion']
        require(isinstance(reference,dict) and reference.get('path')==str(path/'.complete.json')
                and descriptor(path/'.complete.json')==reference, 'Borrowed staged input completion differs')
        # The builder authenticates this existing marker against selected XML
        # inputs and verifies dump/index bytes. No copy or marker rewrite here.
        argv += ['--staged-input-root',str(path)]
    return argv


def command(cfg, edition, workers, memory_limit_bytes=MEMORY):
    require(type(memory_limit_bytes) is int and memory_limit_bytes == MEMORY,
            'Production memory budget must be 8 GiB')
    source, _ = source_roots(cfg)
    argv = [sys.executable, '-B', str(source / 'tools/build_wiktionaries.py'),
        '--resource-mode', 'watchdog', '--compress-shards', '--watchdog-address-space', 'unlimited',
        '--watchdog-memory-limit-mib', str(memory_limit_bytes // 1024**2),
        '--cpu-admission', 'affinity', '--threads', str(workers), '--jobs', '1',
        '--expansion-workers', str(workers), '--build-timeout-seconds', str(cfg['build_timeout_seconds']),
        '--now-unix', str(cfg['now_unix']), '--expansion-timeout-ms', str(cfg['expansion_timeout_ms']),
        '--downloads', cfg['downloads'], '--output', cfg['output'], '--raw-shard-root', cfg['raw_shard_root'],
        '--zig', cfg['compiler']['path'], '--wikis', edition]
    if cfg.get('artifact_root') is not None:
        argv += ['--artifact-root-spec', json.dumps(cfg['artifact_root'], sort_keys=True, separators=(',', ':'))]
    if cfg.get('workspace_root') is not None:
        argv += ['--workspace-root-spec', json.dumps(cfg['workspace_root'], sort_keys=True, separators=(',', ':'))]
    execution = execution_layout(cfg)
    if execution is not None:
        require(edition == execution['edition'], 'Command edition differs from execution manifest')
        argv += ['--execution-root-spec', json.dumps(cfg['execution_root'], sort_keys=True, separators=(',', ':')),
                 '--input-manifest', cfg['manifest']['path'], '--input-manifest-sha256', cfg['manifest']['sha256']]
    argv += edition_cli_options(cfg, edition)
    return argv



CONTEXT_KEYS = ('source', 'compiler', 'manifest', 'downloads', 'output', 'raw_shard_root',
                'date', 'now_unix', 'expansion_timeout_ms')

def production_context(cfg):
    values = {key: cfg[key] for key in CONTEXT_KEYS}
    if cfg.get('artifact_root') is not None:
        values['artifact_root'] = cfg['artifact_root']
    for key in ('campaign', 'edition_options', 'llvm_workers', 'workspace_root', 'execution_root', 'superseded_generated'):
        if key in cfg: values[key] = cfg[key]
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
    for key in (*CONTEXT_KEYS, 'state_directory', 'artifact_root', 'workspace_root', 'execution_root', 'build_timeout_seconds'):
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


def selected_phase_editions(editions, phase, defer_english=False, manifest=None):
    require(phase in ('pilot', 'remaining', 'all'), 'Unknown production phase')
    require(not defer_english or phase in ('remaining', 'all'), 'English deferral requires remaining or all phase')
    if phase == 'all':
        require(len(editions) == len(set(editions)) and isinstance(manifest, dict)
                and isinstance(manifest.get('files'), list), 'All-edition scheduling requires the selected manifest')
        from build_wiktionaries import smallest_first_group_key
        groups = [(edition, [item for item in manifest['files'] if item['wiki'] == edition]) for edition in editions]
        selected = [edition for edition, items in sorted(groups, key=smallest_first_group_key)]
    else:
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
            require(not cfg or cfg.get('campaign') is None, 'Unresolved campaign terminal requires explicit recovery; no automatic retry')
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
        if cfg and cfg.get('campaign') is not None:
            require(row.get('recovered') is not True and row.get('outcome') != 'interrupted'
                    and row.get('cleanup_proven') is True and row.get('source_guard') is True
                    and row.get('control_proven') is True,
                    'Unresolved campaign lifecycle requires explicit reconciliation')
            watchdog = read_ref(row['watchdog'])
            require(watchdog_closed(watchdog) and watchdog.get('termination_reason') == 'child_exit'
                    and watchdog.get('memory_limit_bytes') == row.get('memory_limit_bytes')
                    and type(watchdog.get('child_exit_status')) is int
                    and watchdog['child_exit_status'] == row.get('exit_code')
                    and (watchdog['child_exit_status'] == 0 if row.get('accepted') else watchdog['child_exit_status'] > 0),
                    'Campaign watchdog/source-control history is not safe to continue')
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


GENERATED_RETIREMENT_MAX_ENTRIES = 262144
GENERATION_PROC_VIEWS = ('/proc', '/mnt/ogroot/proc')


def _generated_tree_identity(path):
    import stat
    value = path.lstat()
    require(stat.S_ISDIR(value.st_mode) and not path.is_symlink(), 'Generated role is not a real directory')
    return (value.st_dev, value.st_ino, value.st_uid, value.st_mode)


def _generated_inventory(paths):
    """Bound work and byte accounting; external hardlinks keep their exact pins."""
    import stat
    identities, files, snapshot = set(), {}, {}
    visited = 0
    def unavailable(error):
        raise error
    for root in paths:
        device = root.stat().st_dev
        for parent, directories, names in os.walk(root, followlinks=False, onerror=unavailable):
            for path in [Path(parent), *(Path(parent) / name for name in directories + names)]:
                visited += 1
                require(visited <= GENERATED_RETIREMENT_MAX_ENTRIES, 'Generated role inventory exceeds bounded cleanup')
                info = path.lstat()
                require((stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)) and info.st_uid == os.geteuid(),
                        'Unproven generated descendant')
                require(info.st_dev == device, 'Generated role crosses a mount')
                require(path.name not in ('.presentation-first-failure', 'capture.json', 'diagnostic-result.json'),
                        'Unique diagnostic inside generated role')
                identity = (info.st_dev, info.st_ino)
                identities.add(identity)
                metadata = (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
                            info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_blocks)
                require(str(path) not in snapshot or snapshot[str(path)] == metadata,
                        'Generated descendant changed during inventory')
                snapshot[str(path)] = metadata
                if stat.S_ISREG(info.st_mode):
                    require(info.st_nlink == 1, 'Generated file has unproven external hardlinks')
                    files[identity] = dict(path=str(path), bytes=info.st_size, allocated_bytes=info.st_blocks * 512)
    return dict(identities=identities, files=files, visited=visited, snapshot=snapshot)


def _generation_process_identity(process):
    try:
        record = (process / 'stat').read_text()
        require(')' in record, 'Invalid process identity during cleanup')
        fields = record.rsplit(')', 1)[1].split()
        require(len(fields) > 19, 'Invalid process identity during cleanup')
        return dict(pid=int(process.name), start_time_ticks=int(fields[19]))
    except FileNotFoundError:
        return None


def _generated_consumers(identities):
    """Inspect both required process views with view-local birth identities."""
    views = [Path(path) for path in GENERATION_PROC_VIEWS]
    require(all(view.is_dir() for view in views), 'Required process visibility is unavailable')
    found, observed = [], set()
    for view in views:
        for process in view.iterdir():
            if not process.name.isdigit():
                continue
            try:
                directory = process.stat()
                if directory.st_uid != os.geteuid():
                    continue
                before = _generation_process_identity(process)
                if before is None:
                    continue
                key = (directory.st_dev, directory.st_ino, before['start_time_ticks'])
                if key in observed:
                    continue
                used = set()
                for path in [process / 'exe', process / 'cwd', *(process / 'fd').iterdir()]:
                    try:
                        info = path.stat()
                    except FileNotFoundError:
                        continue
                    if (info.st_dev, info.st_ino) in identities:
                        used.add(str(path))
                with (process / 'maps').open() as stream:
                    for line in stream:
                        fields = line.split(None, 5)
                        require(len(fields) >= 5, 'Invalid process mapping during cleanup')
                        major, minor = (int(value, 16) for value in fields[3].split(':'))
                        if (os.makedev(major, minor), int(fields[4])) in identities:
                            used.add('mapped generated inode')
                after = _generation_process_identity(process)
                if after is not None and after != before:
                    raise ValueError('Process birth changed during generated-consumer observation')
                if used and after is not None:
                    found.append(dict(identity=before, proc_view=str(view), uses=sorted(used)))
                observed.add(key)
            except FileNotFoundError:
                require(_generation_process_identity(process) is None,
                        'Live process visibility changed during generated-consumer observation')
    return found


def cleanup_superseded_generated(cfg, edition, folder, attempt, locks):
    """Retire explicitly released predecessor roles after a joined replacement.

    Config generation transfers only exact closed, consumer-released roles.
    Legacy generations without that relation remain manual cleanup work.
    """
    from build_artifact_root import (OwnedArtifactRoot, execution_mounts, execution_mount_regions,
                                     PRODUCER_SOURCE_FILES, PRODUCER_SOURCE_DIRECTORIES)
    selected = cfg.get('superseded_generated', {}).get(edition, [])
    require(isinstance(selected, list) and len(selected) <= 1, 'Invalid predecessor generation selection')
    if not selected:
        return dict(status='not-selected', generations=[])
    if (attempt.get('outcome') != 'passed' or not isinstance(attempt.get('accepted'), dict)
            or attempt.get('exit_code') != 0 or attempt.get('controller_interrupted') is not False
            or not all(attempt.get(name) is True for name in ('cleanup_proven', 'source_guard', 'control_proven'))):
        return dict(status='retained-no-valid-replacement', generations=[])
    for lock in locks:
        lock.check()
    expected_locks = tuple(map(str, resource_lock_paths(cfg)))
    require(tuple(str(lock.path) for lock in locks) == expected_locks and locks[0].own,
            'Current generation locks differ')
    # The tracked builder released this lock when it exited. Hold it again
    # while retiring predecessors, excluding direct ordinary builders too.
    fcntl.flock(locks[1].fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    results = []
    try:
        replacement = attempt['accepted']
        require(Path(replacement['root']) == Path(cfg['output']) / edition / cfg['date'],
                'Replacement publication root differs')
        require(publication_present(replacement), 'Replacement publication is unavailable')
        protected = [Path(cfg[name]) for name in ('output', 'raw_shard_root', 'state_directory', 'downloads')]
        for options in cfg.get('edition_options', {}).values():
            for name in ('staged_input_root', 'extraction_cache_root'):
                if name in options:
                    protected.append(Path(options[name]['path']))
        source, workspace = source_roots(cfg)
        protected.extend([source] if source != workspace else
                         [source / name for name in (*PRODUCER_SOURCE_FILES, *PRODUCER_SOURCE_DIRECTORIES)])
        protected.extend(Path(replacement[name]['path']) for name in ('complete', 'complete_snapshot'))
        mounts = execution_mounts()
        seen = set()
        for record in selected:
            require(isinstance(record, dict) and set(record) == {'configuration', 'result', 'closure', 'runtime_roles'},
                    'Invalid predecessor role fields')
            old = read_ref(record['configuration']); prior = read_ref(record['result']); closed = read_ref(record['closure'])
            roles = read_ref(record['runtime_roles'])
            require(old['date'] == cfg['date'] and prior['edition'] == edition
                    and Path(record['result']['path']).parent.parent.parent == Path(old['state_directory'])
                    and record['result'] in closed['attempts'] and closed['configuration'] == record['configuration']
                    and all(closed.get(name) is True for name in ('physical_closure', 'source_guard_after', 'cleanup_complete', 'ps_owned_absent')),
                    'Predecessor closure does not bind this generation')
            evidence = closed['attempt_evidence'][record['result']['path']]
            require(evidence['result'] == record['result'] and evidence['physical_closure'] is True
                    and evidence['source_guard_after'] is True and prior['cleanup_proven'] is True
                    and prior['source_guard'] is True and prior['control_proven'] is True,
                    'Predecessor attempt is not closed')
            require(tuple(map(str, resource_lock_paths(old))) == expected_locks,
                    'Predecessor uses a different lock domain')
            require(roles.get('schema') == 'wikidict.runtime-generated-artifact-role-dispositions.v1',
                    'Predecessor consumer release is unavailable')
            matches = [row for row in roles['records'] if row.get('configuration') == record['configuration']
                       and row.get('edition') == edition and row.get('date') == cfg['date']
                       and row.get('output_root') == old['output']]
            require(len(matches) == 1 and matches[0]['runtime_disposition'] ==
                    'NO_RUNTIME_EXECUTION_OR_QUEUED_REUSE_OF_GENERATED_WORKER_LLVM_OBJECT_TOOL_LEAVES'
                    and record['result'] in matches[0]['closed_results']
                    and old['output'] not in roles.get('keep_current_outputs', {}),
                    'Predecessor still has a selected consumer')
            parent = Path(old['output']) / edition; date = cfg['date']
            paths = [parent / (date + '.shards') / 'expander' / '.bundle-expander',
                     parent / (date + '.shards') / 'native-blob-tools',
                     parent / (date + '.building') / '.bundle-expander']
            require(matches[0]['derived_generated_parent_candidates'] == list(map(str, paths)),
                    'Released generated roles differ')
            require(str(parent) not in seen, 'Duplicate predecessor generation'); seen.add(str(parent))
            preserved = protected + [Path(old[name]) for name in ('state_directory', 'raw_shard_root', 'downloads')]
            preserved.extend(Path(record[name]['path']) for name in ('configuration', 'result', 'closure', 'runtime_roles'))
            if old.get('source', {}).get('root') is not None:
                preserved.append(Path(old['source']['root']['path']))
            for options in old.get('edition_options', {}).values():
                for name in ('staged_input_root', 'extraction_cache_root'):
                    if name in options:
                        preserved.append(Path(options[name]['path']))
            protected_regions = [region for path in preserved for region in execution_mount_regions(path, mounts)]
            owner = OwnedArtifactRoot(old['artifact_root'])
            for path in paths:
                owner.check_path(path)
                require(not any(path.is_relative_to(keep) or keep.is_relative_to(path) for keep in preserved),
                        'Predecessor overlaps current inputs or generation')
                require(not any(point != owner.path and point.is_relative_to(owner.path)
                                and (path.is_relative_to(point) or point.is_relative_to(path))
                                for point, _, _ in mounts), 'Generated role contains a mount alias')
                require(not any(device == other_device and (region.is_relative_to(other) or other.is_relative_to(region))
                                for device, region in execution_mount_regions(path, mounts)
                                for other_device, other in protected_regions),
                        'Predecessor physically aliases current inputs or generation')
            lock_path = parent / (date + '.lock'); owner.check_path(lock_path)
            fd = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                lock_info = os.fstat(fd)
                require(lock_info.st_nlink == 1 and (lock_info.st_dev, lock_info.st_ino) ==
                        (lock_path.stat().st_dev, lock_path.stat().st_ino), 'Predecessor edition lock changed')
                present = [(path, _generated_tree_identity(path)) for path in paths if path.exists() or path.is_symlink()]
                inventory = _generated_inventory([path for path, _ in present])
                require(not inventory['identities'] or not _generated_consumers(inventory['identities']),
                        'Generated predecessor has a live consumer')
                # Validate the entire selection before touching any tree. The
                # same metadata is checked again immediately before each removal.
                current = [(path, _generated_tree_identity(path)) for path in paths if path.exists() or path.is_symlink()]
                require(current == present and _generated_inventory([path for path, _ in current]) == inventory,
                        'Generated descendants changed before retirement')
                result = dict(configuration=record['configuration'], result=record['result'],
                              closure=record['closure'], removed=[], removed_file_count=0,
                              removed_logical_file_bytes=0, removed_allocated_file_bytes=0,
                              accounting='Completed removals from deduplicated inode inventory; not filesystem free-space delta',
                              preserved='Publication, inputs, raw shards, captures and all nonselected siblings')
                results.append(result)
                accounted = set()
                for path, identity in present:
                    removal_started = False
                    try:
                        for lock in locks: lock.check()
                        owner.check_path(path)
                        require(_generated_tree_identity(path) == identity, 'Generated role identity changed')
                        expected = {name: value for name, value in inventory['snapshot'].items()
                                    if Path(name).is_relative_to(path)}
                        require(_generated_inventory([path])['snapshot'] == expected,
                                'Generated descendants changed before retirement')
                        removal_started = True
                        owner.remove_tree(path)
                    except (OSError, ValueError) as exc:
                        # A failed filesystem removal may have made partial progress.
                        # Keep the known completed totals and state that uncertainty.
                        result.update(incomplete_removal=str(path), partial_removal_unknown=removal_started)
                        return dict(status='cleanup-deferred', error=f'{type(exc).__name__}: {exc}', generations=results)
                    result['removed'].append(str(path))
                    for key, value in inventory['files'].items():
                        if key not in accounted and Path(value['path']).is_relative_to(path):
                            accounted.add(key)
                            result['removed_file_count'] += 1
                            result['removed_logical_file_bytes'] += value['bytes']
                            result['removed_allocated_file_bytes'] += value['allocated_bytes']
            finally:
                os.close(fd)
        return dict(status='superseded-generated-retired', generations=results)
    finally:
        fcntl.flock(locks[1].fd, fcntl.LOCK_UN)


def execute(cfg, edition, workers, folder, sequence, context, locks, memory_limit_bytes=MEMORY):
    from build_resource_limits import _signal_owned
    folder.mkdir()
    start = dict(attempt_id=folder.name, sequence=sequence, edition=edition, date=cfg['date'],
        workers_requested=workers, memory_limit_bytes=memory_limit_bytes, address_space='unlimited', context=context,
        controller=process_identity(os.getpid()), started_utc=utc(), argv=command(cfg, edition, workers, memory_limit_bytes))
    write_json(folder / 'start.json', start)
    started = time.monotonic()
    error, process, rc = None, None, None
    interrupted = False
    source_verified = False
    source_observation = None
    control_verified = False
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
    phase_error = None
    try:
        evidence = phase_evidence(folder / 'build.log', edition, cfg['date'], strict=True) if log_ref else dict(production_started=False, end=None)
    except (OSError, ValueError) as exc:
        phase_error = f'{type(exc).__name__}: {exc}'
        error = '; '.join(part for part in (error, 'Invalid phase evidence: ' + phase_error) if part)
        evidence = dict(production_started=None, end=None)
    phase = evidence['end']
    accepted = None
    cleanup_proven = process is not None and process.poll() is not None and watchdog_closed(wd)
    try:
        for lock in locks:
            lock.check()
        observed_source = source_guard(cfg)
        source_observation = observed_source if isinstance(observed_source, dict) else None
        source_verified = True
        if wd:
            require(type(wd.get('memory_limit_bytes')) is int and wd['memory_limit_bytes'] == memory_limit_bytes,
                    'Actual watchdog memory budget differs from the requested attempt')
            control_verified = phase_error is None
        if error is None and rc == 0:
            require(cleanup_proven, 'Tracked watchdog cleanup is unproven')
            require(wd.get('child_exit_status') == wd.get('guardian_exit_status') == 0
                    and wd.get('termination_reason') == 'child_exit', 'Successful watchdog terminal missing')
            accepted = accept(cfg, edition, folder, phase, log_ref)
    except (OSError, ValueError) as exc:
        error = '; '.join(part for part in (error, f'{type(exc).__name__}: {exc}') if part)
    row = dict(attempt_id=folder.name, sequence=sequence, edition=edition, workers_requested=workers,
        memory_limit_bytes=memory_limit_bytes, outcome='passed' if accepted else 'failed', exit_code=rc, error=error, elapsed_seconds=elapsed,
        controller_interrupted=interrupted, cleanup_proven=cleanup_proven, source_guard=source_verified, control_proven=control_verified,
        source_observation=source_observation,
        timing_authority='actual controller monotonic interval around joined tracked CLI', ended_utc=utc(),
        execution_mode=phase.get('execution_mode') if phase else None, edition_build=phase, phase_evidence_error=phase_error,
        watchdog=descriptor(wdpath) if wdpath.exists() else None, build_log=log_ref, accepted=accepted)
    verification_only = None if phase_error else phase is not None and phase.get('execution_mode') == 'existing_output'
    row['controller_elapsed_seconds'] = elapsed
    row['verification_only'] = verification_only
    row['production_started'] = evidence['production_started'] and not verification_only
    row['elapsed_seconds'] = phase.get('seconds') if phase else (None if evidence['production_started'] is not False else 0.0)
    require(row['elapsed_seconds'] is None or (type(row['elapsed_seconds']) in (int, float)
            and math.isfinite(row['elapsed_seconds']) and row['elapsed_seconds'] >= 0), 'Invalid edition build time')
    row['production_elapsed_seconds'] = row['elapsed_seconds'] if row['production_started'] else None
    row['verification_elapsed_seconds'] = row['elapsed_seconds'] if verification_only else None
    row['timing_authority'] = 'actual edition_build terminal; existing_output is verification only; controller wall retained separately'
    row['not_ready_reason'] = 'Invalid phase evidence; production status and timing are unknown' if phase_error else (
        None if evidence['production_started'] else 'Normal builder stopped before edition_build; see exact build_log')
    write_json(folder / 'result.json', row)
    # Keep the original failure durable before optional generated-output retirement.
    if row['accepted'] is None:
        from build_wiktionaries import cleanup_failed_attempt_shards, write_failure_evidence
        cleanup_started = time.monotonic()
        try:
            for lock in locks:
                lock.check()
            payload_cleanup = cleanup_failed_attempt_shards(cfg, edition, folder, row)
        except (OSError, ValueError) as exc:
            payload_cleanup = dict(status='cleanup-error', error=f'{type(exc).__name__}: {exc}', partial_cleanup_possible=True)
        payload_cleanup['elapsed_seconds'] = time.monotonic() - cleanup_started
        write_failure_evidence(folder / 'generated-payload-cleanup.json', payload_cleanup)
    if cfg.get('superseded_generated'):
        retirement_started = time.monotonic()
        try:
            retirement = cleanup_superseded_generated(cfg, edition, folder, row, locks)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            retirement = dict(status='cleanup-deferred', error=f'{type(exc).__name__}: {exc}',
                              partial_cleanup_possible=True)
        retirement['elapsed_seconds'] = time.monotonic() - retirement_started
        try:
            write_json(folder / 'superseded-generated-cleanup.json', retirement)
        except OSError as exc:
            print(f'Generated cleanup receipt unavailable: {type(exc).__name__}: {exc}', file=sys.stderr, flush=True)
    return row, wd


def attempt_needed(rows, edition, *, retry_failed=False, revalidate=False):
    prior = [row for row in rows if row['edition'] == edition]
    if prior and prior[-1].get('accepted') and not revalidate:
        if publication_present(prior[-1]['accepted']):
            return False
    if prior and not prior[-1].get('accepted') and prior[-1]['outcome'] != 'interrupted' and not retry_failed:
        return False
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--phase', choices=('pilot', 'remaining', 'all'), default='pilot')
    parser.add_argument('--max-editions', type=int, help='Yield after N closed editions, including all own-cap retries; default unbounded')
    parser.add_argument('--retry-failed', action='store_true')
    parser.add_argument('--revalidate', action='store_true')
    parser.add_argument('--defer-english', action='store_true', help='Remaining/all phase: preserve English as pending while its capture completes')
    args = parser.parse_args(argv)
    require(args.max_editions is None or args.max_editions > 0, 'max-editions must be positive')
    cfg = read_json(args.config)
    require(cfg.get('armed') is True, 'Configuration remains unarmed')
    require(resource.getrlimit(resource.RLIMIT_AS) == (resource.RLIM_INFINITY, resource.RLIM_INFINITY), 'Controller requires inherited unlimited AS')
    _, workspace = source_roots(cfg)
    validate_pipeline_paths(cfg, workspace)
    execution = execution_layout(cfg)
    state = Path(cfg['state_directory'])
    require(not state.is_relative_to(Path(cfg['output'])) and not state.is_relative_to(Path(cfg['raw_shard_root'])), 'Receipts must be separate from build artifacts')
    require(descriptor(cfg['compiler']['path']) == cfg['compiler'], 'Pinned compiler changed')
    manifest = read_ref(cfg['manifest'])
    if execution is None:
        require(Path(cfg['manifest']['path']) == Path(cfg['downloads']) / 'manifest.json', 'Manifest selection differs')
    editions = manifest['requested_editions']
    if cfg.get('campaign') is None:
        if args.phase == 'all':
            require(isinstance(editions, list) and editions
                    and all(isinstance(edition, str) and edition for edition in editions)
                    and len(editions) == len(set(editions))
                    and set(editions) == {item['wiki'] for item in manifest['files']},
                    'Explicit all-phase selection requires nonempty unique editions matching manifest files')
        else:
            require(len(editions) == len(set(editions)) == 198 and set(PILOT) <= set(editions), 'Exactly the selected 198 editions required')
    else:
        require(args.phase == 'all' and not args.retry_failed and not args.revalidate,
                'Campaign selection uses all phase and exact per-edition retry authority')
    predecessors = cfg.get('superseded_generated', {})
    require(isinstance(predecessors, dict) and set(predecessors) <= set(editions)
            and all(isinstance(rows, list) and len(rows) <= 1 for rows in predecessors.values()),
            'Predecessors must select at most one closed generation per edition')
    campaign = campaign_selection(cfg, manifest)
    require({x['date'] for x in manifest['files']} == {cfg['date']} == {'20261001'}, 'Dump date selection changed')
    source_guard(cfg)
    gate(cfg['qualification'], cfg, ('passed-closed',))
    gate(cfg['diagnostic_disposition'], cfg, ('resolved', 'passed-closed'))
    context = production_context(cfg)
    state.mkdir(parents=True, exist_ok=True)
    (state / 'attempts').mkdir(exist_ok=True)
    with ExitStack() as stack:
        controller_lock, build_lock = resource_lock_paths(cfg)
        locks = [stack.enter_context(Lock(controller_lock, True)),
                 stack.enter_context(Lock(build_lock, False))]
        rows = history(state, context, cfg)
        if campaign is not None:
            skipped = {row['edition'] for row in campaign['dispositions'] if row['status'] == 'skipped-published'}
            failed_verification = set()
            for row in sorted(rows, key=lambda row: row['sequence']):
                if row.get('accepted'):
                    failed_verification.discard(row['edition'])
                elif row.get('execution_mode') == 'existing_output':
                    failed_verification.add(row['edition'])
            require(not (failed_verification & skipped),
                    'Failed publication verification requires campaign reconciliation before skipping')
        preparations = load_preparations(cfg)
        current = summarize(rows, editions, preparations)
        if args.phase == 'remaining':
            review = gate(cfg['pilot_review'], cfg, ('passed', 'passed-closed'))
            pilot_rows = [row for row in current['editions'] if row['edition'] in PILOT]
            validate_content_review(review, cfg['source'], pilot_rows, PILOT, scope='pilot')
        selected = selected_phase_editions(editions, args.phase, args.defer_english, manifest=manifest)
        if campaign is not None:
            selected = [edition for edition in selected if edition in campaign['ready']]
            write_json(state / 'campaign-selection.json', campaign, replace=True)
        sequence = max((x['sequence'] for x in rows), default=0)
        completed_editions = []
        pending_editions = []
        for position, edition in enumerate(selected):
            if not attempt_needed(rows, edition, retry_failed=args.retry_failed, revalidate=args.revalidate):
                continue
            if campaign is not None:
                try:
                    edition_cli_options(cfg, edition)
                except (OSError, ValueError) as exc:
                    campaign['dispositions'].append(dict(edition=edition, status='not-ready', reason=str(exc)))
                    write_json(state / 'campaign-selection.json', campaign, replace=True)
                    continue
            workers = next(x for x in WORKERS if x <= len(os.sched_getaffinity(0)))
            memory_limit_bytes = MEMORY
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
                require(row.get('source_guard') is True, 'Production source is unproven; no next edition admitted')
                require(row.get('control_proven') is True, 'Production control validation failed; no next edition admitted')
                if campaign is not None and row.get('not_ready_reason'):
                    campaign['dispositions'].append(dict(edition=edition, status='not-ready', reason=row['not_ready_reason'], build_log=row['build_log']))
                    write_json(state / 'campaign-selection.json', campaign, replace=True)
                if row['accepted']:
                    break
                following = next_resources(workers, memory_limit_bytes, wd)
                if following is None:
                    require(wd.get('termination_reason') == 'child_exit'
                            and type(wd.get('child_exit_status')) is int and wd['child_exit_status'] > 0,
                            'Non-ordinary watchdog outcome halts independent continuation')
                    break
                workers, memory_limit_bytes = following
            completed_editions.append(edition)
            if args.max_editions is not None and len(completed_editions) >= args.max_editions:
                pending_editions = [candidate for candidate in selected[position + 1:]
                    if attempt_needed(rows, candidate, retry_failed=args.retry_failed, revalidate=args.revalidate)]
                break
        summary = summarize(rows, editions, preparations)
        summary['execution'] = dict(outcome='batch-complete' if pending_editions else 'selection-complete',
            max_editions=args.max_editions, completed_editions=completed_editions, pending_editions=pending_editions,
            all_selected_editions_processed=not pending_editions)
        if campaign is not None:
            summary['campaign_selection'] = campaign
        write_json(state / 'summary.json', summary, replace=True)
        skipped = {row['edition'] for row in campaign['dispositions'] if row['status'] == 'skipped-published'} if campaign else set()
        print(json.dumps(dict(summary=str(state / 'summary.json'), remaining=[x['edition'] for x in summary['editions'] if not x['accepted'] and x['edition'] not in skipped], deferred=['enwiktionary'] if args.defer_english else [], execution=summary['execution'])))
    if pending_editions:
        return 0 if all(next(row for row in reversed(rows) if row['edition'] == edition).get('accepted')
                        for edition in completed_editions) else 1
    held = campaign is not None and any(row['status'] != 'skipped-published' for row in campaign['dispositions'])
    return 0 if not held and all(x['accepted'] for x in summary['editions'] if x['edition'] in selected) else 1


if __name__ == '__main__':
    raise SystemExit(main())
