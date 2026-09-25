"""Resource envelopes for the corpus builder's entire process tree.

The default requires a delegated cgroup v2 subtree and kernel-enforced limits.
The explicit watchdog mode samples an owned process tree and is best effort.
Neither mode changes limits on an existing, possibly shared cgroup.
"""
import os
from pathlib import Path
import ctypes
import json
import resource
import signal
import subprocess
import sys
import time
import uuid

CGROUP_ROOT = Path('/sys/fs/cgroup')
SUPERVISOR_CHILD_RESERVE = 256 * 1024**2
MAX_BUILD_MEMORY = 8 * 1024**3
MAX_BUILD_PIDS = 256
CHILD_CGROUP = 'WIKIDICT_BUILD_CHILD_CGROUP'
PIDS_PARENT_RESERVE = 16
WATCHDOG_TOKEN = 'WIKIDICT_BUILD_WATCHDOG_TOKEN'
WATCHDOG_PARENT_PID = 'WIKIDICT_BUILD_WATCHDOG_PARENT_PID'
WATCHDOG_PROOF_FD = 'WIKIDICT_BUILD_WATCHDOG_PROOF_FD'
WATCHDOG_WALL_SECONDS = 2 * 60 * 60
WATCHDOG_POLL_SECONDS = 0.2
_verified_watchdog_pid = None


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


def _limits(parent, affinity_cpus, root=None, current=None):
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
    memory_limit = MAX_BUILD_MEMORY
    effective_cpus = affinity_cpus
    pids_headroom = MAX_BUILD_PIDS
    # A sibling build group will not inherit limits on the supervisor's leaf.
    # Use those limits as additional admission caps rather than escaping them.
    ancestor = current
    while True:
        memory_parent = _number(ancestor / 'memory.max')
        if memory_parent is not None:
            memory_limit = min(memory_limit, memory_parent)
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
    if memory_limit < 1536 * 1024**2 + SUPERVISOR_CHILD_RESERVE:
        raise ContainmentUnavailable('Insufficient inherited memory cap for a contained build')
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


def supervise(*, root=CGROUP_ROOT, argv=None, affinity_cpus=None):
    """Return child status, or raise before spawning if a hard limit is unavailable."""
    try:
        current = _self_cgroup(root)
        parent = _delegated_parent(current, root)
        if affinity_cpus is None:
            affinity_cpus = len(os.sched_getaffinity(0))
        limits = _limits(parent, affinity_cpus, root, current)
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


def inside_watchdog():
    """Validate a one-use parent proof and the child's private session."""
    global _verified_watchdog_pid
    if _verified_watchdog_pid == os.getpid():
        return True
    values = [os.environ.get(name) for name in
              (WATCHDOG_TOKEN, WATCHDOG_PARENT_PID, WATCHDOG_PROOF_FD)]
    if not any(values):
        return False
    if not all(values):
        raise ContainmentUnavailable('Incomplete watchdog child proof')
    fd = None
    try:
        token, parent, proof_fd = values
        fd = int(proof_fd)
        if not token or len(token) != 32 or os.getppid() != int(parent):
            raise ContainmentUnavailable('Invalid watchdog parent proof')
        if os.getsid(0) != os.getpid() or os.getpgrp() != os.getpid():
            raise ContainmentUnavailable('Watchdog child is outside its private session')
        proof = os.read(fd, 64)
        if proof != token.encode('ascii'):
            raise ContainmentUnavailable('Invalid watchdog child proof')
        _verified_watchdog_pid = os.getpid()
        return True
    except (OSError, ValueError, UnicodeError) as error:
        raise ContainmentUnavailable(f'Cannot verify watchdog child: {error}') from error
    finally:
        if fd is not None:
            try: os.close(fd)
            except OSError: pass


def _process_table():
    """Read process identity, parent, session, thread count, and RSS without ps."""
    table = {}
    page_bytes = os.sysconf('SC_PAGE_SIZE')
    for entry in os.scandir('/proc'):
        if not entry.name.isdigit():
            continue
        try:
            raw = Path(entry.path, 'stat').read_text()
            fields = raw[raw.rfind(')') + 2:].split()
            table[int(entry.name)] = {
                'state': fields[0], 'ppid': int(fields[1]), 'pgrp': int(fields[2]),
                'session': int(fields[3]), 'threads': int(fields[17]),
                'start': int(fields[19]), 'rss': int(fields[21]) * page_bytes,
            }
        except (FileNotFoundError, ProcessLookupError):
            continue
        except (OSError, ValueError, IndexError) as error:
            raise ContainmentUnavailable(f'Cannot inspect process {entry.name}: {error}') from error
    return table


