"""Callable support for authenticated native qualification commands."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import time


MEDIA_SUFFIXES = (
    'media retention protects oldest selected file while evicting newer files',
    'media retention keeps sole oversized selection until ordinary trim',
    'ordinary zero-budget media trim removes cached files',
    'media trim releases names and list storage on every allocation failure',
)


REQUIRED_SUFFIXES = MEDIA_SUFFIXES + (
    'AS corroborated support ownership preserves complete authored noun adjective payload',
    'AS support ownership requires edition trusted categories and both source declarations',
    'AS support ownership refuses protected nested missing and conflicting category evidence',
    'AS support ownership refuses mixed banners unsupported boundaries and real language headings',
    'default text retains unorganized nested lists without classifying meanings',
    'default text retains selective definitions when organization is absent',
    'missing language prefix refusal requires active matching evidence in its exact domain',
    'ZA literal banner alias proof rejects dynamic malformed and mixed declarations',
    'ZA indexed static aliases preserve registry conflicts and edition scope',
    'ZA captured aliases retain two Australia owners and unresolved source controls through DPR2',
    'ZA missing Portuguese prefix cannot be absorbed by a later Spanish alias',
)


ANSI = re.compile(r'\x1b\[[0-9;]*m')


SUMMARY = re.compile(r'^pass: (\d+)  fail: (\d+)  skip: (\d+)  leak: (\d+)  crash: (\d+)$', re.M)


STATUS = re.compile(r'^(ok|error|skip|leak|crash) (.*?)(?: \| .*|)$', re.M)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        before = os.fstat(stream.fileno())
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
        after = os.fstat(stream.fileno())
    assert (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    return h.hexdigest()


def ref(path):
    path = Path(path)
    return {'path': str(path), 'bytes': path.stat().st_size, 'sha256': digest(path)}


def write(path, value):
    temporary = path.with_suffix(path.suffix + '.partial')
    with temporary.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def classify(stdout, stderr, *, standalone):
    text = ANSI.sub('', stdout + '\n' + stderr)
    groups = [list(map(int, group)) for group in SUMMARY.findall(text)]
    statuses = STATUS.findall(text)
    names = [name for status, name in statuses if status == 'ok']
    required = {suffix: [name for name in names if name.endswith('.test.' + suffix)] for suffix in (MEDIA_SUFFIXES if standalone else REQUIRED_SUFFIXES)}
    passed = bool(groups and all(group[1:] == [0, 0, 0, 0] for group in groups)
                  and sum(group[0] for group in groups) == len(statuses) == len(names)
                  and all(len(matches) == 1 for matches in required.values()))
    if standalone:
        passed = passed and groups == [[4, 0, 0, 0, 0]] and len(names) == 4
    return {'passed': passed, 'groups': groups, 'status_count': len(statuses), 'required_tests': required,
            'nonpassing_tests': [{'status': status, 'name': name} for status, name in statuses if status != 'ok']}


def normalize_direct_control_result(control, selected_cases):
    """Derive progress without changing raw absence, source or custody evidence."""
    if not isinstance(control, dict) or control.get('schema') != 'existing-direct-root-controls-result.v1':
        raise ValueError('Unsupported direct control result')
    expected = {}
    for case in selected_cases:
        if not isinstance(case, dict) or any(not isinstance(case.get(k), str) or not case[k] for k in ('root', 'name')):
            raise ValueError('Invalid selected control identity')
        identity = (case['root'], case['name'])
        if identity in expected:
            raise ValueError('Duplicate selected control identity')
        expected[identity] = case
    results, inventory, stages = (control.get(k) for k in ('test_results', 'compiled_inventory', 'stages'))
    if (not expected or not isinstance(results, list) or not isinstance(inventory, dict)
            or not isinstance(stages, list) or type(control.get('tests_run')) is not int
            or control['tests_run'] != len(results)):
        raise ValueError('Invalid direct control progress')
    counts = dict.fromkeys(('passed', 'failed', 'skipped', 'leaked', 'crashed'), 0)
    seen = set()
    for result in results:
        if not isinstance(result, dict) or any(not isinstance(result.get(k), str) for k in ('root', 'name')):
            raise ValueError('Invalid observed control')
        identity = (result.get('root'), result.get('name'))
        if identity not in expected or identity in seen or any(result.get(k) != v for k, v in expected[identity].items()):
            raise ValueError('Observed control identity differs')
        rc = result.get('returncode')
        if type(rc) is not int:
            raise ValueError('Invalid observed return code')
        status = {0: 'passed', 2: 'skipped', 3: 'leaked'}.get(rc, 'crashed' if rc < 0 else 'failed')
        if result.get('status') != status or identity[0] not in inventory:
            raise ValueError('Observed control verdict differs')
        seen.add(identity)
        counts[status] += 1
    compiled = 0
    for root, group in inventory.items():
        raw = group.get('inventory') if isinstance(group, dict) else None
        names = raw.get('tests') if isinstance(raw, dict) else None
        if (root not in {identity[0] for identity in expected} or not isinstance(names, list)
                or not all(isinstance(name, str) for name in names) or len(set(names)) != len(names)
                or type(raw.get('compiled_test_count')) is not int or raw['compiled_test_count'] != len(names)
                or set(names) != {identity[1] for identity in expected if identity[0] == root}):
            raise ValueError('Invalid compiled control inventory')
        compiled += len(names)
    keys = ('first_test_started_unix', 'elapsed_to_first_test_seconds')
    states = {k: 'absent' if k not in control else 'null' if control[k] is None else 'value' for k in keys}
    if len(set(states.values())) != 1:
        raise ValueError('Inconsistent first-test field presence')
    started = states[keys[0]] == 'value'
    if started:
        if (any(type(control[k]) not in (int, float) or (type(control[k]) is float and not math.isfinite(control[k])) for k in keys)
                or control[keys[0]] <= 0 or control[keys[1]] < 0):
            raise ValueError('Invalid first-test timing')
    if results and not started:
        raise ValueError('Executed controls lack first-test timing')
    if not all(isinstance(row, dict) and isinstance(row.get('name'), str) for row in stages):
        raise ValueError('Invalid control stages')
    unrun = [dict(case) for identity, case in expected.items() if identity not in seen]
    counts['unrun'] = len(unrun)
    return dict(schema='native-qualification-progress.v1',
                phase='tests_started' if started else 'compile_only' if any(row['name'].startswith('compile-') for row in stages) else 'setup_only',
                tests_run=len(results), compiled_root_count=len(inventory),
                compiled_inventory_occurrences=compiled, selected_counts=counts, controls_unrun=unrun,
                first_test_field_states=states,
                first_test_started_unix=control.get(keys[0]), elapsed_to_first_test_seconds=control.get(keys[1]))


def execute(out, name, argv, cwd):
    receipt = {'argv': argv, 'cwd': str(cwd), 'started_unix': time.time(), 'status': 'running'}
    write(out / (name + '.json'), receipt)
    start = time.monotonic()
    with (out / (name + '.stdout')).open('xb') as so, (out / (name + '.stderr')).open('xb') as se:
        result = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=so, stderr=se, check=False)
    receipt.update(status='exited', returncode=result.returncode, elapsed_seconds=time.monotonic() - start,
                   finished_unix=time.time())
    write(out / (name + '.json'), receipt)
    return receipt


def private_manifest(source, destination, expected_changes=None, *, authenticate_expected=None):
    assert expected_changes is not None, 'Explicit candidate scope required'
    if authenticate_expected is not None:
        assert expected_changes == set(), 'Cached authentication requires unchanged source'
        assert callable(authenticate_expected)
    actual_paths = {str(p.relative_to(destination)) for p in destination.rglob('*') if p.is_file()}
    assert actual_paths == set(source['files']), 'Private source file inventory differs'
    result, changed = {}, set()
    for name in sorted(actual_paths):
        p = destination / name
        expected = source['files'][name]
        mode = source['modes'][name]
        assert not p.is_symlink() and p.stat().st_nlink == 1
        assert stat.S_IMODE(p.stat().st_mode) == mode
        if authenticate_expected is None:
            actual = ref(p)
        else:
            assert Path(expected['path']) == p, 'Expected source path differs'
            assert authenticate_expected(expected) == p, 'Source authentication returned another path'
            assert not p.is_symlink() and p.stat().st_nlink == 1
            assert stat.S_IMODE(p.stat().st_mode) == mode
            actual = expected
        result[name] = dict(bytes=actual['bytes'], sha256=actual['sha256'], mode=mode)
        if actual['sha256'] != expected['sha256']:
            changed.add(name)
    assert changed == expected_changes, changed
    return result


def native_build_argv(args, cache):
    # Zig 0.17 build receives its global cache through the inherited environment.
    return [str(args.compiler), 'build', 'test', '-j1',
            '-Doptimize=safe', '-Dtarget=x86_64-native', '-Dcpu=baseline',
            '--search-prefix', '/usr', '--summary', 'all',
            '--cache-dir', str(cache / 'local')]
