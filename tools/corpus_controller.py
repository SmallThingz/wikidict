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
import re
import resource
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

def selected_python_tooling(cfg):
    """Load only an explicitly authenticated tooling selector; preserve script origins."""
    import importlib.util
    import stat
    selection=cfg.get('python_tooling')
    if selection is None:
        if 'wikidict_python_tooling' in sys.modules and getattr(sys.modules['wikidict_python_tooling'],'_ACTIVE',None) is not None:
            raise ValueError('Cannot drop selected Python tooling within an invocation')
        return None
    reference=selection['selector'];path=Path(reference['path'])
    if (not path.is_absolute() or str(path)!=os.path.normpath(str(path))
            or any(p.is_symlink() for p in (path,*path.parents))):
        raise ValueError('Unsafe Python tooling selector path')
    with path.open('rb') as stream:
        before=os.fstat(stream.fileno());data=stream.read();after=os.fstat(stream.fileno())
    fields=('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns','st_mode')
    if (not all(getattr(before,k)==getattr(after,k)==getattr(path.stat(),k) for k in fields)
            or len(data)!=reference['bytes'] or hashlib.sha256(data).hexdigest()!=reference['sha256']
            or stat.S_IMODE(before.st_mode)!=reference['mode'] or before.st_uid!=os.geteuid()):
        raise ValueError('Selected Python tooling selector changed')
    module=sys.modules.get('wikidict_python_tooling')
    if module is None:
        module=importlib.util.module_from_spec(importlib.util.spec_from_loader('wikidict_python_tooling',loader=None))
        module.__file__=str(path);sys.modules['wikidict_python_tooling']=module
        try:exec(compile(data,str(path),'exec'),module.__dict__)
        except BaseException:
            sys.modules.pop('wikidict_python_tooling',None);raise
    elif Path(module.__file__)!=path:
        raise ValueError('Different Python tooling selector is already imported')
    selected=module.select(selection,role='corpus_controller',origin=__file__)
    if cfg.get('prepared_source_custody') is True:selected.require_prepared_imports()
    return selected


_CONTROLLER_TOOLING=None
if '--python-tooling-json' in sys.argv:
    if sys.argv.count('--python-tooling-json')!=1 or sys.argv.index('--python-tooling-json')+1>=len(sys.argv):
        raise ValueError('Invalid controller Python tooling CLI')
    _CONTROLLER_TOOLING=selected_python_tooling({'python_tooling':json.loads(sys.argv[sys.argv.index('--python-tooling-json')+1])})

from build_artifact_root import validate_pipeline_paths, execution_paths, refuse_execution_destinations

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


def _receipt_stat(path):
    require(path.is_file() and not path.is_symlink(), f'Unsafe receipt: {path}')
    return path.stat()


def _checked_descriptor(path, before, checksum):
    after = path.stat()
    fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
    require(all(getattr(after, k) == getattr(before, k) for k in fields), f'Changed while reading: {path}')
    return dict(path=str(path), bytes=before.st_size, sha256=checksum)


def descriptor(path):
    path = Path(path).absolute()
    before = _receipt_stat(path)
    return _checked_descriptor(path, before, digest(path))


def read_json(path):
    path = Path(path)
    require(path.stat().st_size <= 8 * 1024**2, f'Metadata exceeds bound: {path}')
    value = json.loads(path.read_bytes())
    if (path.name == 'complete.json' and isinstance(value, dict)
            and isinstance(value.get('build_inputs'), dict)
            and 'native_tool_roles_details' in value['build_inputs']):
        from build_wiktionaries import restore_publication_metadata
        return restore_publication_metadata(path.parent, value)
    return value


def read_ref(ref):
    path = Path(ref['path']).absolute()
    before = _receipt_stat(path)
    require(before.st_size <= 8 * 1024**2, f'Metadata exceeds bound: {path}')
    with path.open('rb') as stream:
        data = stream.read(before.st_size + 1)
    actual = _checked_descriptor(path, before, hashlib.sha256(data).hexdigest())
    require(len(data) == before.st_size and actual == ref, 'Receipt bytes changed')
    value = json.loads(data)
    if (path.name == 'complete.json' and isinstance(value, dict)
            and isinstance(value.get('build_inputs'), dict)
            and 'native_tool_roles_details' in value['build_inputs']):
        from build_wiktionaries import restore_publication_metadata
        return restore_publication_metadata(path.parent, value)
    return value


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


def _phase_evidence(lines, edition, date, *, strict=False):
    starts, ends = [], []
    for line in lines:
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


def phase_evidence(log_path, edition, date, *, strict=False):
    with Path(log_path).open(errors='replace') as stream:
        return _phase_evidence(stream, edition, date, strict=strict)


_PHASE_LINE = re.compile(rb'BUILD_PHASE [^\r\n]*')


def _hashed_phase_lines(stream, checksum, block_size):
    """Hash every byte, decoding only phase records at logical line starts."""
    tail = bytearray()
    prefix = b'BUILD_PHASE '
    for block in iter(lambda: stream.read(block_size), b''):
        checksum.update(block)
        end = 1 + max(block.rfind(b'\n'), block.rfind(b'\r'))
        if end:
            tail.extend(block[:end])
            for match in _PHASE_LINE.finditer(tail):
                if match.start() == 0 or tail[match.start() - 1] in (10, 13):
                    yield match.group().decode(errors='replace')
            tail = bytearray(block[end:])
        else:
            tail.extend(block)
        # Retain one non-prefix byte for skipped lines so a mid-line marker at
        # the next block boundary cannot start a record.
        if tail and not (tail.startswith(prefix) or prefix.startswith(tail)):
            tail = bytearray(b'!')
    if tail.startswith(prefix):
        yield tail.decode(errors='replace')


def read_attempt_log(path, edition, date, *, block_size=1024 * 1024):
    path = Path(path).absolute()
    if not path.exists():
        return None, dict(production_started=False, end=None), None
    before = _receipt_stat(path)
    checksum = hashlib.sha256()
    error = None
    with path.open('rb') as stream:
        try:
            evidence = _phase_evidence(_hashed_phase_lines(stream, checksum, block_size),
                                       edition, date, strict=True)
        except ValueError as exc:
            error = f'{type(exc).__name__}: {exc}'
            evidence = dict(production_started=None, end=None)
            # The current block has already been hashed. A malformed record
            # still needs an authenticated receipt for the rest of the log.
            for block in iter(lambda: stream.read(block_size), b''):
                checksum.update(block)
    return _checked_descriptor(path, before, checksum.hexdigest()), evidence, error


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
    histories = {edition: [] for edition in edition_order(editions)}
    unique = {}
    for row in attempt_results:
        key = row['attempt_id']
        if key in unique:
            require(unique[key] == row, 'Conflicting attempt identity')
            continue
        require(row['edition'] in histories, 'Attempt outside configured corpus')
        unique[key] = row
        histories[row['edition']].append(row)
    preparation_by_id = {}
    preparations_by_edition = {}
    for prep in preparations:
        key = prep['preparation_id']
        require(key not in unique, 'Preparation interval is also an attempt')
        require(key not in preparation_by_id or preparation_by_id[key] == prep, 'Conflicting preparation identity')
        require(prep['edition'] in histories and prep['outcome'] in ('passed', 'failed', 'superseded'), 'Preparation outside configured corpus')
        seconds = prep['elapsed_seconds']
        require(type(seconds) in (int, float) and math.isfinite(seconds) and seconds >= 0, 'Invalid preparation interval')
        if key not in preparation_by_id:
            preparation_by_id[key] = prep
            preparations_by_edition.setdefault(prep['edition'], []).append(prep)
    rows = []
    unknown = []
    for edition, history in histories.items():
        measured = [attempt_phase_seconds(x) for x in history if x.get('execution_mode') != 'existing_output']
        timing_unknown = any(x is None for x in measured)
        known_build_seconds = sum(seconds for seconds in measured if seconds is not None)
        own_preparations = preparations_by_edition.get(edition, [])
        preparation_seconds = sum(x['elapsed_seconds'] for x in own_preparations)
        # Equal sequence numbers retain the last distinct input, as in the stable sequence sort.
        latest = max(reversed(history), key=lambda x: x['sequence'], default={})
        current = latest.get('accepted')
        verification = [attempt_phase_seconds(x) for x in history if x.get('execution_mode') == 'existing_output'] if edition not in EXCLUDED else []
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
            verification_seconds=None if edition in EXCLUDED or None in verification else sum(verification),
            original_build_time_unknown=original_unknown, latest_outcome=latest.get('outcome')))
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
    selected=selected_python_tooling(cfg)
    if selected is not None:
        source,workspace=selected.source_root,selected.workspace_root
        require(cfg.get('source',{}).get('root') in (None,selected.spec['source_root'],str(source)), 'Native source root differs from Python tooling selection')
        require(cfg.get('workspace_root') in (None,selected.spec['workspace_root'],str(workspace)), 'Workspace differs from Python tooling selection')
        return source,workspace
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


def derive_launch_output_paths(cfg, *, edition, attempt_suffix, supplied=None,
                               created_runtime_identity=None):
    """Derive the binder's complete absent output set before any mutation."""
    import re
    import stat
    require(isinstance(edition, str) and re.fullmatch(r'[a-z0-9_]+wiktionary', edition),
            'Invalid launch edition')
    require(isinstance(attempt_suffix, str)
            and re.fullmatch(r'[a-z0-9][a-z0-9-]{0,63}', attempt_suffix),
            'Invalid launch attempt suffix')
    require(isinstance(cfg.get('edition_options'), dict)
            and set(cfg['edition_options']) == {edition}, 'Launch edition differs')
    _, workspace = source_roots(cfg)
    roots = {}
    for key in ('state_directory', 'output', 'raw_shard_root'):
        value = cfg.get(key)
        require(isinstance(value, str), 'Missing launch target root')
        path = Path(value)
        require(path.is_absolute() and str(path) == value
                and os.path.normpath(value) == value
                and path.is_relative_to(workspace / 'data')
                and not any(node.is_symlink() for node in (path, *path.parents)),
                'Unsafe launch target root')
        roots[key] = path
    state = roots['state_directory']
    require(state.name.startswith('state-'), 'Invalid launch state target')
    target = state.name[len('state-'):]
    language = edition[:-len('wiktionary')]
    require(re.fullmatch(r'native[0-9]+-' + re.escape(language) + r'-current[0-9]+(?:-[a-z0-9]+)*', target)
            is not None, 'Launch target edition differs')
    require(roots['output'].name == 'dictionaries-' + target
            and roots['raw_shard_root'].name == 'raw-shards-' + target,
            'Launch target roots differ')
    campaign = state.parent
    binder = campaign / 'native10-input-preparation01'
    stem = target + '.' + attempt_suffix
    paths = dict(configuration=str(campaign / ('configuration.' + stem + '.armed.json')),
                 arming=str(campaign / ('arming.' + stem + '.json')),
                 archive=str(binder / (stem + '.archive')),
                 result=str(binder / (stem + '.result.json')),
                 runtime=str(binder / (stem + '.runtime')))
    require(supplied is None or isinstance(supplied, dict) and supplied == paths,
            'Launch output set differs from selected target')
    require(created_runtime_identity is None or supplied is not None,
            'Created runtime identity requires the complete supplied output set')
    for role, value in paths.items():
        path = Path(value)
        require(not any(node.is_symlink() for node in (path, *path.parents)),
                'Symlink in launch output path')
        if role == 'runtime' and created_runtime_identity is not None:
            # This identity is captured by the owner after its exclusive mkdir,
            # passed through the worker header, and never accepted from DATA.
            require(isinstance(created_runtime_identity, dict)
                    and set(created_runtime_identity) == {'dev', 'ino', 'mode', 'uid'}
                    and all(type(v) is int for v in created_runtime_identity.values()),
                    'Invalid owner-created runtime identity')
            observed = path.lstat()
            require(stat.S_ISDIR(observed.st_mode) and observed.st_uid == os.geteuid()
                    and created_runtime_identity == dict(dev=observed.st_dev,
                        ino=observed.st_ino, mode=observed.st_mode, uid=observed.st_uid),
                    'Owner-created runtime identity changed')
        else:
            require(not path.exists(), 'Launch output already exists')
        parent = path.parent.stat()
        require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.geteuid(),
                'Launch output parent is not owned')
    return paths


