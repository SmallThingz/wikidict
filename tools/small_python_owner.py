"""The existing small Python watchdog owner, with task bindings supplied as JSON.

One common future owner retains direct09 watchdog/execve behavior and result shape.
Source authentication streams each distinct stable object once per independent
pre/post pass, with a separate fd/path check for every bound path.
"""
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time


SOURCE_IO = '"""Stable bounded source authentication shared by owner and watchdog worker."""\nimport hashlib\nimport os\nfrom pathlib import Path\nimport stat\n\nBUFFER_BYTES = 256 * 1024\n\n\ndef absolute_path(value):\n    path = Path(value)\n    if not path.is_absolute() or \'..\' in path.parts:\n        raise ValueError(\'Bound paths must be absolute without parent traversal\')\n    return path\n\n\ndef identity(stamp):\n    return (stamp.st_dev, stamp.st_ino, stamp.st_mode, stamp.st_nlink,\n            stamp.st_uid, stamp.st_gid, stamp.st_size,\n            stamp.st_mtime_ns, stamp.st_ctime_ns)\n\n\ndef path_state(path):\n    return (identity(path.lstat()), str(path.resolve(strict=True)), identity(path.stat()))\n\n\ndef checked_state(path, stream, expected):\n    if identity(os.fstat(stream.fileno())) != expected[2] or path_state(path) != expected:\n        raise ValueError(\'Source identity changed: \' + str(path))\n\n\ndef open_source(path):\n    # Do not block if a regular path was replaced by a FIFO before open.\n    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)\n    return os.fdopen(fd, \'rb\', buffering=0)\n\n\nclass SourcePass:\n    """A memo belongs to one independent pass; it never survives child execution."""\n    def __init__(self):\n        self.objects = {}\n        self.paths = {}\n        self.references = 0\n        self.bytes_hashed = 0\n        self.aliases_reused = 0\n\n    def read(self, path, expected=None, *, capture=False):\n        path = absolute_path(path)\n        state = path_state(path)\n        stamp = state[2]\n        if not stat.S_ISREG(stamp[2]):\n            raise ValueError(\'Source is not a regular file: \' + str(path))\n        previous = self.paths.get(str(path))\n        if previous is not None and previous != state:\n            raise ValueError(\'Source identity changed: \' + str(path))\n        if expected is not None:\n            if type(expected[\'bytes\']) is not int or expected[\'bytes\'] < 0:\n                raise ValueError(\'Invalid expected source size: \' + str(path))\n            if stamp[6] != expected[\'bytes\']:\n                raise ValueError(\'Source changed: \' + str(path))\n            if \'mode\' in expected and stat.S_IMODE(stamp[2]) != expected[\'mode\']:\n                raise ValueError(\'Source mode changed: \' + str(path))\n        key = stamp[:2]\n        prior = self.objects.get(key)\n        if prior is not None:\n            if prior[\'identity\'] != stamp:\n                raise ValueError(\'Source identity changed: \' + str(path))\n            if expected is not None and (prior[\'bytes\'], prior[\'sha256\']) != (expected[\'bytes\'], expected[\'sha256\']):\n                raise ValueError(\'Conflicting source references: \' + str(path))\n        # Open even a reused hardlink: every path receives its own fd/path fence.\n        with open_source(path) as stream:\n            checked_state(path, stream, state)\n            if prior is None or capture:\n                digest = hashlib.sha256()\n                size = 0\n                chunks = [] if capture else None\n                buffer = memoryview(bytearray(BUFFER_BYTES))\n                while count := stream.readinto(buffer):\n                    size += count\n                    digest.update(buffer[:count])\n                    self.bytes_hashed += count\n                    if chunks is not None:\n                        chunks.append(bytes(buffer[:count]))\n                record = dict(bytes=size, sha256=digest.hexdigest())\n                if size != stamp[6]:\n                    raise ValueError(\'Source changed: \' + str(path))\n                if expected is not None and (size, record[\'sha256\']) != (expected[\'bytes\'], expected[\'sha256\']):\n                    raise ValueError(\'Source changed: \' + str(path))\n                self.objects[key] = dict(record, identity=stamp)\n            else:\n                self.aliases_reused += 1\n                chunks = None\n                record = dict(bytes=prior[\'bytes\'], sha256=prior[\'sha256\'])\n            checked_state(path, stream, state)\n        if path_state(path) != state:\n            raise ValueError(\'Source identity changed: \' + str(path))\n        self.paths[str(path)] = state\n        self.references += 1\n        return dict(path=str(path), **record), b\'\'.join(chunks) if chunks is not None else None\n\n    def finish(self):\n        # Catch replacement of an earlier path while a later source was hashed.\n        for name, expected in self.paths.items():\n            path = Path(name)\n            with open_source(path) as stream:\n                checked_state(path, stream, expected)\n        return dict(references=self.references, distinct_objects=len(self.objects),\n                    bytes_hashed=self.bytes_hashed, aliases_reused=self.aliases_reused,\n                    path_identities={name: dict(lstat=value[0], resolved=value[1], fstat=value[2])\n                                     for name, value in self.paths.items()})\n\n\ndef authenticate(ref, *, capture=True):\n    selected = SourcePass()\n    _, data = selected.read(ref[\'path\'], ref, capture=capture)\n    selected.finish()\n    return data\n\n\ndef authenticate_sources(refs):\n    selected = SourcePass()\n    for ref in refs:\n        selected.read(ref[\'path\'], ref)\n    return selected.finish()\n\n\ndef file_reference(path):\n    selected = SourcePass()\n    ref, _ = selected.read(path)\n    selected.finish()\n    return ref\n'
exec(compile(SOURCE_IO, __file__ + ":source_io", "exec"), globals())

