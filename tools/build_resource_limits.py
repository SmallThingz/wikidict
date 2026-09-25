"""Kernel-enforced resource envelope for the corpus builder's entire process tree.

The caller must already have a delegated cgroup v2 subtree. This module never
enables controllers or changes limits on an existing (possibly shared) cgroup.
"""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

CGROUP_ROOT = Path('/sys/fs/cgroup')
MEMORY_RESERVE = 2 * 1024**3
SUPERVISOR_CHILD_RESERVE = 256 * 1024**2
MAX_BUILD_MEMORY = 8 * 1536 * 1024**2 + SUPERVISOR_CHILD_RESERVE
MAX_BUILD_PIDS = 256
CHILD_CGROUP = 'WIKIDICT_BUILD_CHILD_CGROUP'
PIDS_PARENT_RESERVE = 16


class ContainmentUnavailable(RuntimeError):
    pass


def _number(path):
    value = path.read_text().strip()
    if value == 'max':
        return None
    result = int(value)
    if result < 0:
        raise ValueError(f'Negative cgroup limit: {path}')
    return result


def _self_cgroup(root=CGROUP_ROOT):
    lines = Path('/proc/self/cgroup').read_text().splitlines()
    paths = [line[3:] for line in lines if line.startswith('0::')]
    if len(paths) != 1 or not paths[0].startswith('/') or '..' in Path(paths[0]).parts:
        raise ContainmentUnavailable('Cannot identify current cgroup v2')
    relative = paths[0].lstrip('/')
    candidate = root / relative
    if (candidate / 'cgroup.procs').is_file():
        return candidate
    # A cgroup namespace may mount the current cgroup as its root.
    if (root / 'cgroup.procs').is_file() and paths[0] == '/':
        return root
    raise ContainmentUnavailable('Current cgroup is not visible in the cgroup v2 mount')


def _limits(parent, available_bytes, affinity_cpus, root=None, current=None):
    if root is None:
        root = parent
    if parent != root and root not in parent.parents:
        raise ContainmentUnavailable('Current cgroup is outside the mounted hierarchy')
    if current is None:
        current = parent
    if current != parent and parent not in current.parents:
        raise ContainmentUnavailable('Supervisor cgroup is outside the delegated subtree')
    required = {'cpu', 'memory', 'pids'}
    enabled = set((parent / 'cgroup.subtree_control').read_text().split())
    if not required <= enabled:
        raise ContainmentUnavailable('A delegated cgroup with cpu, memory and pids controllers is required')
    memory_headroom = available_bytes - MEMORY_RESERVE
    effective_cpus = affinity_cpus
    pids_headroom = MAX_BUILD_PIDS
    # A sibling build group will not inherit limits on the supervisor's leaf.
    # Use those limits as additional admission caps rather than escaping them.
    ancestor = current
    while True:
        memory_parent = _number(ancestor / 'memory.max')
        memory_used = int((ancestor / 'memory.current').read_text())
        if memory_parent is not None:
            memory_headroom = min(memory_headroom, memory_parent - memory_used - MEMORY_RESERVE)
        cpu_tokens = (ancestor / 'cpu.max').read_text().split()
        if len(cpu_tokens) != 2:
            raise ContainmentUnavailable('Cannot determine ancestor cgroup CPU quota')
        quota, period = cpu_tokens
        period = int(period)
        if period <= 0:
            raise ContainmentUnavailable('Cannot determine effective CPU capacity')
        if quota != 'max':
            effective_cpus = min(effective_cpus, int(quota) / period)
        pids_parent = _number(ancestor / 'pids.max')
        pids_used = int((ancestor / 'pids.current').read_text())
        if pids_parent is not None:
            pids_headroom = min(pids_headroom, pids_parent - pids_used - PIDS_PARENT_RESERVE)
        if ancestor == root:
            break
        ancestor = ancestor.parent
    memory_limit = min(MAX_BUILD_MEMORY, memory_headroom)
    if memory_limit < 1536 * 1024**2 + SUPERVISOR_CHILD_RESERVE:
        raise ContainmentUnavailable('Insufficient memory headroom for a contained build')
    if affinity_cpus < 1:
        raise ContainmentUnavailable('Cannot determine effective CPU capacity')
    cpu_quota = int(effective_cpus * 0.75 * 100000)
    if cpu_quota < 25000:
        raise ContainmentUnavailable('Insufficient CPU quota for a contained build')
    pids_limit = pids_headroom
    if pids_limit < 32:
        raise ContainmentUnavailable('Insufficient process slots for a contained build')
    if not (parent / 'cgroup.procs').is_file():
        raise ContainmentUnavailable('Current cgroup does not expose cgroup.procs')
    return {'memory.max': str(memory_limit), 'memory.swap.max': '0',
            'cpu.max': f'{cpu_quota} 100000', 'pids.max': str(pids_limit),
            'memory.oom.group': '1'}