def _owned_sample(child_pid, child_start, known, supervisor_pid, preexisting=frozenset()):
    table = _process_table()
    root = table.get(child_pid)
    if root is not None and root['start'] != child_start:
        raise ContainmentUnavailable('Watchdog child PID was reused')
    owned = {pid for pid, start in known.items()
             if pid in table and table[pid]['start'] == start}
    if root is not None:
        owned.add(child_pid)
    # Session members remain identifiable after their parent exits. Parent
    # links find descendants that changed process group or created a session.
    changed = True
    while changed:
        before = len(owned)
        owned.update(pid for pid, info in table.items()
                     if info['start'] >= child_start and
                     (info['session'] == child_pid or
                      info['ppid'] in owned or
                      (info['ppid'] == supervisor_pid and
                       (pid, info['start']) not in preexisting)))
        changed = len(owned) != before
    for pid in owned:
        known[pid] = table[pid]['start']
    pss = rss = tasks = 0
    live = {}
    for pid in owned:
        info = table[pid]
        if info['state'] == 'Z':
            continue
        try:
            lines = Path('/proc', str(pid), 'smaps_rollup').read_text().splitlines()
            pss_kib = next(int(line.split()[1]) for line in lines if line.startswith('Pss:'))
            status = Path('/proc', str(pid), 'status').read_text().splitlines()
            threads = next(int(line.split()[1]) for line in status if line.startswith('Threads:'))
        except (FileNotFoundError, ProcessLookupError):
            # A vanished process no longer consumes resources. A reused PID
            # must never be charged or signalled as our child.
            fresh = _process_table().get(pid)
            if fresh is not None and fresh['start'] == info['start'] and fresh['state'] != 'Z':
                raise ContainmentUnavailable(f'Owned process {pid} became unreadable')
            continue
        except (OSError, ValueError, StopIteration) as error:
            raise ContainmentUnavailable(f'Cannot measure owned process {pid}: {error}') from error
        pss += pss_kib * 1024
        rss += info['rss']
        tasks += threads
        live[pid] = info
    return {'pss_bytes': pss, 'rss_bytes': rss, 'tasks': tasks, 'live': live}


def _signal_owned(known, sig):
    """Pin each owned PID before signalling so reuse cannot hit another job."""
    for pid, start in tuple(known.items()):
        if pid == os.getpid():
            continue
        try:
            pidfd = os.pidfd_open(pid)
        except ProcessLookupError:
            continue
        try:
            raw = Path('/proc', str(pid), 'stat').read_text()
            fields = raw[raw.rfind(')') + 2:].split()
            if int(fields[19]) == start:
                signal.pidfd_send_signal(pidfd, sig)
        except (FileNotFoundError, ProcessLookupError):
            pass
        finally:
            os.close(pidfd)