WORKER = SOURCE_IO + "import json, os, subprocess, time, hashlib, sys\nfrom pathlib import Path\nrequest = json.loads(sys.argv[1])\nassert len(request) in (2, 3)\ncommand, output = request[:2]\ndirect_cli = len(request) == 3\nif direct_cli:\n    assert request[2] is True\nplan = json.loads(authenticate(command))\nout = Path(output)\nenv = os.environ.copy()\nenv.update(plan['env'])\nenv['TMPDIR'] = str(out / 'tmp')\n(out / 'tmp').mkdir()\nt = time.monotonic()\nwith (out / 'tests.stdout').open('xb') as so, (out / 'tests.stderr').open('xb') as se:\n    if direct_cli:\n        os.chdir(plan['cwd'])\n        os.dup2(so.fileno(), 1)\n        os.dup2(se.fileno(), 2)\n        # Keep the watchdog child PID/session and its unconsumed inheritable\n        # one-use proof descriptor. No intermediate subprocess may consume it.\n        os.execve(plan['argv'][0], plan['argv'], env)\n    r = subprocess.run(plan['argv'], cwd=plan['cwd'], env=env, stdout=so, stderr=se)\nref = file_reference\nwith (out / 'result01.json').open('x') as f:\n    json.dump(dict(returncode=r.returncode, argv=plan['argv'], cwd=plan['cwd'], environment=plan['env'], measurement_scope=plan['scope'], elapsed_seconds=time.monotonic() - t, stdout=ref(out / 'tests.stdout'), stderr=ref(out / 'tests.stderr')), f, indent=2)\n    f.write('\\n')\nsys.exit(r.returncode)\n"


def inherited_child_nice(config):
    value = config.get('child_nice')
    if value is not None and (type(value) is not int or not 0 <= value <= 19 or
                              value != max(0, os.getpriority(os.PRIO_PROCESS, 0))):
        raise ValueError('Normal child priority must preserve inherited niceness')
    return value


def prepare(config, *, source_checks=None):
    """Resolve data once and reject setup mistakes before host admission."""
    command = absolute_path(config['input_ref']['path'])
    plan = json.loads(authenticate(config['input_ref']))
    output = absolute_path(config['output_root'])
    if absolute_path(plan['qualification_root']) != output:
        raise ValueError('Command and owner output roots differ')
    if output.is_symlink() or not output.is_dir():
        raise ValueError('Qualification parent must already be a real directory')
    runtime = output / 'direct-runtime01'
    for leaf in ('direct-runtime01', 'tmp', 'tests.stdout', 'tests.stderr', 'result01.json'):
        if os.path.lexists(output / leaf):
            raise ValueError('Qualification output already exists: ' + leaf)
    if not absolute_path(plan['cwd']).is_dir():
        raise ValueError('Command working directory is absent')
    argv = plan['argv']
    if not isinstance(argv, list) or not argv or not all(isinstance(x, str) for x in argv):
        raise ValueError('Command argv must be a nonempty string list')
    absolute_path(argv[0])
    refs = config['source_refs']
    if len(refs) < 2:
        raise ValueError('Resource helper and guardian bindings are required')
    known = {(r['path'], r['bytes'], r['sha256']) for r in refs}
    for ref in plan.get('source_refs', []):
        if (ref['path'], ref['bytes'], ref['sha256']) not in known:
            raise ValueError('Command source is not guarded: ' + ref['path'])
    profile = config['profile']
    for name in ('memory_bytes', 'reserve_bytes', 'cpu_seconds', 'wall_seconds', 'max_tasks', 'disk_floor_bytes'):
        if type(profile[name]) is not int or profile[name] <= 0:
            raise ValueError('Invalid resource profile: ' + name)
    if not profile['cpus'] or any(type(c) is not int or c < 0 for c in profile['cpus']):
        raise ValueError('Invalid CPU set')
    # The watchdog prepends its selected interpreter. This is an argument tail.
    direct_cli = config.get('direct_cli', False)
    if type(direct_cli) is not bool:
        raise ValueError('direct_cli must be a boolean')
    inherited_child_nice(config)
    before = authenticate_sources(refs)
    if source_checks is not None:
        source_checks.append(before)
    request = [config['input_ref'], str(output)]
    if direct_cli:
        request.append(True)
    child = ['-B', '-c', WORKER, json.dumps(request)]
    return plan, output, runtime, child