def normalize_launch_handoff(cfg, *, locks, runtime, create_runtime=False):
    """Validate launch DATA; the existing owner alone creates its runtime directory."""
    import stat
    require(type(create_runtime) is bool, 'Invalid runtime creation flag')
    expected = resource_lock_paths(cfg)
    require(isinstance(locks, list) and len(locks) == len(expected),
            'Launch lock count differs')
    normalized = []
    schema = None
    for row, path in zip(locks, expected):
        require(isinstance(row, dict), 'Invalid launch lock descriptor')
        keys = set(row)
        require(keys in ({'path', 'device', 'inode'}, {'path', 'dev', 'ino'}),
                'Launch lock fields differ')
        require(schema is None or keys == schema, 'Mixed launch lock schemas')
        schema = keys
        dev_key, ino_key = ('device', 'inode') if 'device' in row else ('dev', 'ino')
        require(isinstance(row['path'], str) and row['path'] == str(path)
                and type(row[dev_key]) is int and row[dev_key] >= 0
                and type(row[ino_key]) is int and row[ino_key] > 0,
                'Launch lock path or identity fields differ')
        require(not any(node.is_symlink() for node in (path, *path.parents)),
                'Symlink in launch lock path')
        observed = path.stat()
        require(stat.S_ISREG(observed.st_mode) and observed.st_uid == os.geteuid()
                and observed.st_nlink == 1
                and (observed.st_dev, observed.st_ino) == (row[dev_key], row[ino_key]),
                'Launch lock identity changed')
        normalized.append(dict(path=str(path), dev=row[dev_key], ino=row[ino_key]))
    require(isinstance(runtime, str), 'Invalid launch runtime path')
    target = Path(runtime)
    _, workspace = source_roots(cfg)
    require(target.is_absolute() and str(target) == runtime
            and runtime == os.path.normpath(runtime)
            and any(target.is_relative_to(workspace / name) and target != workspace / name
                    for name in ('.tmp', 'data'))
            and not any(node.is_symlink() for node in (target, *target.parents)),
            'Launch runtime path is not an owned canonical runtime destination')
    require(not target.exists(), 'Launch runtime already exists')
    parent = target.parent.stat()
    require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.geteuid(),
            'Launch runtime parent is not owned')
    if create_runtime:
        # No parents=True or exist_ok=True: never adopt another owner's output.
        target.mkdir()
    return dict(runtime=str(target), locks=normalized)


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
    require(cfg.get('python_tooling') is not None or Path(__file__).resolve().parents[1] == source,
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
    selector=sys.modules.get('wikidict_python_tooling')
    selected=getattr(selector,'_ACTIVE',None) if selector is not None else None
    if selected is not None:
        selected.require_unchanged();require(builder.PROJECT==source,'Selected builder native root differs');return
    require(Path(builder.__file__).resolve() == source / 'tools/build_wiktionaries.py'
            and builder.PROJECT == source, 'Builder import belongs to another producer root')
    helper_names = {Path(name).stem for name in files
                    if Path(name).parent.as_posix() == 'tools' and name.endswith('.py')}
    for name, origin in loaded_module_origins().items():
        path = Path(origin).absolute()
        if name in helper_names or path.is_relative_to(workspace):
            require(path.is_relative_to(source) and path.relative_to(source).as_posix() in files,
                    'Loaded project helper is outside the bound producer inventory: ' + name)


def prepared_git_source_authority(cfg, *, retained=None):
    """Bind original tracked bytes once; later keep their exact Git objects available.

    This is producer provenance, not permission to release any runtime input.
    Private donors without this exact committed inventory remain unsupported.
    """
    import hashlib
    import re
    source, workspace = source_roots(cfg)
    require(source == workspace, 'Prepared Git authority requires the original canonical producer')
    head = cfg['source']['head']
    require(isinstance(head, str) and re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', head) is not None,
            'Prepared source lacks an immutable Git commit')
    inventory_ref = cfg['source']['inventory']
    inventory = read_ref(inventory_ref)
    require(inventory['head'] == head, 'Prepared Git inventory belongs to another producer')
    require(subprocess.check_output(['git', '--no-replace-objects', 'rev-parse', '--verify', head + '^{commit}'],
                                    cwd=source, text=True).strip() == head, 'Prepared source is not an exact Git commit')
    tree = subprocess.check_output(['git', '--no-replace-objects', 'rev-parse', '--verify', head + '^{tree}'], cwd=source, text=True).strip()
    authority = dict(schema='wikidict.prepared-git-source.v1', head=head, tree=tree,
                     inventory=inventory_ref, fingerprint=cfg['source']['fingerprint'])
    if retained is not None:
        require(retained == authority, 'Retained original Git source authority changed')
        # Keep referenced objects available without reopening canonical payloads.
        entries = subprocess.check_output(['git', '--no-replace-objects', 'ls-tree', '-r', '-z', head], cwd=source)
        oids = [row.split(b'\t', 1)[0].split()[2] for row in entries.split(b'\0') if row]
        checked = subprocess.run(['git', '--no-replace-objects', 'cat-file', '--batch-check'], cwd=source,
                                 input=b''.join(oid + b'\n' for oid in oids),
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
        rows = checked.stdout.splitlines()
        require(len(rows) == len(oids) and all(len(row.split()) == 3
                and row.split()[0] == oid and row.split()[1] == b'blob'
                for row, oid in zip(rows, oids)), 'Retained original Git blob is unavailable')
        return authority
    files, modes = inventory['files'], inventory['modes']
    require(isinstance(files, dict) and files and set(files) == set(modes), 'Prepared Git inventory is incomplete')
    entries = {}
    raw = subprocess.check_output(['git', '--no-replace-objects', 'ls-tree', '-r', '-z', head], cwd=source)
    for entry in raw.split(b'\0'):
        if not entry:
            continue
        metadata, name = entry.split(b'\t', 1)
        name = name.decode('utf-8')
        if name.startswith('apps/'):
            continue
        mode, kind, oid = metadata.decode('ascii').split()
        require(mode in ('100644', '100755') and kind == 'blob' and name not in entries,
                'Prepared Git source contains an unsupported entry')
        entries[name] = (mode, oid)
    require(set(entries) == set(files), 'Prepared Git commit differs from the qualified inventory')
    # One stream, bounded chunks: no worktree, archive or copied source payload.
    import build_wiktionaries as builder
    source_digest = hashlib.sha256()
    if cfg.get('python_tooling') is not None:
        selected=selected_python_tooling(cfg)
        source_digest.update(b'wikidict.selected-python-tooling.v1\0'+json.dumps(
            selected.require_unchanged(),sort_keys=True,separators=(',',':')).encode()+b'\0')
    process = subprocess.Popen(['git', '--no-replace-objects', 'cat-file', '--batch'], cwd=source,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        for name in sorted(entries):
            reference = files[name]
            require(isinstance(reference, dict) and set(reference) == {'path', 'bytes', 'sha256'}
                    and type(reference['bytes']) is int and reference['bytes'] >= 0
                    and isinstance(reference['sha256'], str)
                    and re.fullmatch('[0-9a-f]{64}', reference['sha256']) is not None,
                    'Malformed qualified Git source descriptor')
            mode, oid = entries[name]
            require(reference['path'] == str(source / name) and modes[name] == int(mode[-3:], 8),
                    'Prepared Git path or mode differs from the qualified producer')
            process.stdin.write((oid + '\n').encode('ascii'))
            process.stdin.flush()
            header = process.stdout.readline().decode('ascii').strip().split()
            require(len(header) == 3 and header[:2] == [oid, 'blob'] and int(header[2]) == reference['bytes'],
                    'Prepared Git blob size differs from the qualified producer')
            selected_source = (name in builder.PRODUCER_SOURCE_FILES or
                (Path(name).parts[0] in builder.PRODUCER_SOURCE_DIRECTORIES
                 and Path(name).suffix in ('.zig', '.py', '.c', '.h', '.zon')))
            if selected_source:
                source_digest.update(name.encode() + b'\0')
            remaining = reference['bytes']
            digest = hashlib.sha256()
            while remaining:
                chunk = process.stdout.read(min(1024 * 1024, remaining))
                require(bool(chunk), 'Prepared Git blob is truncated')
                digest.update(chunk)
                if selected_source:
                    source_digest.update(chunk)
                remaining -= len(chunk)
            require(process.stdout.read(1) == b'\n' and digest.hexdigest() == reference['sha256'],
                    'Prepared Git bytes differ from the qualified producer')
            if selected_source:
                source_digest.update(b'\0')
        require(source_digest.hexdigest() == cfg['source']['fingerprint'],
                'Qualified fingerprint contains source outside the original Git inventory')
        process.stdin.close()
        require(process.wait(timeout=30) == 0, 'Prepared Git object read failed')
    finally:
        # EOF closes this direct cat-file session. Closing its output also
        # releases a writer after an early malformed-header/byte refusal.
        if not process.stdin.closed:
            process.stdin.close()
        process.stdout.close()
        # A failed bounded join propagates; it is never reported as cleanup.
        process.wait(timeout=30)
    return authority


def prepared_source_observation(cfg, binding):
    """Validate an explicit parent authorization, never infer one from a marker."""
    import build_wiktionaries as builder
    require(isinstance(binding,dict) and set(binding)<= {'start','authorization','finalization'}
            and {'start','authorization'}<=set(binding), 'Invalid prepared source authorization')
    start=builder.prepared_metadata(binding['start'])
    require(start['context']==production_context(cfg) and start['date']==cfg['date']
            and logical_role_argv(start['argv'])==command(cfg,start['edition'],start['workers_requested'],start['memory_limit_bytes'],
                prepared_bytecode_prefix=str(Path(binding['start']['path']).parent/'unwritten-python-cache')),
            'Prepared source attempt invocation differs')
    source,workspace=source_roots(cfg)
    execution_layout(cfg)
    selected=selected_python_tooling(cfg)
    expected_builder=Path(selected.spec['modules']['build_wiktionaries']['path']) if selected is not None else source/'tools/build_wiktionaries.py'
    require(builder.PROJECT==source and Path(builder.__file__).resolve()==expected_builder,
            'Prepared source builder import belongs to another producer')
    launch=builder.prepared_metadata(binding['authorization'])
    original=launch['prepared_source_authorization']['original_source_observation']
    immutable=prepared_git_source_authority(cfg, retained=original['immutable_source'])
    retired=binding.get('finalization') is not None
    generation=builder.prepared_authorized_generation(cfg,start,binding['authorization'],retired=retired)
    if retired:
        final=builder.prepared_metadata(binding['finalization'])
        require(Path(binding['finalization']['path'])==Path(binding['start']['path']).parent/'prepared-finalization.json'
                and final==dict(schema='wikidict.prepared-source-finalization.v1',
                    generation=generation.generation_reference,authorization=binding['authorization'],
                    attempt_start=binding['start'],native_work_complete=True,publication_verified=False,
                    staging_identity=generation.identity,seal_archive=generation.record['seal_archive']),
                'Finalized prepared proof differs from the original authorized generation')
        archive=generation.record['seal_archive']
        require(archive['sha256']==generation.record['seal_sha256'], 'Retained generation seal differs')
        builder.prepared_metadata(archive)
    else:
        generation.require_unchanged()
    require(descriptor(cfg['manifest']['path'])==cfg['manifest'], 'Input manifest changed')
    return dict(qualified_head=cfg['source']['head'],current_head=None,
        producer_inventory=cfg['source']['inventory'],apps_acceptance=False,
        source_mode='parent-authorized-prepared-generation',immutable_source=immutable,
        current_canonical_zig_read_after_preparation=False,
        native_generation_retired=retired,prepared_authorization=binding)


def authorize_prepared_source(cfg,start,start_ref,launch_path,generation_ref,*,process,inherited=None):
    """Run while the tracked child/edition and controller locks remain owned."""
    import build_wiktionaries as builder
    require(cfg.get('prepared_source_custody') is True, 'Prepared source custody was not selected')
    record=builder.prepared_metadata(generation_ref)
    require(record['context']==start['context']==production_context(cfg), 'Prepared context differs')
    launch=read_json(launch_path)
    if inherited is None:
        require(Path(generation_ref['path'])==Path(start_ref['path']).parent/'prepared-generation.json'
                and record.get('prepared_by_start')==start_ref
                and record.get('tracked_process')==launch['identity'],
                'Prepared generation belongs to another tracked attempt')
    # Only this live child in the controller-created exclusive attempt may
    # offer semantic success. Arbitrary generation/dispatch consumers do not
    # transport it. Keep the final whole-source/Git and process checks below.
    if (inherited is None and cfg.get('retained_native_roles') is not None
            and record.get('figure_validation') is not None
            and builder.prepared_metadata(start_ref)==start
            and start.get('prepared_source_control',{}).get('configuration')==cfg
            and {'argv','edition','workers_requested','memory_limit_bytes'}<=set(start)
            and logical_role_argv(start['argv'])==command(cfg,start['edition'],start['workers_requested'],start['memory_limit_bytes'],
                prepared_bytecode_prefix=str(Path(start_ref['path']).parent/'unwritten-python-cache'))
            and getattr(process,'args',None)==start['argv']
            and record.get('source')==cfg['source']
            and record.get('python_tooling')==cfg.get('python_tooling')
            and process.pid==launch['identity']['pid'] and process.poll() is None
            and process_identity(process.pid)==launch['identity'] and process.poll() is None):
        with builder.build_phase(start['edition'],cfg['date'],'prepared_figure_semantic_verdict',
                                 scope='controller',reused=False) as phase:
            phase['reused']=builder.reuse_prepared_figure_verdict(cfg,record['figure_validation'])
    authenticated_roles=None
    if cfg.get('retained_native_roles') is not None:
        binding=record.get('retained_dispatch')
        require(isinstance(binding,dict) and binding.get('selection')==cfg['retained_native_roles'],
                'Prepared retained selection differs from configuration')
        if inherited is None:
            roles=builder.RetainedNativeToolRoles(cfg['retained_native_roles'],
                zig_sha256=record['build_identity']['zig_sha256'])
            authenticated_roles=roles.authenticate_prepared_dispatch(binding,cfg)
    else:
        require(record.get('retained_dispatch') is None, 'Prepared native map was not selected')
    require(record.get('python_tooling')==cfg.get('python_tooling'), 'Prepared import catalog differs')
    generation=builder.PreparedSourceGeneration(record,source=cfg['source'],
        build_identity=record['build_identity'],now_unix=cfg['now_unix'],context=start['context'],
        **({'_authenticated_roles':authenticated_roles} if authenticated_roles is not None else {}))
    if inherited is None:
        original_observation=source_guard(cfg)
        if cfg.get('retained_native_roles') is not None:
            require(original_observation.get('current_head')==cfg['source']['head'],
                    'Prepared retained adoption requires the original qualified HEAD')
    else:
        previous=prepared_source_observation(cfg,inherited)
        require(not previous['native_generation_retired'], 'Retired native generation cannot restart expansion')
        prior_launch=builder.prepared_metadata(inherited['authorization'])
        original_observation=prior_launch['prepared_source_authorization']['original_source_observation']
        require(prior_launch['prepared_source_authorization']['generation']==generation_ref,
                'Own-cap retry selected a different prepared generation')
    # Close changes during the last potentially lengthy full source check.
    # Only this retained parent call has already done the full generation probe.
    # Its roles still revalidate the frozen context, loader resolution and full
    # input stamps on every check; ordinary/child/full-final probes are unchanged.
    recheck={'full_context':False} if authenticated_roles is not None else {}
    generation.require_unchanged(**recheck)
    if inherited is None:
        original_observation['immutable_source']=prepared_git_source_authority(cfg)
        generation.require_unchanged(**recheck)
    require(read_json(launch_path)==launch, 'Tracked launch changed during source authentication')
    require(process.pid==launch['identity']['pid'] and process.poll() is None
            and process_identity(process.pid)==launch['identity'] and process.poll() is None,
            'Tracked CLI exited or changed during prepared source authentication')
    require('prepared_source_authorization' not in launch, 'Attempt already authorized a generation')
    launch['prepared_source_authorization']=dict(schema='wikidict.prepared-source-authorization.v1',
        configuration=cfg,context=start['context'],attempt_start=start,generation=generation_ref,
        decision='parent-verified-original-source',original_source_observation=original_observation)
    write_json(launch_path,launch,replace=True)
    return dict(start=start_ref,authorization=descriptor(launch_path))


def source_guard(cfg, prepared_authorization=None):
    if prepared_authorization is not None:
        require(cfg.get('prepared_source_custody') is True, 'Prepared source custody was not selected')
        return prepared_source_observation(cfg,prepared_authorization)
    source, workspace = source_roots(cfg)
    execution_layout(cfg)
    frozen = source != workspace
    if cfg.get('artifact_root') is not None or frozen:
        validate_pipeline_paths(cfg, workspace)
    if frozen:
        require(descriptor(cfg['compiler']['path']) == cfg['compiler'], 'Pinned compiler changed')
    import build_wiktionaries as builder
    if cfg.get('python_tooling') is not None:
        selected_python_tooling(cfg).require_unchanged()
        require(builder.PROJECT==source,'Selected builder native source differs')
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
        head = None if frozen else subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
        inventory_ref = cfg['source'].get('inventory')
        require(not frozen or inventory_ref is not None, 'Retained producer requires a qualified source inventory')
        if inventory_ref is None:
            dirty = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=source, text=True)
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
                tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=source).decode().split('\0')
                producer_paths = {name for name in tracked if name and not name.startswith('apps/')}
                require(producer_paths == set(files), 'Tracked producer inventory changed')
                untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=source).decode().split('\0')
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
REVIEW_COVERAGE_NAMES = ('page-coverage.json', 'namespace-coverage.json')


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
    from build_wiktionaries import open_fallback_report
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
    with open_fallback_report(path, 'rb') as stream:
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
        # Git head is provenance, not producer-byte identity. Keep the original
        # producer head for all source-derived dispositions below; the review's
        # current head remains independently bound above.
        producer_source = accepted['source']
        require(isinstance(producer_source,dict) and isinstance(producer_source.get('head'),str)
                and bool(producer_source['head']) and dict(producer_source,head=source['head']) == source
                and review.get('complete') == accepted['complete'],
                'Content review completion/source differs')
        require(all(type(accepted[key].get('bytes')) is int and 0 < accepted[key]['bytes'] <= REVIEW_METADATA_LIMIT
                    for key in ('complete', 'complete_snapshot')), 'Completion review metadata exceeds limit')
        complete = read_ref(accepted['complete']); snapshot = read_ref(accepted['complete_snapshot'])
        require(complete == snapshot and all(accepted['complete'][key] == accepted['complete_snapshot'][key]
                for key in ('bytes', 'sha256')) and complete['edition'] == row['edition'] and
                complete['date'] == root.name and complete['build_inputs'] == accepted['build_inputs'] and
                complete['build_inputs']['source'] == source['fingerprint'], 'Accepted completion identity differs')
        reports = accepted['reports']
        import build_wiktionaries as builder
        fallback_name, fallback_decoded = builder.published_fallback_report(complete)
        report_names = (*REVIEW_COVERAGE_NAMES, fallback_name)
        require(set(reports) == set(report_names) and review.get('reports') == reports,
                'Content review report inventory differs')
        files = complete['publication_files']
        for name in report_names:
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
        fallback_path = root / fallback_name
        if fallback_decoded is not None:
            builder.require_decoded_fallback_report(fallback_path, fallback_decoded)
        reasons = _review_fallbacks(fallback_path, fallback_count, fallback_namespaces, source_limitations, source_lua_defects, unsectioned_notices)
        # Reuse the producer's exact bounded coverage/conservation validators.
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
    if 'output' in cfg and 'date' in cfg:
        root = Path(cfg['output'])/edition
        if not (root/cfg['date']/'complete.json').exists():
            require(not any((root/(cfg['date']+'.shards')/name).exists()
                            or (root/(cfg['date']+'.shards')/name).is_symlink() for name in RETIRED_PROVIDER_MARKERS),
                    'Retired provider-copy workspace requires a fresh whole-attempt output; retained captures unchanged')
    options = cfg.get('edition_options', {}).get(edition, {})
    require(isinstance(options, dict) and set(options) <= {'extraction_cache_root', 'staged_input_root', 'auxiliary_snapshots', 'interwiki_snapshot', 'presentation_audit_pages', 'continue_failed_shards'},
            'Unknown edition option')
    argv = []
    if 'continue_failed_shards' in options:
        from build_wiktionaries import validate_presentation_audit_pages
        validate_presentation_audit_pages(options.get('presentation_audit_pages'), options['continue_failed_shards'])
        if options['continue_failed_shards']:
            argv += ['--continue-failed-shards']
    if 'presentation_audit_pages' in options:
        from build_wiktionaries import validate_presentation_audit_pages
        pages = options['presentation_audit_pages']
        require(pages is not None, 'Presentation audit pages must be explicitly positive')
        validate_presentation_audit_pages(pages)
        argv += ['--presentation-audit-pages', str(pages)]
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