def _write_watchdog_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.part')
    with temporary.open('w') as output:
        json.dump(report, output, sort_keys=True)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def supervise_watchdog(*, argv=None, report_path=None, wall_seconds=WATCHDOG_WALL_SECONDS,
                       memory_limit_bytes=MAX_BUILD_MEMORY, max_tasks=MAX_BUILD_PIDS):
    """Opt-in sampled fallback. Its aggregate cap is best effort, not a cgroup."""
    if not 0 < wall_seconds <= WATCHDOG_WALL_SECONDS:
        raise ContainmentUnavailable('Invalid watchdog wall limit')
    if not 0 < memory_limit_bytes <= MAX_BUILD_MEMORY or not 0 < max_tasks <= MAX_BUILD_PIDS:
        raise ContainmentUnavailable('Invalid watchdog resource limit')
    cpus = sorted(os.sched_getaffinity(0))[:4]
    if not cpus:
        raise ContainmentUnavailable('No available CPUs for watchdog child')
    report_path = Path('.tmp/build-watchdog-report.json') if report_path is None else Path(report_path)
    token = uuid.uuid4().hex
    proof_read, proof_write = os.pipe()
    child = None
    old_int = old_term = None
    old_mask = None
    signals_masked = False
    libc = ctypes.CDLL(None, use_errno=True)
    was_subreaper = ctypes.c_int()
    subreaper_set = False
    known = {}
    preexisting = frozenset()
    started = time.monotonic()
    report = {'mode': 'watchdog', 'aggregate_limit': 'sampled best effort, not kernel hard cap',
              'memory_limit_bytes': memory_limit_bytes, 'max_tasks': max_tasks,
              'wall_seconds': wall_seconds, 'peak_pss_bytes': 0,
              'peak_rss_bytes': 0, 'peak_tasks': 0, 'termination_reason': 'starting'}
    reason = None
    try:
        if libc.prctl(37, ctypes.byref(was_subreaper), 0, 0, 0) != 0 or \
           libc.prctl(36, 1, 0, 0, 0) != 0:
            raise ContainmentUnavailable('Cannot enable watchdog child reaping')
        subreaper_set = True
        os.write(proof_write, token.encode('ascii'))
        os.close(proof_write)
        proof_write = None
        env = os.environ.copy()
        env.update({WATCHDOG_TOKEN: token, WATCHDOG_PARENT_PID: str(os.getpid()),
                    WATCHDOG_PROOF_FD: str(proof_read)})
        preexisting = frozenset((pid, info['start']) for pid, info in _process_table().items()
                                if info['ppid'] == os.getpid())
        def child_setup():
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
            os.sched_setaffinity(0, cpus)
            os.nice(15)
            def bound_rlimit(name, requested):
                inherited_hard = resource.getrlimit(name)[1]
                bounded = requested if inherited_hard == resource.RLIM_INFINITY else min(requested, inherited_hard)
                resource.setrlimit(name, (bounded, bounded))
            bound_rlimit(resource.RLIMIT_AS, memory_limit_bytes)
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            bound_rlimit(resource.RLIMIT_NOFILE, 512)
            cpu_limit = max(1, min(WATCHDOG_WALL_SECONDS, int(wall_seconds)))
            bound_rlimit(resource.RLIMIT_CPU, cpu_limit)
        command = [sys.executable, *(sys.argv if argv is None else argv)]
        old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        signals_masked = True
        old_int = signal.signal(signal.SIGINT, _interrupt)
        old_term = signal.signal(signal.SIGTERM, _interrupt)
        child = subprocess.Popen(command, env=env, pass_fds=(proof_read,),
                                 start_new_session=True, preexec_fn=child_setup)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        signals_masked = False
        report['child_pid'] = child.pid
        os.close(proof_read)
        proof_read = None
        first = _process_table().get(child.pid)
        if first is None:
            raise ContainmentUnavailable('Cannot identify watchdog child')
        child_start = first['start']
        report['child_start_time_ticks'] = child_start
        known[child.pid] = child_start
        last_report = 0.0
        while True:
            sample = _owned_sample(child.pid, child_start, known, os.getpid(), preexisting)
            elapsed = time.monotonic() - started
            report['peak_pss_bytes'] = max(report['peak_pss_bytes'], sample['pss_bytes'])
            report['peak_rss_bytes'] = max(report['peak_rss_bytes'], sample['rss_bytes'])
            report['peak_tasks'] = max(report['peak_tasks'], sample['tasks'])
            report['elapsed_seconds'] = elapsed
            if sample['pss_bytes'] > memory_limit_bytes:
                reason = 'sampled_pss_limit'
            elif sample['tasks'] > max_tasks:
                reason = 'task_limit'
            elif elapsed >= wall_seconds:
                reason = 'wall_limit'
            status = child.poll()
            if status is not None:
                sample = _owned_sample(child.pid, child_start, known, os.getpid(), preexisting)
                if any(pid != child.pid for pid in sample['live']):
                    reason = reason or 'controller_exited_with_descendants'
                else:
                    reason = reason or 'child_exit'
            if elapsed - last_report >= 5 or reason:
                report['termination_reason'] = reason or 'running'
                _write_watchdog_report(report_path, report)
                last_report = elapsed
            if reason:
                break
            time.sleep(WATCHDOG_POLL_SECONDS)
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt,
            ContainmentUnavailable) as error:
        reason = 'monitor_error' if not isinstance(error, KeyboardInterrupt) else 'interrupted'
        report['error'] = str(error)
    finally:
        if old_int is not None:
            signal.signal(signal.SIGINT, signal.SIG_IGN)
        if old_term is not None:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if signals_masked:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        try:
            if child is not None:
                if reason != 'child_exit':
                    if child.pid in known:
                        try:
                            _signal_owned(known, signal.SIGTERM)
                            deadline = time.monotonic() + 1.0
                            while time.monotonic() < deadline:
                                try:
                                    if not _owned_sample(child.pid, known[child.pid], known,
                                                         os.getpid(), preexisting)['live']:
                                        break
                                except ContainmentUnavailable:
                                    break
                                time.sleep(0.05)
                        finally:
                            _signal_owned(known, signal.SIGKILL)
                    elif child.poll() is None:
                        # Popen still owns this unreaped PID, even if an early
                        # /proc race prevented capture of its start time.
                        child.kill()
                child.wait(timeout=2)
                # Drain adopted children before dropping subreaper ownership.
                if child.pid in known:
                    deadline = time.monotonic() + 2.0
                    while True:
                        remaining = _owned_sample(child.pid, known[child.pid], known,
                                                  os.getpid(), preexisting)['live']
                        for pid in tuple(known):
                            if pid != child.pid:
                                try: os.waitpid(pid, os.WNOHANG)
                                except ChildProcessError: pass
                        if not remaining:
                            break
                        if time.monotonic() >= deadline:
                            raise ContainmentUnavailable('Owned watchdog descendants did not exit')
                        _signal_owned(known, signal.SIGKILL)
                        time.sleep(0.05)
            report['child_exit_status'] = child.returncode if child is not None else None
        except (OSError, ValueError, subprocess.SubprocessError, ContainmentUnavailable) as error:
            reason = 'cleanup_error'
            report['error'] = str(error)
        finally:
            for fd in (proof_read, proof_write):
                if fd is not None:
                    try: os.close(fd)
                    except OSError: pass
            if subreaper_set:
                libc.prctl(36, was_subreaper.value, 0, 0, 0)
            if old_int is not None:
                signal.signal(signal.SIGINT, old_int)
            if old_term is not None:
                signal.signal(signal.SIGTERM, old_term)
            report['elapsed_seconds'] = time.monotonic() - started
            report['termination_reason'] = reason or 'monitor_error'
            _write_watchdog_report(report_path, report)
    if reason != 'child_exit':
        raise ContainmentUnavailable(f'Watchdog stopped build: {reason}; see {report_path}')
    return child.returncode


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