def run(config):
    source_checks = []
    plan, output, runtime, child = prepare(config, source_checks=source_checks)
    refs = config['source_refs']
    profile = config['profile']
    sys.path.insert(0, str(absolute_path(refs[0]['path']).parent))
    import build_resource_limits as limits
    import build_watchdog_guardian as guardian
    if Path(limits.__file__).resolve() != absolute_path(refs[0]['path']):
        raise ValueError('Unexpected resource helper')
    if Path(guardian.__file__).resolve() != absolute_path(refs[1]['path']):
        raise ValueError('Unexpected guardian')
    runtime.mkdir()
    with (runtime / 'source-validation-before01.json').open('x') as stream:
        json.dump(source_checks[0], stream, indent=2, sort_keys=True)
        stream.write('\n')
    resource.setrlimit(resource.RLIMIT_CPU, (profile['cpu_seconds'], profile['cpu_seconds']))
    os.sched_setaffinity(0, set(profile['cpus']))
    child_nice = inherited_child_nice(config)
    if child_nice is None:
        os.nice(19)
        subprocess.run(['ionice', '-c2', '-n7', '-p', str(os.getpid())], check=True)
    policy = dict(admission_mem_available_bytes=profile['memory_bytes'] + profile['reserve_bytes'], admission_pressure_advisory=True, poll_seconds=0.2, runtime_termination_enabled=False, swap_counted_as_ram_headroom=True)
    host = limits.HostMemoryObservation(policy)
    sample = host.sample()
    fields = Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()
    start = dict(owner=dict(pid=os.getpid(), birth=int(fields[19])), started_unix=time.time(), sample=sample, policy=policy, input_authority=config['input_ref'], source_refs=refs, scope=plan['scope'], cap_bytes=profile['memory_bytes'], cpus=profile['cpus'], wall_seconds=profile['wall_seconds'], cpu_seconds=profile['cpu_seconds'])
    with (runtime / 'start.json').open('x') as stream:
        json.dump(start, stream, indent=2, sort_keys=True)
        stream.write('\n')
    encoded_refs = json.dumps(refs, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()
    console = {key: value for key, value in start.items() if key != 'source_refs'}
    console.update(source_ref_count=len(refs), source_refs_sha256=hashlib.sha256(encoded_refs).hexdigest(), source_receipt=str(runtime / 'start.json'))
    print('CHECK', json.dumps(console), flush=True)
    supervised_started = time.monotonic()
    code = limits.supervise_watchdog(argv=child, report_path=runtime / 'watchdog.json', wall_seconds=profile['wall_seconds'], memory_limit_bytes=profile['memory_bytes'], address_space_limit_bytes='unlimited', max_tasks=profile['max_tasks'], max_cpus=len(set(profile['cpus'])), disk_paths=[runtime], disk_floor_bytes=profile['disk_floor_bytes'], host_observation=host, child_nice=child_nice)
    after = authenticate_sources(refs)
    authenticate(config['input_ref'], capture=False)
    with (runtime / 'source-validation-after01.json').open('x') as stream:
        json.dump(after, stream, indent=2, sort_keys=True)
        stream.write('\n')
    if config.get('direct_cli', False):
        streams = {}
        for key in ('stdout', 'stderr'):
            path = output / ('tests.' + key)
            streams[key] = file_reference(path)
        with (output / 'result01.json').open('x') as stream:
            json.dump(dict(returncode=code, argv=plan['argv'], cwd=plan['cwd'], environment=plan['env'],
                           measurement_scope=plan['scope'], elapsed_seconds=time.monotonic() - supervised_started,
                           elapsed_scope='direct CLI and watchdog join', stdout=streams['stdout'], stderr=streams['stderr']), stream, indent=2)
            stream.write('\n')
    with (runtime / 'owner-result.json').open('x') as stream:
        json.dump(dict(returncode=code, finished_unix=time.time(), source_after=True), stream, indent=2)
        stream.write('\n')
    return code


def main(argv):
    # The caller binds config bytes, including all paths/profile/source refs.
    if len(argv) != 3:
        raise ValueError('Expected config path, byte count, and SHA-256')
    ref = dict(path=argv[0], bytes=int(argv[1]), sha256=argv[2])
    config = json.loads(authenticate(ref))
    code = run(config)
    authenticate(ref, capture=False)
    return code


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