def _delegated_parent(current, root):
    """Find an already-enabled writable ancestor; the supervisor stays in its leaf."""
    if current != root and root not in current.parents:
        raise ContainmentUnavailable('Current cgroup is outside the mounted hierarchy')
    required = {'cpu', 'memory', 'pids'}
    ancestor = current
    while True:
        if required <= set((ancestor / 'cgroup.subtree_control').read_text().split()) \
                and os.access(ancestor, os.W_OK):
            return ancestor
        if ancestor == root:
            break
        ancestor = ancestor.parent
    raise ContainmentUnavailable('A writable delegated cgroup with cpu, memory and pids controllers is required')


def _cleanup(group):
    events = dict(line.split() for line in (group / 'cgroup.events').read_text().splitlines())
    if events.get('populated') == '1':
        (group / 'cgroup.kill').write_text('1')
    for _ in range(40):
        if (group / 'cgroup.events').read_text().find('populated 0') >= 0:
            group.rmdir()
            return
        time.sleep(0.05)
    raise ContainmentUnavailable(f'Private build cgroup did not empty: {group}')


def _interrupt(signum, _frame):
    raise KeyboardInterrupt(f'Build supervisor interrupted by signal {signum}')


def child_memory_limit_bytes():
    """Return the verified child's aggregate memory cap, or None outside it."""
    marker = os.environ.get(CHILD_CGROUP)
    if not marker:
        return None
    return _number(Path(marker) / 'memory.max')


def supervise(available_bytes, *, root=CGROUP_ROOT, argv=None, affinity_cpus=None):
    """Return child status, or raise before spawning if a hard limit is unavailable."""
    try:
        current = _self_cgroup(root)
        parent = _delegated_parent(current, root)
        if affinity_cpus is None:
            affinity_cpus = len(os.sched_getaffinity(0))
        limits = _limits(parent, available_bytes, affinity_cpus, root, current)
        group = parent / ('wikidict-build-' + uuid.uuid4().hex)
        group.mkdir(mode=0o700)
        status = None
        child = None
        old_int = old_term = None
        try:
            for name, value in limits.items():
                (group / name).write_text(value)
            if not os.access(group / 'cgroup.procs', os.W_OK) or not os.access(group / 'cgroup.kill', os.W_OK):
                raise ContainmentUnavailable('Delegated cgroup cannot join or reap its build children')
            env = os.environ.copy()
            env[CHILD_CGROUP] = str(group)
            command = [sys.executable, *(sys.argv if argv is None else argv)]

            def enter_cgroup():
                # Runs in the child before exec: every Zig and xz descendant inherits it.
                (group / 'cgroup.procs').write_text(str(os.getpid()))

            old_int = signal.signal(signal.SIGINT, _interrupt)
            old_term = signal.signal(signal.SIGTERM, _interrupt)
            child = subprocess.Popen(command, env=env, preexec_fn=enter_cgroup)
            status = child.wait()
        finally:
            if old_int is not None:
                signal.signal(signal.SIGINT, signal.SIG_IGN)
            if old_term is not None:
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            try:
                _cleanup(group)
                if child is not None and status is None:
                    child.wait(timeout=2)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                raise ContainmentUnavailable(f'Could not reap private build cgroup (child exit status {status}): {error}') from error
            finally:
                if old_int is not None:
                    signal.signal(signal.SIGINT, old_int)
                if old_term is not None:
                    signal.signal(signal.SIGTERM, old_term)
        return status
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise ContainmentUnavailable(f'Cannot enforce build process-tree limits: {error}') from error


def inside_envelope(root=CGROUP_ROOT):
    """Check the re-executed builder is in its private, bounded cgroup."""
    marker = os.environ.get(CHILD_CGROUP)
    if not marker:
        return False
    try:
        current = _self_cgroup(root)
        if not current.samefile(marker) or not current.name.startswith('wikidict-build-'):
            raise ContainmentUnavailable('Build child did not enter its private cgroup')
        for name in ('memory.max', 'memory.swap.max', 'pids.max'):
            value = _number(current / name)
            if value is None or (name == 'memory.swap.max' and value != 0):
                raise ContainmentUnavailable(f'Build cgroup has no safe {name} limit')
            if name == 'memory.max' and not 0 < value <= MAX_BUILD_MEMORY:
                raise ContainmentUnavailable('Build memory cap exceeds the supported maximum')
            if name == 'pids.max' and not 0 < value <= MAX_BUILD_PIDS:
                raise ContainmentUnavailable('Build process cap exceeds the supported maximum')
        cpu = (current / 'cpu.max').read_text().split()
        if len(cpu) != 2 or cpu[0] == 'max' or int(cpu[0]) <= 0 or int(cpu[1]) <= 0:
            raise ContainmentUnavailable('Build cgroup has no CPU quota')
        if int(cpu[0]) / int(cpu[1]) > len(os.sched_getaffinity(0)) * 0.75:
            raise ContainmentUnavailable('Build CPU quota exceeds the supported maximum')
    except (OSError, ValueError) as error:
        raise ContainmentUnavailable(f'Cannot verify build cgroup: {error}') from error
    return True
