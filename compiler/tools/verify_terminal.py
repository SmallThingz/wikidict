#!/usr/bin/env python3
"""Exercise the real TUI through a PTY and a VT emulator (uv run --with pyte)."""
import argparse
import codecs
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import termios
import time
import pyte


def run(args):
    args.report.mkdir(parents=True, exist_ok=True)
    text = subprocess.run([str(args.binary), 'lookup', 'cat', '--root', str(args.root), '--details'],
                          capture_output=True, check=True, timeout=30).stdout.decode()
    for token in ['PREAMBLE', 'column A  column B\n  indented\tvalue', 'Inflection table', 'Reference content.', 'Example pronunciation.ogg']:
        assert token in text, token
    (args.report / 'cli.txt').write_text(text)
    outcomes = []
    for columns, rows in [(40, 20), (80, 24), (120, 40)]:
        master, slave = pty.openpty()
        termios.tcsetwinsize(slave, (rows, columns))
        child = subprocess.Popen([str(args.binary), 'tui', 'cat', '--root', str(args.root), '--details'],
                                 stdin=slave, stdout=slave, stderr=slave, env={**os.environ, 'TERM':'xterm-256color', 'LANG':'C.UTF-8'}, start_new_session=True)
        os.close(slave)
        screen = pyte.Screen(columns, rows)
        stream = pyte.Stream(screen)
        decoder = codecs.getincrementaldecoder('utf-8')('replace')
        raw = bytearray()
        def read_for(seconds):
            until = time.monotonic() + seconds
            while time.monotonic() < until:
                if select.select([master], [], [], min(.1, max(0, until-time.monotonic())))[0]:
                    try: data = os.read(master, 65536)
                    except OSError: break
                    if not data: break
                    raw.extend(data)
                    stream.feed(decoder.decode(data))
        def snapshot(name):
            (args.report / f'{columns}-{name}.txt').write_text('\n'.join(screen.display)+'\n')
            assert '\ufffd' not in '\n'.join(screen.display), 'broken UTF-8'
        try:
            read_for(1)
            assert child.poll() is None, 'TUI exited early'
            os.write(master, b'\t\t')
            read_for(.25)
            snapshot('reading')
            assert 'READING' in '\n'.join(screen.display), 'no reading pane'
            os.write(master, b'\x1b[6~\x1b[6~')
            read_for(.25)
            snapshot('scrolled')
            os.write(master, b'/\x15' + '猫👩🏽‍💻'.encode())
            read_for(.2)
            os.write(master, b'\x7f\x7fcat')
            read_for(.3)
            snapshot('unicode-edit')
            # Resize an active terminal, then force a normal input event.
            termios.tcsetwinsize(master, (rows + 2, columns + 4))
            screen.resize(rows + 2, columns + 4)
            os.kill(child.pid, signal.SIGWINCH)
            os.write(master, b'\t')
            read_for(.25)
            snapshot('resize')
            os.write(master, b'\x03')
            child.wait(timeout=5)
            assert child.returncode == 0, child.returncode
            outcomes.append(dict(columns=columns, rows=rows, status='passed'))
        finally:
            if child.poll() is None:
                child.kill(); child.wait()
            os.close(master)
            (args.report / f'{columns}.ansi').write_bytes(raw)
    (args.report / 'report.json').write_text(json.dumps(dict(status='passed', cases=outcomes), indent=2)+'\n')
    print('TERMINAL_RENDERER_PASS', json.dumps(outcomes))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('binary','root','report'): p.add_argument('--'+name,type=Path,required=True)
    args = p.parse_args()
    args.binary = args.binary.resolve()
    run(args)
