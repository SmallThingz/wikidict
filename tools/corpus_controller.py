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


def command(cfg, edition, workers):
    return [sys.executable, '-B', str(ROOT / 'tools/build_wiktionaries.py'),
        '--resource-mode', 'watchdog', '--watchdog-address-space', 'unlimited',
        '--cpu-admission', 'affinity', '--threads', str(workers), '--jobs', '1',
        '--expansion-workers', str(workers), '--build-timeout-seconds', str(cfg['build_timeout_seconds']),
        '--now-unix', str(cfg['now_unix']), '--expansion-timeout-ms', str(cfg['expansion_timeout_ms']),
        '--downloads', cfg['downloads'], '--output', cfg['output'], '--raw-shard-root', cfg['raw_shard_root'],
        '--zig', cfg['compiler']['path'], '--wikis', edition]


def history(state, context):
    rows = []
    attempts = state / 'attempts'
    for folder in sorted(attempts.iterdir()):
        if not folder.is_dir():
            continue
        start = read_json(folder / 'start.json')
        require(start['context'] == context, 'Run directory has another source/input configuration')
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


def execute(cfg, edition, workers, folder, sequence, context, locks):
    from build_resource_limits import _signal_owned
    folder.mkdir()
    start = dict(attempt_id=folder.name, sequence=sequence, edition=edition, date=cfg['date'],
        workers_requested=workers, memory_limit_bytes=MEMORY, address_space='unlimited', context=context,
        controller=process_identity(os.getpid()), started_utc=utc(), argv=command(cfg, edition, workers))
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
        if error is None and rc == 0:
            require(cleanup_proven, 'Tracked watchdog cleanup is unproven')
            require(wd.get('child_exit_status') == wd.get('guardian_exit_status') == 0
                    and wd.get('termination_reason') == 'child_exit', 'Successful watchdog terminal missing')
            accepted = accept(cfg, edition, folder, phase, log_ref)
    except (OSError, ValueError) as exc:
        error = f'{type(exc).__name__}: {exc}'
    row = dict(attempt_id=folder.name, sequence=sequence, edition=edition, workers_requested=workers,
        outcome='passed' if accepted else 'failed', exit_code=rc, error=error, elapsed_seconds=elapsed,
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
    args = parser.parse_args(argv)
    cfg = read_json(args.config)
    require(cfg.get('armed') is True, 'Configuration remains unarmed')
    require(resource.getrlimit(resource.RLIMIT_AS) == (resource.RLIM_INFINITY, resource.RLIM_INFINITY), 'Controller requires inherited unlimited AS')
    for key in ('downloads', 'output', 'raw_shard_root', 'state_directory'):
        path = Path(cfg[key])
        require(path.is_absolute() and path.is_relative_to(ROOT / 'data')
                and not any(p.is_symlink() for p in (path, *path.parents)), 'Use explicit non-symlink repository data paths')
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
    context = hashlib.sha256(json.dumps({k: cfg[k] for k in ('source', 'compiler', 'manifest', 'downloads', 'output', 'raw_shard_root', 'date', 'now_unix', 'expansion_timeout_ms')}, sort_keys=True).encode()).hexdigest()
    state.mkdir(parents=True, exist_ok=True)
    (state / 'attempts').mkdir(exist_ok=True)
    with ExitStack() as stack:
        locks = [stack.enter_context(Lock(ROOT / 'data/build-resources/corpus-controller.lock', True)),
                 stack.enter_context(Lock(ROOT / '.tmp/build-resources.lock', False))]
        rows = history(state, context)
        preparations = load_preparations(cfg)
        current = summarize(rows, editions, preparations)
        if args.phase == 'remaining':
            review = gate(cfg['pilot_review'], cfg, ('passed', 'passed-closed'))
            expected = {x['edition']: x['accepted']['complete']['sha256'] for x in current['editions'] if x['edition'] in PILOT and x['accepted']}
            require(set(expected) == set(PILOT) and review['accepted_completions'] == expected, 'Actual current eight-edition content review required')
        selected = PILOT if args.phase == 'pilot' else [x for x in edition_order(editions) if x not in PILOT]
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
            while workers:
                for lock in locks:
                    lock.check()
                source_guard(cfg)
                sequence += 1
                folder = state / 'attempts' / f'{sequence:06d}-{edition}-w{workers}-{uuid.uuid4().hex[:12]}'
                row, wd = execute(cfg, edition, workers, folder, sequence, context, locks)
                rows.append(row)
                write_json(state / 'summary.json', summarize(rows, editions, preparations), replace=True)
                if row['controller_interrupted']:
                    return 130
                require(row['cleanup_proven'], 'Owned cleanup is unproven; no next edition admitted')
                if row['accepted']:
                    break
                workers = next_workers(workers, wd)
        summary = summarize(rows, editions, preparations)
        write_json(state / 'summary.json', summary, replace=True)
        print(json.dumps(dict(summary=str(state / 'summary.json'), remaining=[x['edition'] for x in summary['editions'] if not x['accepted']])))
    return 0 if all(x['accepted'] for x in summary['editions'] if x['edition'] in selected) else 1


if __name__ == '__main__':
    raise SystemExit(main())
