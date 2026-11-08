"""Callable support for authenticated native qualification commands."""
import hashlib
import json
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