def command(cfg, edition, workers, memory_limit_bytes=MEMORY, *, prepared_bytecode_prefix=None):
    require(type(memory_limit_bytes) is int and memory_limit_bytes == MEMORY,
            'Production memory budget must be 8 GiB')
    source, _ = source_roots(cfg)
    selected=selected_python_tooling(cfg)
    script=Path(selected.spec['modules']['build_wiktionaries']['path']) if selected is not None else source/'tools/build_wiktionaries.py'
    argv = [sys.executable, '-B', str(script),
        '--resource-mode', 'watchdog', '--compress-shards', '--watchdog-address-space', 'unlimited',
        '--watchdog-memory-limit-mib', str(memory_limit_bytes // 1024**2),
        '--cpu-admission', 'affinity', '--threads', str(workers), '--jobs', '1',
        '--expansion-workers', str(workers), '--build-timeout-seconds', str(cfg['build_timeout_seconds']),
        '--now-unix', str(cfg['now_unix']), '--expansion-timeout-ms', str(cfg['expansion_timeout_ms']),
        '--downloads', cfg['downloads'], '--output', cfg['output'], '--raw-shard-root', cfg['raw_shard_root'],
        '--zig', cfg['compiler']['path'], '--wikis', edition]
    if selected is not None:
        prefix=prepared_bytecode_prefix or str(Path(cfg['state_directory'])/'unwritten-python-cache')
        require(Path(prefix).is_absolute() and not os.path.lexists(prefix),'Selected Python bytecode prefix is not absent')
        argv[1:2]=['-I','-S','-B','-X','pycache_prefix='+prefix]
        argv += ['--python-tooling-json',json.dumps(selected.spec,sort_keys=True,separators=(',',':'))]
    metadata_network = cfg.get('metadata_network', 'offline')
    require(metadata_network in ('offline', 'allow'), 'Invalid metadata network policy')
    if metadata_network != 'offline':
        argv += ['--metadata-network', metadata_network]
    reuse_batches = cfg.get('figure_reuse_batches', [])
    require(isinstance(reuse_batches, list) and all(isinstance(path, str) and Path(path).is_absolute() for path in reuse_batches)
            and len(set(reuse_batches)) == len(reuse_batches), 'Invalid Figure reuse batch paths')
    for path in reuse_batches:
        argv += ['--figure-reuse-batch', path]
    if 'retained_native_roles' in cfg:
        from build_wiktionaries import RETAINED_NATIVE_ROLE_NAMES
        roles=cfg['retained_native_roles']
        require(isinstance(roles,dict) and set(roles)==set(RETAINED_NATIVE_ROLE_NAMES)
                and all(isinstance(row,dict) for row in roles.values()),
                'Invalid retained native role selection')
        if cfg.get('prepared_source_custody') is True:
            require(len({'initial_sealed_generation','closed_whole_execution'} & set(roles.get('dict-bundle-build',{})))==1,
                    'Prepared retained custody requires explicit initial sealed or closed-whole selection')
        argv += ['--retained-native-roles-json',json.dumps(roles,sort_keys=True,separators=(',',':'))]
    if cfg.get('prepared_source_custody') is True:
        require(isinstance(prepared_bytecode_prefix, str) and Path(prepared_bytecode_prefix).is_absolute(),
                'Prepared command requires its owned bytecode prefix')
        if selected is not None:
            position=argv.index(str(script));argv[position:position]=['-X','wikidict_prepared_source=1']
        else:
            argv[1:2]=['-I','-S','-B','-X','wikidict_prepared_source=1',
                       '-X','pycache_prefix='+prepared_bytecode_prefix]
    if cfg.get('artifact_root') is not None:
        argv += ['--artifact-root-spec', json.dumps(cfg['artifact_root'], sort_keys=True, separators=(',', ':'))]
    if cfg.get('workspace_root') is not None:
        argv += ['--workspace-root-spec', json.dumps(cfg['workspace_root'], sort_keys=True, separators=(',', ':'))]
    execution = execution_layout(cfg)
    if execution is not None:
        require(edition == execution['edition'], 'Command edition differs from execution manifest')
        argv += ['--execution-root-spec', json.dumps(cfg['execution_root'], sort_keys=True, separators=(',', ':')),
                 '--input-manifest', cfg['manifest']['path'], '--input-manifest-sha256', cfg['manifest']['sha256']]
    if selected is not None and execution is not None:
        argv += ['--exact-snapshot-selection']
    argv += edition_cli_options(cfg, edition)
    return argv


def compact_role_argv(argv, folder):
    """Keep large role provenance out of the OS argument vector."""
    if '--retained-native-roles-json' not in argv:
        return argv
    index = argv.index('--retained-native-roles-json')
    require(argv.count('--retained-native-roles-json') == 1 and index + 1 < len(argv)
            and '--retained-native-roles-ref' not in argv, 'Invalid retained native role arguments')
    value = argv[index + 1]
    # Linux limits each argument to 32 pages including its terminating NUL.
    if len(os.fsencode(value)) < 32 * os.sysconf('SC_PAGE_SIZE'):
        return argv
    import stat
    folder = Path(folder)
    require(folder.is_absolute() and folder.resolve() == folder,
            'Unsafe retained native role directory')
    name = 'retained-native-roles.json'
    temporary = name + '.' + uuid.uuid4().hex + '.part'
    created = False
    raw = value.encode('utf-8')
    require(0 < len(raw) <= 64 * 1024**2, 'Retained native role metadata exceeds bound')
    folder.mkdir(mode=0o700, exist_ok=True)
    directory = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        owned = os.fstat(directory)
        require(owned.st_uid == os.geteuid() and not owned.st_mode & 0o022,
                'Unsafe retained native role directory ownership')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=directory)
        created = True
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            # Publish complete bytes once; a retry or concurrent constructor
            # must authenticate the existing file instead of replacing it.
            os.link(temporary, name, src_dir_fd=directory, dst_dir_fd=directory,
                    follow_symlinks=False)
        except FileExistsError:
            pass
        os.unlink(temporary, dir_fd=directory)
        created = False
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            require(stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                    and before.st_nlink == 1 and not before.st_mode & 0o022
                    and before.st_size == len(raw), 'Unsafe or conflicting retained native role file')
            actual = stream.read(len(raw) + 1)
            after = os.fstat(stream.fileno())
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_uid', 'st_gid',
                  'st_size', 'st_mtime_ns', 'st_ctime_ns')
        linked = os.stat(name, dir_fd=directory, follow_symlinks=False)
        require(actual == raw and all(getattr(before, key) == getattr(after, key)
                == getattr(linked, key) for key in fields),
                'Retained native role file changed or conflicts with selected provenance')
        current = folder.stat()
        require((current.st_dev, current.st_ino, current.st_mode, current.st_uid, current.st_gid)
                == (owned.st_dev, owned.st_ino, owned.st_mode, owned.st_uid, owned.st_gid)
                and folder.resolve() == folder, 'Retained native role directory changed')
        reference = dict(path=str(folder / name), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
    finally:
        if created:
            os.unlink(temporary, dir_fd=directory)
        os.close(directory)
    return [*argv[:index], '--retained-native-roles-ref', json.dumps(reference), *argv[index + 2:]]


def logical_role_argv(argv):
    """Authenticate the recorded file and recover the usual command for comparison."""
    if '--retained-native-roles-ref' not in argv:
        return argv
    index = argv.index('--retained-native-roles-ref')
    require(argv.count('--retained-native-roles-ref') == 1 and index + 1 < len(argv)
            and '--retained-native-roles-json' not in argv, 'Invalid retained native role arguments')
    from build_wiktionaries import prepared_metadata
    roles = prepared_metadata(json.loads(argv[index + 1]))
    value = json.dumps(roles, sort_keys=True, separators=(',', ':'))
    return [*argv[:index], '--retained-native-roles-json', value, *argv[index + 2:]]


def ordinary_command_record(*, argv, cwd, environment, output, roles, source_refs, scope):
    """Build the direct-owner record from selected inputs, without donor state."""
    output = Path(output)
    require(output.is_absolute() and output.resolve() == output,
            'Ordinary command output must be canonical and absolute')
    require(isinstance(argv, list) and all(isinstance(value, str) for value in argv)
            and argv.count('--output') == 1 and argv.count('--wikis') == 1,
            'Ordinary command requires one selected output and edition')
    require(argv.index('--output') + 1 < len(argv) and argv.index('--wikis') + 1 < len(argv)
            and argv[argv.index('--output') + 1] == str(output / 'output'),
            'Ordinary command output differs from its owned root')
    require(isinstance(environment, dict) and all(isinstance(k, str) and isinstance(v, str)
            for k, v in environment.items()), 'Invalid ordinary command environment')
    require(isinstance(roles, dict) and set(roles) == {
            'dict-blob-build', 'dict-blob-merge', 'dict-blob-verify', 'dict-bundle-build'}
            and all(isinstance(row, dict) for row in roles.values()),
            'Ordinary command requires its selected native roles')
    logical = logical_role_argv(argv)
    require(logical.count('--retained-native-roles-json') == 1
            and logical.index('--retained-native-roles-json') + 1 < len(logical),
            'Ordinary command requires its selected role arguments')
    require(json.loads(logical[logical.index('--retained-native-roles-json') + 1]) == roles,
            'Ordinary command role arguments differ from selected provenance')
    require(isinstance(source_refs, list) and isinstance(scope, str) and bool(scope),
            'Ordinary command requires source custody and scope')
    import copy
    origins = {name: {key: copy.deepcopy(row[key]) for key in (
        'actual_emission_result', 'qualification_closure', 'compilation_recipe', 'source')
        if key in row} for name, row in roles.items()}
    writer = roles['dict-blob-build']
    require(isinstance(writer.get('qualification_closure'), dict),
            'Ordinary command Writer lacks its actual closure')
    env = dict(environment)
    env['TMPDIR'] = str(output / 'runtime01' / 'tmp')
    physical = compact_role_argv(argv, output)
    refs = copy.deepcopy(source_refs)
    if '--retained-native-roles-ref' in physical:
        reference = json.loads(physical[physical.index('--retained-native-roles-ref') + 1])
        require(not any(row.get('path') == reference['path'] and row != reference for row in refs),
                'Retained native role file conflicts with source custody')
        if reference not in refs:
            refs.append(reference)
    return dict(argv=list(physical), cwd=str(cwd), env=env,
                qualification_root=str(output / 'runtime01'), source_refs=refs,
                independent_role_origins=origins,
                current_production_closure=copy.deepcopy(writer['qualification_closure']), scope=scope)



CONTEXT_KEYS = ('source', 'compiler', 'manifest', 'downloads', 'output', 'raw_shard_root',
                'date', 'now_unix', 'expansion_timeout_ms')

def production_context(cfg):
    values = {key: cfg[key] for key in CONTEXT_KEYS}
    if cfg.get('artifact_root') is not None:
        values['artifact_root'] = cfg['artifact_root']
    for key in ('campaign', 'edition_options', 'llvm_workers', 'workspace_root', 'execution_root', 'superseded_generated', 'metadata_network', 'figure_reuse_batches', 'retained_native_roles', 'python_tooling'):
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
    raw_identity = json.loads(snapshot.read_bytes()).get('build_inputs')
    if isinstance(raw_identity, dict) and 'native_tool_roles_details' in raw_identity:
        builder.copy_publication_role_details(root, folder, raw_identity)
    require(type(complete['input_pages']) is int and complete['input_pages'] >= 0, 'Invalid accepted page count')
    fallback_name, _ = builder.published_fallback_report(complete)
    report_names = (*REVIEW_COVERAGE_NAMES, fallback_name)
    reports = {name: dict(path=str(root / name), bytes=value['size'], sha256=value['sha256'])
               for name, value in complete['publication_files'].items()
               if name in report_names}
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


DERIVED_SHARED_ASSETS = frozenset(('page-index.tsv', 'page-title-index.bin', 'dump-streams.tsv',
                                  'template-source.bin', 'template-source.idx'))


def _derived_identity(path):
    s = path.lstat()
    return (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_gid, s.st_nlink,
            s.st_size, s.st_blocks, s.st_mtime_ns, s.st_ctime_ns)


def protected_source_identity(row):
    """Match a physical pin; protection-root timestamps are not content proof.

    The explicit directory role protects its entire subtree, including unknown
    descendants. It never replaces authenticated leaf/manifest validation.
    Legacy rows and regular files retain the complete ten-field comparison.
    """
    import stat
    if not isinstance(row, dict) or set(row) not in ({'path','identity'}, {'path','identity','purpose'}):
        return None
    purpose = row.get('purpose')
    if 'purpose' in row and purpose != 'protect-subtree':
        return None
    expected = row['identity']
    if not isinstance(row['path'], str) or not isinstance(expected, list) or len(expected) != 10:
        return None
    path = Path(row['path'])
    if (not path.is_absolute() or path.anchor != '/' or str(path) != row['path']
            or str(path) != os.path.normpath(row['path'])
            or any(node.is_symlink() for node in (path, *path.parents))):
        return None
    actual = _derived_identity(path)
    if purpose == 'protect-subtree':
        matches = stat.S_ISDIR(actual[2]) and tuple(expected[:8]) == actual[:8]
    else:
        matches = (stat.S_ISREG(actual[2]) or stat.S_ISDIR(actual[2])) and tuple(expected) == actual
    return (path, actual) if matches else None


def _reconcile_derived_sources(reference, locks):
    """The ordinary binder must publish committed selections under this lock.

    Immutable old configs alone are not a queue authority. Legacy packets have
    no such contract and defer; progress and unarmed planning are not selections.
    """
    import stat
    roles = read_ref(reference); pins = roles.get('derived_source_pins')
    require(isinstance(pins, dict) and set(pins) == {
        'selection_protocol', 'lock', 'selection_checkpoint', 'authorities', 'paths', 'unresolved'},
        'Fresh committed source-selection authority is unavailable')
    require(pins['selection_protocol'] == 'controller-lock-v1' and pins['unresolved'] == []
            and isinstance(pins['authorities'], list) and pins['authorities']
            and isinstance(pins['paths'], list) and pins['paths'], 'Unresolved physical-source selection')
    lock = locks[0]; lock.check(); held = os.fstat(lock.fd)
    require(lock.own and pins['lock'] == dict(path=str(lock.path), dev=held.st_dev, ino=held.st_ino),
            'Source-selection coordinator lock differs')
    # This fd already holds the lock across main/execute/post-result cleanup.
    fcntl.flock(lock.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    checkpoint = read_ref(pins['selection_checkpoint'])
    require(checkpoint.get('committed_source_selection') ==
            {key: pins[key] for key in pins if key != 'selection_checkpoint'},
            'Committed source selection differs from its cleanup pins')
    for authority in pins['authorities']: read_ref(authority)
    paths, identities = [], set()
    for row in pins['paths']:
        matched = protected_source_identity(row)
        require(matched is not None, 'Protected physical source changed')
        path, identity = matched
        paths.append(path); identities.add(identity[:2])
    return dict(paths=paths, identities=identities)


def normalize_registry_rows(value, *, edition, date):
    """Validate earned singleton/list registry metadata, then select one row.

    Callers authenticate and compare the original representation before this
    projection; the returned list preserves every selected field unchanged.
    """
    import re
    require(isinstance(edition,str) and edition.endswith('wiktionary')
            and isinstance(date,str) and re.fullmatch('[0-9]{8}',date), 'Invalid registry selection context')
    require(isinstance(value,dict) or isinstance(value,list), 'Unsupported registry row representation')
    rows = [value] if isinstance(value,dict) else value
    require(bool(rows), 'Empty registry inventory')
    seen=set(); selected=[]
    for row in rows:
        require(isinstance(row,dict) and set(row) == {'content_language','date','name','sha256','size','wiki'},
                'Invalid registry row fields')
        require(isinstance(row['wiki'],str) and row['wiki'].endswith('wiktionary')
                and not any(c.isspace() or c in '/\\' for c in row['wiki'])
                and isinstance(row['content_language'],str) and re.fullmatch('[a-z][a-z0-9-]*',row['content_language'])
                and row['date'] == date and row['name'] == 'language-registry.tsv'
                and type(row['size']) is int and row['size'] > 0
                and isinstance(row['sha256'],str) and re.fullmatch('[0-9a-f]{64}',row['sha256']),
                'Invalid registry row identity')
        key=(row['wiki'],row['date'])
        require(key not in seen, 'Duplicate registry identity'); seen.add(key)
        if row['wiki'] == edition: selected.append(dict(row))
    require(len(selected) == 1, 'Registry selection is not unique')
    return selected




def require_ordinary_input_roles(cfg):
    """Cheap producer-contract preflight; full normal tuple validation is separate."""
    import build_wiktionaries as builder
    tooling = cfg.get('python_tooling')
    if tooling is not None:
        require(Path(builder.__file__) == Path(tooling['modules']['build_wiktionaries']['path']),
                'Required-role check must use the selected producer')
    editions = cfg.get('edition_options')
    require(isinstance(editions, dict) and bool(editions), 'Ordinary input selection has no editions')
    for options in editions.values():
        require(isinstance(options, dict) and isinstance(options.get('auxiliary_snapshots', {}), dict),
                'Invalid ordinary provider selection')
        staged = options.get('staged_input_root')
        if staged is not None:
            require(isinstance(staged, dict) and set(staged) == {'path', 'device', 'inode', 'uid', 'mode', 'completion'},
                    'Invalid borrowed staged input record')
            require(isinstance(staged['path'], str) and all(type(staged[k]) is int for k in ('device', 'inode', 'uid', 'mode')),
                    'Invalid borrowed staged input identity fields')
            root = Path(staged['path'])
            require(root.is_absolute() and root.resolve() == root and not root.is_symlink() and root.is_dir(),
                    'Selected staged input root is not a direct existing directory')
            for name in ('pages.xml.zst', 'pages-index.txt.bz2', '.complete.json'):
                path = root / name
                require(not path.is_symlink() and path.is_file(),
                        'Selected staged input lacks regular file: ' + name)
        snapshots = options.get('auxiliary_snapshots', {})
        builder.require_figure_inputs(snapshots)
        for name in set(builder.FIGURE_SNAPSHOT_FILES) & set(snapshots):
            reference = snapshots[name]
            require(isinstance(reference, dict) and set(reference) == {'path', 'bytes', 'sha256'}
                    and isinstance(reference['path'], str) and Path(reference['path']).is_absolute()
                    and type(reference['bytes']) is int and reference['bytes'] >= 0
                    and isinstance(reference['sha256'], str) and len(reference['sha256']) == 64
                    and all(c in '0123456789abcdef' for c in reference['sha256']),
                    'Invalid required Figure input descriptor: ' + name)


def ordinary_edition_input_selection(cfg, official_manifest, selected_manifest, registry_rows, *, providers, added_rows=()):
    """Select authenticated metadata for the existing normal resolver/arm path.

    This creates no cache, arming or historical input-reuse authority. Callers
    retain their bound references, optional keeper checks and ownership locks.
    """
    import copy
    require_ordinary_input_roles(cfg)
    edition = execution_layout(cfg)['edition']
    date = cfg['date']
    require(isinstance(selected_manifest, dict) and selected_manifest.get('requested_editions') == [edition]
            and selected_manifest.get('failures') == [], 'Selected manifest belongs to another edition')
    require(isinstance(official_manifest, dict) and isinstance(official_manifest.get('files'), list),
            'Official input inventory missing')
    original_rows = [row for row in official_manifest['files'] if row.get('wiki') == edition and row.get('date') == date]
    require(original_rows and isinstance(added_rows, (list, tuple)), 'Selected official inputs missing')
    rows = original_rows + list(added_rows)
    require(all(isinstance(row, dict) and row.get('wiki') == edition and row.get('date') == date
                and isinstance(row.get('name'), str) and row['name']
                and Path(row['name']).name == row['name']
                and type(row.get('size')) is int and row['size'] > 0
                and isinstance(row.get('sha1'), str) and len(row['sha1']) == 40 for row in rows),
            'Official input row differs from selected edition/date')
    require(len({row['name'] for row in rows}) == len(rows), 'Duplicate original or added official input')
    require(isinstance(selected_manifest.get('files'), list)
            and sorted(selected_manifest['files'], key=lambda row: row['name']) == sorted(rows, key=lambda row: row['name']),
            'Selected manifest differs from exact original and added inputs')
    registry = normalize_registry_rows(registry_rows, edition=edition, date=date)
    selected_registry = selected_manifest.get('language_registries')
    if 'reviewed_alias_derivation' in selected_manifest:
        from download_wiktionaries import derived_registry_paths
        derived_registry_paths(selected_manifest, Path(cfg['downloads']))
        # The normal verifier authenticates the whole manifest and lineage;
        # compare its selected registry identity without discarding that authority.
        selected_registry = [{key: row[key] for key in registry[0]}
                             for row in selected_manifest['language_registries']]
    require(selected_registry == registry, 'Selected registry differs from its authority')
    roots = official_manifest.get('auxiliary_capture_roots', {})
    require(isinstance(roots, dict) and edition in roots
            and selected_manifest.get('auxiliary_capture_roots') == {edition: roots[edition]},
            'Selected auxiliary capture root differs from original inventory')
    options = cfg.get('edition_options', {}).get(edition)
    require(isinstance(options, dict) and isinstance(providers, dict)
            and options.get('auxiliary_snapshots', {}) == providers,
            'Selected auxiliary provider descriptors differ')
    for reference in providers.values():
        require(isinstance(reference, dict) and set(reference) == {'path', 'bytes', 'sha256'}
                and isinstance(reference['path'], str) and Path(reference['path']).is_absolute()
                and type(reference['bytes']) is int and reference['bytes'] >= 0
                and isinstance(reference['sha256'], str) and len(reference['sha256']) == 64,
                'Invalid selected auxiliary provider descriptor')
    provider_descriptors = dict(providers)
    if options.get('interwiki_snapshot') is not None:
        require('interwiki_snapshot' not in providers, 'Interwiki input aliases an auxiliary role')
        reference = options['interwiki_snapshot']
        require(isinstance(reference, dict) and set(reference) == {'path', 'bytes', 'sha256'}
                and isinstance(reference['path'], str) and Path(reference['path']).is_absolute()
                and type(reference['bytes']) is int and reference['bytes'] >= 0
                and isinstance(reference['sha256'], str) and len(reference['sha256']) == 64,
                'Invalid selected interwiki descriptor')
        provider_descriptors['interwiki_snapshot'] = reference
    return copy.deepcopy(dict(edition=edition, date=date, key=(edition, date), manifest=selected_manifest,
        rows=selected_manifest['files'], original_rows=original_rows, added_rows=list(added_rows),
        registry_rows=registry, overrides={name: Path(value['path']) for name,value in providers.items()},
        provider_descriptors=provider_descriptors))


def commit_source_selection_checkpoint(update, selection_fd, *, lock, authenticate):
    """Commit the existing coordinator checkpoint under its authenticated lock."""
    import stat
    assert set(update) == {'protocol', 'before', 'replacement', 'after'}
    assert update['protocol'] == 'controller-lock-v1'
    lock_path = Path(lock['path'])
    observed = os.fstat(selection_fd)
    assert not lock_path.is_symlink()
    assert (observed.st_dev, observed.st_ino) == (lock['device'], lock['inode'])
    assert (lock_path.stat().st_dev, lock_path.stat().st_ino) == (observed.st_dev, observed.st_ino)
    fcntl.flock(selection_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    destination = Path(update['before']['path'])
    assert update['after']['path'] == str(destination)
    assert update['replacement']['path'] != str(destination)
    assert not any(node.is_symlink() for node in (destination, *destination.parents))
    existing = destination.stat()
    assert stat.S_ISREG(existing.st_mode) and existing.st_uid == os.geteuid() and existing.st_nlink == 1
    authenticate(update['before'], metadata=True)
    replacement = authenticate(update['replacement'], metadata=True)
    selection = replacement['committed_source_selection']
    assert selection['selection_protocol'] == 'controller-lock-v1'
    assert selection['lock'] == dict(path=lock['path'], dev=lock['device'], ino=lock['inode'])
    assert selection['unresolved'] == []
    assert selection['authorities'] and selection['paths']
    payload = Path(update['replacement']['path']).read_bytes()
    assert len(payload) == update['replacement']['bytes']
    assert hashlib.sha256(payload).hexdigest() == update['replacement']['sha256']
    assert update['after'] == dict(path=str(destination), bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())
    for reference in selection['authorities']:
        authenticate(reference)
    for item in selection['paths']:
        assert protected_source_identity(item) is not None, 'Protected physical source changed'
    pending = destination.with_name(destination.name + '.selection.pending')
    created = False
    try:
        with pending.open('xb') as output:
            created = True
            os.fchmod(output.fileno(), stat.S_IMODE(existing.st_mode))
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        authenticate(update['before'], metadata=True)
        assert (destination.stat().st_dev, destination.stat().st_ino) == (existing.st_dev, existing.st_ino)
        os.replace(pending, destination)
        created = False
        parent_fd = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    finally:
        if created:
            pending.unlink()
    authenticate(update['after'], metadata=True)
    return dict(selection_protocol='controller-lock-v1', selection_checkpoint=update['after'],
                lock=selection['lock'], prior_checkpoint=update['before'])


RETIRED_PROVIDER_MARKERS = ('.retired-duplicate-provider-payloads01.json',
                            '.retired-duplicate-wikibase-payloads01.json')


PROVIDER_SNAPSHOT_ROLES = ('category-tree', 'category-stats', 'wikibase-entities')
PROVIDER_COPY_MAX_RECORDS = 2 + len(PROVIDER_SNAPSHOT_ROLES)


def _provider_retirement_plan(record, cfg, edition, options):
    """Read existing capture inventories; do not replay a provider or recapture.

    The original selected role and byte-identical retained metadata authorize
    only explicitly released duplicate payloads. Snapshot/receipt/request files
    remain at their original paths and are never represented as regenerated.
    """
    import re
    primary, keeper = record['manifest'], record['keeper']
    require(primary['bytes'] == keeper['bytes'] and primary['sha256'] == keeper['sha256'],
            'Provider manifests are not retained byte-for-byte')
    old_root, keeper_root = Path(primary['path']).parent, Path(keeper['path']).parent
    old = read_ref(primary); retained = read_ref(keeper)
    require(isinstance(old,dict) and isinstance(retained,dict) and isinstance(options,dict)
            and old == retained and old.get('wiki') == edition and old.get('date') == cfg['date'],
            'Provider capture context differs')
    metadata = [primary, keeper]; preserved = []
    def pair(name, sha=None, size=None):
        require(Path(name).name == name and name not in ('.','..'), 'Escaped provider metadata')
        refs = [descriptor(root/name) for root in (old_root,keeper_root)]
        require(refs[0]['bytes'] == refs[1]['bytes'] and refs[0]['sha256'] == refs[1]['sha256']
                and (sha is None or refs[0]['sha256'] == sha) and (size is None or refs[0]['bytes'] == size),
                'Provider metadata has no exact retained copy')
        metadata.extend(refs); return read_ref(refs[0])
    def snapshot(role, marker):
        selected = options.get(role)
        require(isinstance(selected,dict) and selected['path'] == str(keeper_root/(role+'.tsv'))
                and selected['sha256'] == marker['output_sha256'] and selected['bytes'] == marker['output_bytes'],
                'Provider keeper differs from the original selected role')
        for root in (old_root,keeper_root):
            path=root/(role+'.tsv')
            require(path.is_file() and not path.is_symlink() and path.stat().st_size == selected['bytes'],
                    'Original provider snapshot is unavailable')
            preserved.append(path)
    group = record['asset_groups']
    if group == ['provider-snapshot']:
        role = Path(primary['path']).name.removesuffix('.manifest.json')
        require(role in PROVIDER_SNAPSHOT_ROLES
                and Path(primary['path']).name == role + '.manifest.json',
                'Unknown disposable provider snapshot role')
        if role == 'category-tree':
            require(isinstance(old.get('sources'), dict)
                    and set(old['sources']) == {'page', 'linktarget', 'categorylinks'}
                    and isinstance(old.get('dump_siteinfo_sha256'), str),
                    'Unknown category tree snapshot provenance')
        elif role == 'category-stats':
            require(old.get('output') == 'category-stats.tsv'
                    and old.get('columns') == ['cat_title', 'cat_pages', 'cat_subcats', 'cat_files']
                    and isinstance(old.get('source'), str) and old['source'].endswith('-category.sql.gz'),
                    'Unknown category statistics snapshot provenance')
        else:
            require(old.get('schema') == 'wikidict-wikibase-capture-v1'
                    and old.get('version') == 1 and old.get('name') == role
                    and isinstance(old.get('requests'), list) and isinstance(old.get('artifacts'), dict),
                    'Unknown Wikibase snapshot provenance')
        selected = options.get(role)
        require(isinstance(selected, dict)
                and selected.get('path') == str(keeper_root / (role + '.tsv'))
                and type(old.get('output_bytes')) is int and old['output_bytes'] >= 0
                and selected.get('bytes') == old['output_bytes']
                and selected.get('sha256') == old.get('output_sha256'),
                'Provider snapshot keeper differs from original selected role')
        # Only this explicit duplicate TSV is disposable. Every manifest/raw
        # capture/source receipt remains at its original path for failure replay.
        allowed = {role + '.tsv'}
        inventory = {role + '.tsv': [old['output_bytes'], old['output_sha256']]}
    elif group == ['file-metadata-captures']:
        require(Path(primary['path']).name == 'file-metadata.manifest.json'
                and old.get('schema') in ('wikidict.file-metadata-union.v1','wikidict.file-metadata-union.v2'), 'Unknown file-metadata capture')
        reference=old['evidence']
        require(reference['path'] == 'file-metadata.evidence.json', 'Unknown file-metadata evidence path')
        evidence=pair(reference['path'],reference['sha256'],reference['size'])
        complete=pair('file-metadata.complete.json')
        require(complete == dict(schema=old['schema'],manifest_sha256=primary['sha256']), 'File-metadata completion differs')
        require(isinstance(evidence,dict) and isinstance(evidence.get('captures'),list)
                and isinstance(evidence.get('artifacts'),dict), 'Unknown file-metadata evidence')
        if old['schema'] == 'wikidict.file-metadata-union.v2':
            require(old.get('header_version') == 2 and set(evidence) == {'captures','artifacts','base_capture'}
                    and type(evidence['base_capture']) is int and evidence['base_capture'] == 0
                    and 2 <= len(evidence['captures']) <= 160, 'Invalid retained union base inventory')
            for number,row in enumerate(evidence['captures']):
                require(isinstance(row,dict) and set(row) == {'path','manifest_sha256','rows'}
                        and row['path'] == 'file-metadata.capture-%04d.tar' % number
                        and type(row['rows']) is int and 0 < row['rows'] <= (250000 if number == 0 else 10000)
                        and isinstance(row['manifest_sha256'],str)
                        and re.fullmatch('[0-9a-f]{64}',row['manifest_sha256']), 'Invalid retained union base child')
        allowed={row['path'] for row in evidence['captures']}
        require(all(re.fullmatch(r'file-metadata\.capture-[0-9]+\.tar',name) and name in evidence['artifacts']
                    for name in allowed), 'Unknown file-metadata archive inventory')
        inventory={name:[row['size'],row['sha256']] for name,row in evidence['artifacts'].items() if name in allowed}
        snapshot('file-metadata',old)
    elif group == ['wikibase-responses']:
        require(Path(primary['path']).name == 'wikibase-entities.manifest.json'
                and old.get('schema') == 'wikidict-wikibase-capture-v1' and old.get('version') == 1
                and old.get('name') == 'wikibase-entities', 'Unknown Wikibase capture')
        terms=pair('wikibase-entity-terms.manifest.json')
        require(isinstance(terms,dict) and isinstance(old.get('artifacts'),dict) and isinstance(old.get('requests'),list)
                and terms.get('schema') == old['schema'] and terms.get('version') == 1
                and terms.get('name') == 'wikibase-entity-terms' and terms.get('wiki') == edition
                and terms.get('date') == cfg['date'] and terms['requests'] == old['requests']
                and terms['artifacts'] == old['artifacts'], 'Wikibase paired capture differs')
        pair('wikibase-namespace-capture.complete.json',old['artifacts']['wikibase-namespace-capture.complete.json'])
        allowed={row['response'] for row in old['requests']}
        require(len(allowed) == len(old['requests']) and all(re.fullmatch(r'wikibase-request-[0-9]+\.raw\.json',name)
                and name in old['artifacts'] for name in allowed), 'Unknown Wikibase response inventory')
        for row in old['requests']:
            require(re.fullmatch(r'wikibase-request-[0-9]+\.request\.json',row['request']), 'Unknown Wikibase request metadata')
            pair(row['request'],old['artifacts'][row['request']])
        inventory={name:[None,old['artifacts'][name]] for name in allowed}
        snapshot('wikibase-entities',old); snapshot('wikibase-entity-terms',terms)
    else: raise ValueError('Unknown disposable provider payload family')
    names=record['payload_names']
    require(isinstance(names,list) and names == sorted(set(names)) and names and set(names) <= allowed,
            'Provider payload selection is not in the capture inventory')
    present=[]; absent=[]
    for name in names:
        if not os.path.lexists(old_root/name):
            absent.append(name);continue
        row=inventory[name]
        require(isinstance(row[1],str) and re.fullmatch('[0-9a-f]{64}',row[1]), 'Invalid provider payload digest')
        sizes=[(root/name).lstat().st_size for root in (old_root,keeper_root)]
        require(sizes[0] == sizes[1] and (row[0] is None or row[0] == sizes[0]), 'Provider payload size differs')
        row[0]=sizes[0]
        present.append(name)
    return inventory,present,metadata,preserved,absent


def _retire_derived_assets(records, *, roles_reference, cfg, folder, locks, protected,
                           reconcile_sources, preserved_inputs=(), provider_copies=False,
                           provider_root=None, provider_options=None, provider_edition=None):
    """Manifest-only selection, closed consumer release, and exact alias groups.

    Never walk/remove a tree: distinct provenance and unknown siblings survive.
    The keeper proves retained bytes, not a new source or semantic acceptance.
    """
    import re, stat
    from native_qualification import _retention_path_chunks, _retention_locks_clear, _retention_stamp
    from build_artifact_root import execution_mounts, execution_mount_regions
    result = dict(status='provider-copies-retired' if provider_copies else 'derived-assets-retired', removed_names=0, freed_inodes=0,
                  freed_logical_inode_bytes=0, freed_allocated_inode_bytes=0,
                  exclusive_gain_bytes=None, generations=[])
    input_ids = {path:_derived_identity(path) for path in preserved_inputs}
    snapshot_input_ids = {}
    def check_inputs():
        require(all(_derived_identity(path) == value
                    for pins in (input_ids, snapshot_input_ids) for path,value in pins.items()),
                'Preserved old staged input changed')
    journal = folder / 'superseded-derived-assets.jsonl'
    def append(value):
        with journal.open('a') as stream:
            stream.write(json.dumps(value, sort_keys=True) + '\n'); stream.flush(); os.fsync(stream.fileno())
    require(type(provider_copies) is bool, 'Invalid provider-copy mode')
    require(isinstance(records, list) and 0 < len(records) <= (PROVIDER_COPY_MAX_RECORDS if provider_copies else 1), 'Invalid derived-generation selection')
    require(callable(reconcile_sources), 'Fresh committed source reconciliation is required')
    environment = dict(os.environ); mounts = execution_mounts()
    deadline = time.monotonic() + cfg['build_timeout_seconds']
    require(all(isinstance(record, dict) for record in records), 'Invalid derived-asset record')
    # Raw capture plans consume the copied TSVs. Finish those dependencies
    # before an explicitly released snapshot, regardless of packet order.
    ordered_records = (sorted(records, key=lambda row: row.get('asset_groups') == ['provider-snapshot'])
                       if provider_copies else records)
    for record in ordered_records:
        require(isinstance(record, dict) and set(record) == ({'manifest', 'keeper', 'aliases', 'asset_groups', 'payload_names'} if provider_copies
                    else {'manifest', 'keeper', 'aliases', 'asset_groups'}),
                'Invalid derived-asset fields')
        metadata_refs = [record['manifest'],record['keeper']]
        if provider_copies:
            before,names,metadata_refs,snapshots,absent = _provider_retirement_plan(record,cfg,provider_edition,provider_options)
            if record['asset_groups'] == ['provider-snapshot']:
                old_root = Path(record['manifest']['path']).parent
                require(old_root == provider_root and Path(record['keeper']['path']).parent != old_root,
                        'Released snapshot is not a separate closed copy')
                for name in names:
                    path = old_root / name
                    if path in snapshot_input_ids:
                        require(_derived_identity(path) == snapshot_input_ids[path],
                                'Consumed provider snapshot changed before release')
                        # Its raw dependencies are now complete. Only this
                        # explicitly selected, manifest-bound copy can retire;
                        # original preserved_inputs and every keeper stay pinned.
                        del snapshot_input_ids[path]
            for path in snapshots:
                value = _derived_identity(path)
                require(all(path not in pins or pins[path] == value
                            for pins in (input_ids, snapshot_input_ids)),
                        'Preserved provider snapshot changed')
                snapshot_input_ids.setdefault(path, value)
            groups = record['asset_groups']
            result['already_absent_names'] = result.get('already_absent_names',0)+len(absent)
        else:
            old = read_ref(record['manifest']); keeper = read_ref(record['keeper'])
            require(set(old) <= {'identity', 'assets', 'asset_ownership'} and set(keeper) <= {'identity', 'assets', 'asset_ownership'}
                    and {'identity','assets'} <= set(old) and {'identity','assets'} <= set(keeper), 'Unknown extraction marker')
            require(all(marker.get('asset_ownership', 'wikidict.extraction-owned-assets.v1') ==
                        'wikidict.extraction-owned-assets.v1' for marker in (old, keeper)), 'Unknown extraction ownership')
            identities = [dict(marker['identity']) for marker in (old, keeper)]
            for identity in identities:
                require('tool' in identity, 'Extraction tool provenance is missing'); identity.pop('tool')
            require(identities[0] == identities[1], 'Extraction input identity differs')
            def assets(marker):
                rows = marker['assets']; require(isinstance(rows, list) and rows, 'Missing extraction assets')
                names = []
                for row in rows:
                    require(isinstance(row, list) and len(row) == 3 and isinstance(row[0], str)
                            and type(row[1]) is int and row[1] >= 0 and isinstance(row[2], str)
                            and re.fullmatch('[0-9a-f]{64}', row[2]), 'Invalid extraction asset')
                    path = Path(row[0]); require(not path.is_absolute() and str(path) == row[0]
                        and all(part not in ('.', '..') for part in path.parts), 'Escaped extraction asset')
                    names.append(row[0])
                require(names == sorted(set(names)), 'Unordered or duplicate extraction assets')
                return {row[0]: row[1:] for row in rows}
            before, retained = assets(old), assets(keeper)
            require({k:v for k,v in before.items() if k != 'extraction-source.json'} ==
                    {k:v for k,v in retained.items() if k != 'extraction-source.json'}, 'Unique derived assets lack a retained keeper')
            groups = record['asset_groups']
            require(isinstance(groups, list) and groups == sorted(set(groups)) and groups
                    and set(groups) <= {'modules', 'shared-indexes'}, 'Unknown derived asset selection')
            names = [name for name in before if ('modules' in groups and name.startswith('modules/'))
                     or ('shared-indexes' in groups and name in DERIVED_SHARED_ASSETS)]
        require((names or provider_copies) and len(names) * len(record['aliases']) <= GENERATED_RETIREMENT_MAX_ENTRIES,
                'Derived asset selection exceeds bound')
        aliases = [bound_directory(spec, 'Released derived alias') for spec in record['aliases']]
        require((len(aliases) == 1 if provider_copies else 2 <= len(aliases) <= 4) and len(set(aliases)) == len(aliases)
                and all(not a.is_relative_to(b) for a in aliases for b in aliases if a != b), 'Ambiguous derived aliases')
        keeper_root = Path(record['keeper']['path']).parent
        if provider_copies:
            require(aliases == [provider_root] and Path(record['manifest']['path']).parent == provider_root
                    and keeper_root != provider_root, 'Provider copies are outside the closed workspace')
        else:
            require(Path(record['manifest']['path']) == aliases[0]/'.complete.json', 'Old manifest root differs')
            keeper_root = Path(record['keeper']['path']).parent
            require(Path(record['keeper']['path']).name == '.complete.json' and keeper_root not in aliases,
                    'Keeper is not a separate generation')
            old_key = hashlib.sha256(json.dumps(old['identity'], sort_keys=True).encode()).hexdigest()
            keeper_key = hashlib.sha256(json.dumps(keeper['identity'], sort_keys=True).encode()).hexdigest()
            require(aliases[0].name == old_key and keeper_root.name == keeper_key
                    and keeper_root.parent.name == 'extraction-cache', 'Extraction generation key differs')
        _, workspace = source_roots(cfg)
        require(all(path.is_relative_to(workspace/'data') for path in [*aliases, keeper_root]), 'Derived generation is outside owned data')
        for root in aliases:
            require(not any(point.is_relative_to(root) for point,_,_ in mounts),
                    'Derived alias contains an unowned mount')
            if not provider_copies:
                require((root.parent.name == 'extraction-cache' and root.name == old_key)
                        or (root.name == '.bundle-expander' and (root.parent.name == 'expander'
                            or root.parent.name.endswith('.building'))), 'Unknown derived generation role')
        if provider_copies and not names:
            reconcile_sources(roles_reference,locks)
            result['generations'].append(dict(manifest=record['manifest'],keeper=record['keeper'],aliases=record['aliases'],already_absent=absent))
            continue
        parent_ids = {}
        def regular(path):
            for parent in path.parents:
                if parent in parent_ids: break
                parent_ids[parent] = _generated_tree_identity(parent)
            value = _derived_identity(path)
            require(stat.S_ISREG(value[2]) and value[3:5] == (os.geteuid(),os.getegid()), 'Unsafe derived asset')
            return value
        def check_parents(paths):
            parents = {parent for path in paths for parent in path.parents}
            require(all(_generated_tree_identity(parent) == parent_ids[parent] for parent in parents),
                    'Derived parent changed')
        # Check directory users before opening our own cleanup-only directory
        # fds. A lazy worker cwd is a consumer even before it opens an asset.
        for root in aliases:
            for parent in (root,*root.parents):
                if parent not in parent_ids: parent_ids[parent] = _generated_tree_identity(parent)
            for name in names:
                for parent in (root/name).parents:
                    if parent in parent_ids: break
                    parent_ids[parent] = _generated_tree_identity(parent)
        directory_ids = {value[:2] for path,value in parent_ids.items()
                         if any(path.is_relative_to(root) for root in aliases)}
        require(not _generated_consumers(directory_ids), 'Derived directory has a live consumer')
        fds = []
        try:
            for root in sorted(aliases):
                fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW); fds.append(fd)
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            selected = []; inode_keys = set()
            fresh = reconcile_sources(roles_reference, locks)
            baseline = fresh
            def refresh():
                current = reconcile_sources(roles_reference, locks)
                require(current == baseline, 'Current or queued source selection changed')
                check_inputs()
                return current
            check_inputs()
            marker_ids = {Path(ref['path']): _derived_identity(Path(ref['path'])) for ref in metadata_refs}
            if provider_copies:
                for reference in metadata_refs: read_ref(reference)
                require(all(_derived_identity(path) == value for path,value in marker_ids.items()), 'Provider metadata changed during authentication')
            keep_paths = protected + fresh['paths'] + [keeper_root]
            regions = [region for path in keep_paths for region in execution_mount_regions(path, mounts)]
            overlapping_regions = {}
            for root in aliases:
                require(not any(root.is_relative_to(p) for p in keep_paths),
                        'Derived alias overlaps protected source')
                mapped = execution_mount_regions(root,mounts)
                require(not any(device == other_device and region.is_relative_to(other)
                    for device,region in mapped for other_device,other in regions),
                    'Derived alias physically overlaps protected source')
                overlapping_regions[root] = [(region,other) for device,region in mapped
                    for other_device,other in regions if device == other_device and other.is_relative_to(region)]
            for ordinal,name in enumerate(names):
                require(time.monotonic() < deadline, 'Derived cleanup deadline reached')
                require(not any(part in ('.presentation-first-failure','capture.json','diagnostic-result.json')
                                for part in Path(name).parts), 'Unique diagnostic cannot be retired')
                paths = [root/name for root in aliases]; observed = [regular(p) for p in paths]
                require(not any(path.is_relative_to(p) or p.is_relative_to(path) for path in paths for p in keep_paths)
                        and not any((region/name).is_relative_to(other) or other.is_relative_to(region/name)
                            for root in aliases for region,other in overlapping_regions[root]),
                        'Selected derived asset overlaps protected source')
                require(all(value == observed[0] for value in observed) and observed[0][5] == len(aliases),
                        'Unknown aliases or changed derived links')
                value = observed[0]; retained_path = keeper_root/name; kept = regular(retained_path)
                require(value[:2] != kept[:2] and value[:2] not in inode_keys
                        and value[:2] not in fresh['identities']
                        and value[:2] not in {v[:2] for pins in (input_ids, snapshot_input_ids) for v in pins.values()}, 'Derived inode is current or ambiguously shared')
                inode_keys.add(value[:2])
                require(value[6] == kept[6] == before[name][0] and digest(paths[0]) == before[name][1]
                        and digest(retained_path) == before[name][1], 'Derived or keeper bytes differ')
                require(all(regular(p) == value for p in paths) and regular(retained_path) == kept,
                        'Derived assets changed during authentication')
                selected.append((ordinal,name,value,kept))
            check_parents(root/name for root in [*aliases,keeper_root] for name in names)
            require(not _generated_consumers(inode_keys), 'Derived generation has a live consumer')
            # The shared chunker budgets the frozen environment, pointers and NULs.
            # Use its windows to retain complete hardlink groups in each transaction.
            by_name = {row[1]:row for row in selected}; last_prefix = str(aliases[-1])+'/'
            all_paths = [str(root/name) for _,name,_,_ in selected for root in aliases]
            append(dict(event='selection', manifest=record['manifest'], keeper=record['keeper'],
                        aliases=record['aliases'], asset_groups=groups, count=len(selected)))
            for window in _retention_path_chunks(all_paths, environment=environment):
                require(time.monotonic() < deadline, 'Derived cleanup deadline reached')
                batch = [by_name[path[len(last_prefix):]] for path in window if path.startswith(last_prefix)]
                if not batch: continue
                fresh = refresh()
                require(not inode_keys.intersection(fresh['identities']), 'New current source aliases derived assets')
                nodes = [(root/name,_retention_stamp(root/name)) for _,name,_,_ in batch for root in aliases]
                require(_retention_locks_clear(nodes), 'Derived inode is locked')
                for chunk in _retention_path_chunks([str(p) for p,_ in nodes], environment=environment):
                    probe = subprocess.run(['/usr/bin/fuser','-I',*chunk],capture_output=True,text=True,
                        env=environment,timeout=max(0.001,deadline-time.monotonic()))
                    require(probe.returncode == 1 and probe.stdout == probe.stderr == '', 'Derived inode has an open consumer')
                require(_retention_locks_clear(nodes), 'Derived inode locked after open probe')
                check_parents([*[p for p,_ in nodes], *[keeper_root/name for _,name,_,_ in batch]])
                for _,name,value,kept in batch:
                    require(all(regular(root/name) == value for root in aliases)
                            and regular(keeper_root/name) == kept, 'Keeper or derived asset changed before unlink')
                require(time.monotonic() < deadline, 'Derived cleanup deadline reached')
                require(all(_derived_identity(p) == value for p,value in marker_ids.items()), 'Extraction manifest changed')
                refresh()
                append(dict(event='selected-chunk', ordinals=[row[0] for row in batch]))
                if provider_copies:
                    retired = aliases[0]/RETIRED_PROVIDER_MARKERS[0]
                    previous = read_json(retired) if retired.exists() else dict(schema='wikidict.retired-provider-payloads.v1',records=[])
                    require(not retired.is_symlink() and previous.get('schema') == 'wikidict.retired-provider-payloads.v1' and isinstance(previous.get('records'),list),
                            'Unknown prior provider-retirement evidence')
                    item = dict(manifest=record['manifest'],keeper=record['keeper'],payload_names=names,
                                consumer_release=roles_reference,selection='closed-disposable-copy',status='historical-ineligible',already_absent=absent)
                    if item not in previous['records']:
                        previous['records'].append(item);write_json(retired,previous,replace=retired.exists())

                for ordinal,name,value,kept in batch:
                    expected = value
                    for index,root in enumerate(aliases):
                        path=root/name
                        require(regular(path) == expected and regular(keeper_root/name) == kept,
                                'Derived asset or keeper changed during unlink')
                        path.unlink(); result['removed_names'] += 1
                        if index+1 < len(aliases):
                            after = regular(aliases[index+1]/name)
                            require(after[:5] == expected[:5] and after[5] == expected[5]-1
                                    and after[6:9] == expected[6:9], 'Unexpected hardlink transition')
                            expected = after
                        else:
                            result['freed_inodes'] += 1; result['freed_logical_inode_bytes'] += value[6]
                            result['freed_allocated_inode_bytes'] += value[7] * 512
                append(dict(event='completed-chunk', removed_names=result['removed_names'],
                            freed_inodes=result['freed_inodes'], freed_allocated_inode_bytes=result['freed_allocated_inode_bytes']))
            require(all(regular(keeper_root/name) == kept for _,name,_,kept in selected), 'Keeper changed after retirement')
            check_parents([keeper_root/name for name in names])
            read_ref(record['manifest']); read_ref(record['keeper']); refresh()
            result['generations'].append(dict(manifest=record['manifest'],keeper=record['keeper'],aliases=record['aliases']))
        except (OSError, ValueError, KeyError, TypeError, AssertionError, subprocess.SubprocessError) as error:
            result.update(status='cleanup-deferred',error=f'{type(error).__name__}: {error}',partial_removal_possible=bool(result['removed_names']))
            append(dict(event='deferred', **result)); return result
        finally:
            for fd in reversed(fds): os.close(fd)
    result['accounting'] = 'Distinct last-link inode allocation removed; exclusive filesystem gain unknown'
    append(dict(event='result', **result)); return result


def cleanup_superseded_generated(cfg, edition, folder, attempt, locks, *, reconcile_derived_sources=None):
    """Retire explicitly released predecessor roles after a joined replacement.

    Config generation transfers only exact closed, consumer-released roles.
    Legacy generations without that relation remain manual cleanup work.
    """
    import re
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
            require(isinstance(record, dict) and {'configuration', 'result', 'closure', 'runtime_roles'} <= set(record)
                    and set(record) <= {'configuration', 'result', 'closure', 'runtime_roles', 'derived_assets', 'provider_copies', 'raw_intermediates'},
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
            derived = record.get('derived_assets', [])
            require(isinstance(derived, list) and len(derived) <= 1
                    and (not derived or matches[0].get('released_derived_assets') == derived),
                    'Derived assets lack exact consumer release')
            provider = record.get('provider_copies', [])
            require(isinstance(provider,list) and len(provider) <= PROVIDER_COPY_MAX_RECORDS
                    and (not provider or matches[0].get('released_provider_copies') == provider),
                    'Provider copies lack exact consumer release')
            raw_role = record.get('raw_intermediates')
            require(raw_role is None or (isinstance(raw_role, dict)
                    and set(raw_role) == {'root', 'owner', 'state'}
                    and matches[0].get('released_raw_intermediates') == raw_role),
                    'Raw intermediates lack exact consumer release')
            # The derived branch removes only declared files. Do not feed its
            # roots to the legacy whole-tree path, even when that branch defers.
            derived_roots = [Path(spec['path']) for row in derived for spec in row['aliases']]
            paths = [path for path in paths if not any(path.is_relative_to(root) or root.is_relative_to(path)
                                                      for root in derived_roots)]
            if provider and not derived: paths = []  # Provider-only release never selects worker trees.
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
                raw_dirs, raw_files, raw_inventory = [], {}, None
                raw_result = None
                if raw_role is not None:
                    raw = Path(old['raw_shard_root']) / edition / (date + '.raw-shards')
                    workspace = parent / (date + '.shards')
                    require(raw_role['root']['path'] == str(raw)
                            and raw_role['owner']['path'] == str(raw / '.wikidict-raw-shards.json')
                            and raw_role['state']['path'] == str(workspace / 'state.json'),
                            'Released raw path differs from the predecessor workspace')
                    raw_result = dict(status='absent', removed=[], removed_file_count=0,
                                      removed_logical_file_bytes=0, removed_allocated_file_bytes=0,
                                      preserved='Raw owner/state, coverage, failure/page/timing receipts and all unknown members')
                    if raw.exists() or raw.is_symlink():
                        bound_directory(raw_role['root'], 'Released raw intermediates')
                        require(read_ref(raw_role['owner']) == dict(version=1, workspace=str(workspace), raw_shards=str(raw)),
                                'Released raw owner differs')
                        state = read_ref(raw_role['state'])
                        require(state.get('edition') == edition and state.get('date') == date
                                and state.get('raw_shards_path') == str(raw), 'Released raw state differs')
                        owner.check_path(raw)
                        for shard in sorted(raw.iterdir()):
                            if re.fullmatch(r'[0-9]{8}', shard.name):
                                owner.check_path(shard)
                                _generated_tree_identity(shard)
                                for name in ('languages', '.spool'):
                                    path = shard / name
                                    if path.exists() or path.is_symlink(): raw_dirs.append(path)
                        # The old raw root is a container, not a payload. Keep its
                        # unique metadata and every nonselected member in place.
                        raw_preserved = protected + [Path(old[name]) for name in ('state_directory', 'downloads')]
                        raw_preserved.extend(Path(record[name]['path']) for name in ('configuration', 'result', 'closure', 'runtime_roles'))
                        if old.get('source', {}).get('root'):
                            raw_preserved.append(Path(old['source']['root']['path']))
                        for options in old.get('edition_options', {}).values():
                            for name in ('staged_input_root', 'extraction_cache_root'):
                                if name in options:
                                    raw_preserved.append(Path(options[name]['path']))
                        raw_regions = [region for path in raw_preserved for region in execution_mount_regions(path, mounts)]
                        for path in raw_dirs:
                            owner.check_path(path)
                            require(not any(path.is_relative_to(keep) or keep.is_relative_to(path) for keep in raw_preserved),
                                    'Raw intermediate overlaps current inputs or generation')
                            require(not any(point != owner.path and point.is_relative_to(owner.path)
                                            and (path.is_relative_to(point) or point.is_relative_to(path)) for point, _, _ in mounts),
                                    'Raw intermediate contains a mount alias')
                            require(not any(device == other_device and (region.is_relative_to(other) or other.is_relative_to(region))
                                            for device, region in execution_mount_regions(path, mounts)
                                            for other_device, other in raw_regions), 'Raw intermediate physically aliases protected inputs')
                        raw_inventory = _generated_inventory(raw_dirs)
                        spool_names = {f'lang-{i:02d}.tmp' for i in range(32)} | {
                            name + '.tmp' for name in ('thesaurus','citations','reconstruction','rhymes','sign-gloss','supplemental','aliases')}
                        for identity, value in raw_inventory['files'].items():
                            path = Path(value['path'])
                            if path.parent not in raw_dirs: continue
                            disposable = (path.name in spool_names if path.parent.name == '.spool' else
                                          re.fullmatch(r'[0-9a-f]{64}\.wikblb(?:\.xz(?:\.part)?)?', path.name))
                            if disposable: raw_files[path] = (identity, value)
                        require(not raw_files or not _generated_consumers(raw_inventory['identities']),
                                'Raw predecessor has a live consumer')
                        raw_result['status'] = 'no-selected-payload'
                derived_result = None
                if derived:
                    # Mutable cache/output containers are not blanket pins. The
                    # fresh coordinator supplies their exact consumed generations.
                    derived_protected = [Path(replacement['root']), *[Path(cfg[key]) for key in ('raw_shard_root','state_directory','downloads')],
                        *[Path(old[key]) for key in ('raw_shard_root','state_directory','downloads')],
                        *[source / name for name in (*PRODUCER_SOURCE_FILES, *PRODUCER_SOURCE_DIRECTORIES)]]
                    for options in cfg.get('edition_options',{}).values():
                        if 'staged_input_root' in options: derived_protected.append(Path(options['staged_input_root']['path']))
                    try:
                        from build_wiktionaries import DUMP_STAGING_VERSION
                        old_inputs = []
                        for options in old.get('edition_options',{}).values():
                            if 'staged_input_root' not in options: continue
                            stage = options['staged_input_root']
                            root = bound_directory({key:stage[key] for key in ('path','device','inode','uid','mode')},
                                                   'Released old staged input')
                            require(stage['completion']['path'] == str(root/'.complete.json'), 'Old staged completion path differs')
                            marker = read_ref(stage['completion'])
                            require(marker.get('version') == DUMP_STAGING_VERSION and marker.get('dump_codec') == 'zstd'
                                    and marker.get('dump_stream_kind') == 'multistream-zstd', 'Unknown released old staged input schema')
                            payloads = [('dump',root/'pages.xml.zst'),('index',root/'pages-index.txt.bz2')]
                            require(all(path.is_file() and not path.is_symlink() and path.stat().st_size == marker.get(label+'_size')
                                        for label,path in payloads), 'Old staged payload identity is unavailable')
                            # Keep original input/provenance leaves; only the
                            # explicitly released derived children may be removed.
                            old_inputs.extend([root/'.complete.json',*[path for _,path in payloads]])
                        derived_protected.extend(old_inputs)
                        derived_result = _retire_derived_assets(derived, roles_reference=record['runtime_roles'],
                            cfg=cfg, folder=folder, locks=locks, protected=derived_protected,
                            reconcile_sources=reconcile_derived_sources, preserved_inputs=old_inputs)
                    except (OSError, ValueError, KeyError, TypeError, AssertionError, subprocess.SubprocessError) as error:
                        derived_result = dict(status='cleanup-deferred',error=f'{type(error).__name__}: {error}',removed_names=0)
                provider_result = None
                if provider:
                    try:
                        provider_root = parent/(date+'.shards');owner.check_path(provider_root)
                        provider_result = _retire_derived_assets(provider,roles_reference=record['runtime_roles'],
                            cfg=cfg,folder=folder,locks=locks,protected=preserved,
                            reconcile_sources=reconcile_derived_sources,provider_copies=True,provider_root=provider_root,
                            provider_options=old.get('edition_options',{}).get(edition,{}).get('auxiliary_snapshots',{}),
                            provider_edition=edition)
                    except (OSError,ValueError,KeyError,TypeError,AssertionError,subprocess.SubprocessError) as error:
                        provider_result = dict(status='cleanup-deferred',error=f'{type(error).__name__}: {error}',removed_names=0)
                present = [(path, _generated_tree_identity(path)) for path in paths if path.exists() or path.is_symlink()]
                inventory = _generated_inventory([path for path, _ in present])
                require(not inventory['identities'] or not _generated_consumers(inventory['identities']),
                        'Generated predecessor has a live consumer')
                # Validate the entire selection before touching any tree. The
                # same metadata is checked again immediately before each removal.
                current = [(path, _generated_tree_identity(path)) for path in paths if path.exists() or path.is_symlink()]
                require(current == present and _generated_inventory([path for path, _ in current]) == inventory,
                        'Generated descendants changed before retirement')
                if raw_inventory is not None:
                    require(_generated_inventory(raw_dirs) == raw_inventory, 'Raw intermediates changed before retirement')
                    read_ref(raw_role['owner']); read_ref(raw_role['state'])
                result = dict(configuration=record['configuration'], result=record['result'],
                              closure=record['closure'], removed=[], removed_file_count=0,
                              **({'derived_assets':derived_result} if derived_result is not None else {}),
                              **({'provider_copies':provider_result} if provider_result is not None else {}),
                              **({'raw_intermediates':raw_result} if raw_result is not None else {}),
                              removed_logical_file_bytes=0, removed_allocated_file_bytes=0,
                              accounting='Completed removals from deduplicated inode inventory; not filesystem free-space delta',
                              preserved='Publication, inputs, raw ownership and diagnostics, captures and all nonselected siblings')
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
                for path, (identity, value) in sorted(raw_files.items()):
                    removal_started = False
                    try:
                        for lock in locks: lock.check()
                        bound_directory(raw_role['root'], 'Released raw intermediates')
                        owner.check_path(path)
                        metadata = raw_inventory['snapshot'][str(path.parent)]
                        require(_generated_tree_identity(path.parent) == (metadata[0], metadata[1], metadata[3], metadata[2]),
                                'Raw payload directory changed before unlink')
                        info = path.lstat()
                        stamp = (info.st_dev,info.st_ino,info.st_mode,info.st_uid,info.st_nlink,
                                 info.st_size,info.st_mtime_ns,info.st_ctime_ns,info.st_blocks)
                        require(stamp == raw_inventory['snapshot'][str(path)], 'Raw payload changed before unlink')
                        read_ref(raw_role['owner']); read_ref(raw_role['state'])
                        removal_started = True
                        owner.unlink(path)
                    except (OSError, ValueError) as exc:
                        raw_result.update(status='cleanup-deferred', incomplete_removal=str(path), partial_removal_unknown=removal_started)
                        return dict(status='cleanup-deferred', error=f'{type(exc).__name__}: {exc}', generations=results)
                    raw_result['removed'].append(str(path))
                    raw_result['removed_file_count'] += 1
                    raw_result['removed_logical_file_bytes'] += value['bytes']
                    raw_result['removed_allocated_file_bytes'] += value['allocated_bytes']
                    raw_result['status'] = 'generated-raw-payload-retired'
            finally:
                os.close(fd)
        return dict(status=('cleanup-deferred' if any(row.get('derived_assets',{}).get('status') == 'cleanup-deferred'
                                or row.get('provider_copies',{}).get('status') == 'cleanup-deferred' for row in results)
                            else 'superseded-generated-retired'), generations=results)
    finally:
        fcntl.flock(locks[1].fd, fcntl.LOCK_UN)


def execute(cfg, edition, workers, folder, sequence, context, locks, memory_limit_bytes=MEMORY, *, reconcile_derived_sources=None, prepared_authorization=None):
    from build_resource_limits import _signal_owned
    folder.mkdir()
    start = dict(attempt_id=folder.name, sequence=sequence, edition=edition, date=cfg['date'],
        workers_requested=workers, memory_limit_bytes=memory_limit_bytes, address_space='unlimited', context=context,
        controller=process_identity(os.getpid()), started_utc=utc(), argv=command(cfg, edition, workers, memory_limit_bytes,
            **({'prepared_bytecode_prefix':str(folder/'unwritten-python-cache')} if cfg.get('prepared_source_custody') is True or cfg.get('python_tooling') is not None else {})))
    start['argv'] = compact_role_argv(start['argv'], folder)
    if cfg.get('prepared_source_custody') is True:
        bytecode_prefix=folder/'unwritten-python-cache'
        require(not os.path.lexists(bytecode_prefix), 'Prepared bytecode prefix is not absent')
        start['prepared_source_control']=dict(version=1,configuration=cfg,resume=prepared_authorization,
            bytecode_prefix=str(bytecode_prefix))
    elif prepared_authorization is not None:
        raise ValueError('Unselected prepared source authorization')
    write_json(folder / 'start.json', start)
    start_ref=descriptor(folder/'start.json') if cfg.get('prepared_source_custody') is True else None
    active_prepared=None
    started = time.monotonic()
    error, process, rc = None, None, None
    interrupted = False
    source_verified = False
    source_observation = None
    control_verified = False
    try:
        with (folder / 'build.log').open('xb') as log:
            launch_options={}
            if start_ref is not None:
                environment=dict(os.environ)
                environment['WIKIDICT_PREPARED_SOURCE_ATTEMPT']=json.dumps(start_ref,sort_keys=True)
                environment['PYTHONPYCACHEPREFIX']=start['prepared_source_control']['bytecode_prefix']
                launch_options['env']=environment
            process = subprocess.Popen(start['argv'], cwd=folder, stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT, start_new_session=True,**launch_options)
            identity = process_identity(process.pid)
            require(identity is not None, 'Could not record tracked CLI identity')
            write_json(folder / 'launch.json', dict(identity=identity, private_session=process.pid))
            if prepared_authorization is not None:
                import build_wiktionaries as builder
                prior=builder.prepared_metadata(prepared_authorization['authorization'])
                active_prepared=authorize_prepared_source(cfg,start,start_ref,folder/'launch.json',
                    prior['prepared_source_authorization']['generation'],process=process,inherited=prepared_authorization)
            while process.poll() is None:
                if start_ref is not None and active_prepared is None and (folder/'prepared-generation.json').is_file():
                    active_prepared=authorize_prepared_source(cfg,start,start_ref,folder/'launch.json',
                        descriptor(folder/'prepared-generation.json'),process=process)
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
    log_ref, evidence, phase_error = read_attempt_log(folder / 'build.log', edition, cfg['date'])
    if phase_error:
        error = '; '.join(part for part in (error, 'Invalid phase evidence: ' + phase_error) if part)
    phase = evidence['end']
    accepted = None
    cleanup_proven = process is not None and process.poll() is not None and watchdog_closed(wd)
    try:
        for lock in locks:
            lock.check()
        if active_prepared is not None:
            final_path=folder/'prepared-finalization.json'
            if final_path.is_file():active_prepared=dict(active_prepared,finalization=descriptor(final_path))
            observed_source=source_guard(cfg,prepared_authorization=active_prepared)
        else:
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
    if active_prepared is not None:row['prepared_source_authorization']=active_prepared
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
            retirement = cleanup_superseded_generated(cfg, edition, folder, row, locks,
                **({'reconcile_derived_sources':reconcile_derived_sources} if reconcile_derived_sources is not None else {}))
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
    parser.add_argument('--python-tooling-json')
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--phase', choices=('pilot', 'remaining', 'all'), default='pilot')
    parser.add_argument('--max-editions', type=int, help='Yield after N closed editions, including all own-cap retries; default unbounded')
    parser.add_argument('--retry-failed', action='store_true')
    parser.add_argument('--revalidate', action='store_true')
    parser.add_argument('--defer-english', action='store_true', help='Remaining/all phase: preserve English as pending while its capture completes')
    args = parser.parse_args(argv)
    require(args.max_editions is None or args.max_editions > 0, 'max-editions must be positive')
    cfg = read_json(args.config)
    require((json.loads(args.python_tooling_json) if args.python_tooling_json is not None else None)==cfg.get('python_tooling'), 'Controller startup tooling differs from its configuration')
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
    derived_reconciler = _reconcile_derived_sources if any(record.get('derived_assets') or record.get('provider_copies')
        for rows in predecessors.values() for record in rows) else None
    campaign = campaign_selection(cfg, manifest)
    require({x['date'] for x in manifest['files']} == {cfg['date']} == {'20261001'}, 'Dump date selection changed')
    source_guard(cfg)
    # Reject an uncommitted qualified inventory before child/input setup.
    if cfg.get('prepared_source_custody') is True:
        prepared_git_source_authority(cfg)
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
            prepared_authorization = None
            while workers:
                for lock in locks:
                    lock.check()
                if prepared_authorization is None:
                    source_guard(cfg)
                else:
                    source_guard(cfg, prepared_authorization=prepared_authorization)
                sequence += 1
                folder = state / 'attempts' / f'{sequence:06d}-{edition}-w{workers}-{uuid.uuid4().hex[:12]}'
                row, wd = execute(cfg, edition, workers, folder, sequence, context, locks, memory_limit_bytes,
                    **({'reconcile_derived_sources':derived_reconciler} if derived_reconciler is not None else {}),
                    **({'prepared_authorization':prepared_authorization} if prepared_authorization is not None else {}))
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
                prepared_authorization=row.get('prepared_source_authorization')
                if prepared_authorization is not None and prepared_authorization.get('finalization') is not None:
                    # Native scratch was deliberately retired after verified
                    # staging. Never turn a later resource retry into a fresh
                    # canonical preparation or mix generations implicitly.
                    row['prepared_source_fresh_attempt_required']='native generation finalized; bind verified staging as an explicit whole attempt'
                    write_json(folder/'result.json',row,replace=True)
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
