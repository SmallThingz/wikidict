"""Drive the opt-in MainWindowTest slot using one native reader per scan."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time


@contextmanager
def layout_session(test, *, temporary_root=None, observe_process=None):
    test = Path(test).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='qt-layout-', dir=temporary_root) as directory:
        private = Path(directory)
        env = dict(os.environ, QT_QPA_PLATFORM='offscreen', XDG_RUNTIME_DIR=directory)
        for key, child in [('XDG_CONFIG_HOME', 'config'), ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data')]:
            env[key] = str(private / child)
        read_fd, write_fd = os.pipe()
        env['WIKIDICT_LAYOUT_AUDIT_FD'] = str(write_fd)
        try:
            process = subprocess.Popen([str(test), 'auditExportedEntryLayouts', '-maxwarnings', '25'],
                cwd=private, env=env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, pass_fds=(write_fd,))
        except BaseException:
            os.close(read_fd)
            raise
        finally:
            os.close(write_fd)
        data = bytearray()
        def response(where):
            until = time.monotonic() + 120
            while b'\n' not in data:
                if not select.select([read_fd], [], [], max(0, until - time.monotonic()))[0]:
                    raise ValueError(f'Qt layout timeout at {where}')
                chunk = os.read(read_fd, 16384)
                if not chunk or len(data) + len(chunk) > (1 << 20):
                    raise ValueError(f'Qt layout response missing or oversized at {where}')
                data.extend(chunk)
            line, _, tail = data.partition(b'\n')
            data[:] = tail
            return json.loads(line)
        count = 0
        try:
            ready = response('startup')
            if ready.get('ready') is not True or ready['viewport'] < 1:
                raise ValueError('Qt layout reader not ready')
            if observe_process is not None:
                observe_process(process.pid)
            # Bind the executable and actual Qt, platform plugin and application libraries.
            mapped = {test}
            for line in Path('/proc', str(process.pid), 'maps').read_text().splitlines():
                fields = line.split(maxsplit=5)
                if len(fields) == 6 and fields[5].startswith('/'):
                    path = Path(fields[5])
                    if path.name.startswith(('libQt6', 'libqoffscreen', 'libdictffi', 'libwikidict')):
                        mapped.add(path.resolve(strict=True))
            def fingerprint(path):
                with path.open('rb') as stream:
                    return hashlib.file_digest(stream, 'sha256').hexdigest()
            runtime = {str(p): fingerprint(p) for p in sorted(mapped)}
            def inspect(entry):
                nonlocal count
                title = entry['title']
                where = (entry['kind'], entry.get('language'), title)
                try:
                    process.stdin.write(json.dumps(entry, ensure_ascii=False, separators=(',', ':')).encode() + b'\n')
                    process.stdin.flush()
                    row = response(where)
                except (BrokenPipeError, OSError, ValueError) as error:
                    raise ValueError(f'Qt layout of {where!r} incomplete: {error}') from error
                if row.get('ordinal') != count or row.get('title') != title or not isinstance(row.get('error'), str):
                    raise ValueError(f'Unbound Qt layout reply for {where!r}')
                count += 1
                return row
            yield inspect, {'runtime_sha256': runtime, 'viewport': ready['viewport'],
                            'geometry': 'expanded offline Qt Reading view, 640x650 window',
                            'action_scope': 'exposed native accessibility links, ranges and press actions',
                            'visual_fidelity_assessed': False}
            process.stdin.close()
            if response('completion') != {'finished': count} or process.wait(timeout=15) != 0:
                raise ValueError('Qt layout session did not finish')
            if any(fingerprint(Path(name)) != digest for name, digest in runtime.items()):
                raise ValueError('Qt layout runtime changed during audit')
        finally:
            os.close(read_fd)
            if not process.stdin.closed:
                process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # Popen still owns this unreaped direct child. No group signal.
                process.kill()
                process.wait()
