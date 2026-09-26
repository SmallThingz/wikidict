#!/usr/bin/env python3
"""Independent, best-effort cleanup observer for one watchdog child session.

The watchdog starts this as a single detached process before its build child.
Only one verified private session may be signalled; no shared cgroup is touched.
"""
import argparse
import json
import os
from pathlib import Path
import resource
import select
import signal
import time


def process(pid):
    raw = (Path('/proc') / str(pid) / 'stat').read_text()
    fields = raw[raw.rfind(')') + 2:].split()
    return {
        'pid': pid, 'state': fields[0], 'ppid': int(fields[1]),
        'pgrp': int(fields[2]), 'session': int(fields[3]),
        'start': int(fields[19]),
    }


def same_process(pid, start):
    try:
        return process(pid)['start'] == start
    except (FileNotFoundError, ProcessLookupError):
        return False


def owned_members(root_pid, root_start, known):
    """Keep exact descendants, including a child observed after setsid()."""
    table = {}
    for entry in os.scandir('/proc'):
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        try:
            item = process(pid)
        except (FileNotFoundError, ProcessLookupError):
            continue
        table[pid] = item
    found = {pid for pid, start in known.items()
             if pid in table and table[pid]['start'] == start}
    changed = True
    while changed:
        before = len(found)
        found.update(pid for pid, item in table.items()
                     if item['start'] >= root_start and
                     (item['session'] == root_pid or item['ppid'] in found))
        changed = len(found) != before
    for pid in found:
        known[pid] = table[pid]['start']
    return {pid: table[pid]['start'] for pid in found
            if table[pid]['state'] not in ('Z', 'X')}


def signal_exact(pid, start, signum):
    try:
        fd = os.pidfd_open(pid)
    except (FileNotFoundError, ProcessLookupError):
        return False
    try:
        if same_process(pid, start):
            try:
                signal.pidfd_send_signal(fd, signum)
                return True
            except ProcessLookupError:
                return False
    finally:
        os.close(fd)
    return False


def report(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.part')
    with temporary.open('w') as output:
        json.dump(payload, output, sort_keys=True)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


def read_identity(fd, supervisor_pid, deadline):
    raw = b''
    while len(raw) < 128 and time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            continue
        piece = os.read(fd, 128 - len(raw))
        if not piece:
            return None
        raw += piece
        if b'\n' in raw:
            pid_text, start_text = raw.split(b'\n', 1)[0].split(b' ')
            pid, start = int(pid_text), int(start_text)
            item = process(pid)
            if (item['start'] != start or item['ppid'] != supervisor_pid or
                    item['pgrp'] != pid or item['session'] != pid):
                raise RuntimeError('Build session identity differs at guardian handshake')
            return pid, start
    raise RuntimeError('Guardian did not receive one bounded build identity')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--supervisor-pid', type=int, required=True)
    parser.add_argument('--supervisor-start', type=int, required=True)
    parser.add_argument('--liveness-fd', type=int, required=True)
    parser.add_argument('--identity-fd', type=int, required=True)
    parser.add_argument('--identity-ack-fd', type=int, required=True)
    parser.add_argument('--wall-seconds', type=int, required=True)
    parser.add_argument('--observer-cpu', type=int, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.wall_seconds <= 7200:
        raise ValueError('Guardian wall bound must be 1..7200 seconds')
    if not all(hasattr(os, name) for name in ('pidfd_open',)) or not hasattr(signal, 'pidfd_send_signal'):
        raise RuntimeError('pidfd signalling is required for owned cleanup')
    os.sched_setaffinity(0, {args.observer_cpu})
    os.nice(15)
    for which, limit in ((resource.RLIMIT_AS, 192 * 1024**2),
                         (resource.RLIMIT_CPU, 600),
                         (resource.RLIMIT_NOFILE, 64),
                         (resource.RLIMIT_CORE, 0)):
        hard = resource.getrlimit(which)[1]
        value = limit if hard == resource.RLIM_INFINITY else min(limit, hard)
        resource.setrlimit(which, (value, value))
    started = time.monotonic()
    record = {'supervisor_pid': args.supervisor_pid,
              'supervisor_start': args.supervisor_start,
              'guardian_pid': os.getpid(), 'status': 'waiting_for_child'}
    root = read_identity(args.identity_fd, args.supervisor_pid, started + 15)
    os.close(args.identity_fd)
    if root is None:
        os.close(args.identity_ack_fd)
        record['status'] = 'no_child_started'
        report(args.report, record)
        return
    root_pid, root_start = root
    record.update(root_pid=root_pid, root_start=root_start, status='observing')
    report(args.report, record)
    os.write(args.identity_ack_fd, b'1')
    os.close(args.identity_ack_fd)
    known = {root_pid: root_start}
    reason = None
    liveness = b''
    while reason is None:
        owned_members(root_pid, root_start, known)
        if not same_process(args.supervisor_pid, args.supervisor_start):
            reason = 'supervisor_lost'
            break
        if time.monotonic() - started > args.wall_seconds + 30:
            reason = 'independent_wall_limit'
            break
        ready, _, _ = select.select([args.liveness_fd], [], [], 0.2)
        if ready:
            piece = os.read(args.liveness_fd, 16)
            if not piece:
                reason = 'supervisor_liveness_pipe_closed'
            else:
                liveness += piece
                if len(liveness) > 16:
                    reason = 'invalid_liveness_message'
                elif b'\n' in liveness:
                    reason = 'normal_done' if liveness == b'DONE\n' else 'invalid_liveness_message'
    os.close(args.liveness_fd)
    record['reason'] = reason
    if reason == 'normal_done' and not owned_members(root_pid, root_start, known):
        record['status'] = 'disarmed'
        record['tracked_processes'] = len(known)
        report(args.report, record)
        return
    record['status'] = 'cleanup'
    signalled = {}
    for signum, duration in ((signal.SIGTERM, 1.0), (signal.SIGKILL, 2.0)):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            members = owned_members(root_pid, root_start, known)
            if not members:
                record['status'] = 'owned_session_gone'
                record['tracked_processes'] = len(known)
                record['signalled'] = signalled
                report(args.report, record)
                return
            for pid, start in members.items():
                if signal_exact(pid, start, signum):
                    signalled[str(pid)] = {'start': start, 'last_signal': signal.Signals(signum).name}
            time.sleep(0.05)
    record['status'] = 'cleanup_incomplete'
    record['remaining'] = owned_members(root_pid, root_start, known)
    record['signalled'] = signalled
    report(args.report, record)
    raise RuntimeError('Guardian could not reap verified private session')


if __name__ == '__main__':
    main()
