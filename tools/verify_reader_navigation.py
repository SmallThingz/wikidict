#!/usr/bin/env python3
"""PTY acceptance for navigation, folds, games, persistence and narrow layouts."""
import argparse,codecs,json,os,pty,select,shutil,signal,subprocess,tempfile,termios,time
from pathlib import Path
from verify_reader_ux import OwnedReaderProcess, copy_fixture, require


class ReaderCleanupError(RuntimeError):
    """The direct child could not be reaped; retain its private fixture."""


def stop_reader(child, owned):
    if child.poll() is not None:
        return
    if owned is None:
        raise ReaderCleanupError("Reader ownership was not captured; no signal sent")
    try:
        for signum in (signal.SIGTERM, signal.SIGKILL):
            # The shared helper checks birth, parent, session and UID, then uses
            # the held pidfd. A refused identity never falls back to kill(pid).
            owned.send(signum)
            try:
                child.wait(timeout=1)
                return
            except subprocess.TimeoutExpired:
                pass
    except OSError as error:
        if child.poll() is None:
            raise ReaderCleanupError("Reader cleanup failed; private fixture retained") from error
        return
    raise ReaderCleanupError("Reader remains unreaped; private fixture retained")


def reader_environment(root):
    env = dict(os.environ, DICT_ROOT=str(root), TERM="xterm-256color")
    for name, directory in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                            ("XDG_DATA_HOME", "data"), ("XDG_CACHE_HOME", "cache"),
                            ("XDG_STATE_HOME", "state"), ("XDG_RUNTIME_DIR", "runtime")):
        target = root.parent / directory
        target.mkdir(mode=0o700)
        env[name] = str(target)
    return env


def run_owned(binary,root,report,cols,rows):
    import pyte
    screen=pyte.Screen(cols,rows);stream=pyte.Stream(screen);decoder=codecs.getincrementaldecoder('utf-8')('replace')
    env = reader_environment(root)
    master,slave=pty.openpty()
    child = owned = None
    def read(seconds=.25):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            if select.select([master],[],[],.05)[0]:
                try:data=os.read(master,65536)
                except OSError:break
                if not data:break
                stream.feed(decoder.decode(data))
    def send(data):os.write(master,data);read()
    def text():return '\n'.join(screen.display)
    def expect(value):assert value in text(),(value,text())
    try:
        termios.tcsetwinsize(slave,(rows,cols))
        child=subprocess.Popen([str(binary),'tui','elephant','--root',str(root),'--color','always'],stdin=slave,stdout=slave,stderr=slave,cwd=root,env=env,start_new_session=True)
        owned = OwnedReaderProcess(child.pid)
        os.close(slave);slave=None
        read(1);assert child.poll() is None
        send(b'\r');expect('elephant');expect('Noun');expect('[+]')
        (report/f'{cols}-reading.txt').write_text(text())
        send(b's');send(b'1');expect('Saved');expect('elephant')
        send(b'2');expect('history');expect('elephant')
        send(b'5');expect('Settings');send(b'\x1b[B\x1b[B\x1b[C');expect('200')
        (report/f'{cols}-settings.txt').write_text(text())
        send(b'4');expect('Recall the meaning');send(b' ');send(b'y');expect('Recall the meaning')
        send(b'\t');expect('quiz');expect('6 ');send(b'6');send(b' ')
        send(b'\t');expect('Your answer:');send(b'notcorrect\r');send(b' ')
        (report/f'{cols}-learn.txt').write_text(text())
        send(b'\x03');child.wait(timeout=5);assert child.returncode==0
    finally:
        try:
            if child is not None:
                stop_reader(child, owned)
        finally:
            try:
                if owned is not None:
                    owned.close()
            finally:
                os.close(master)
                if slave is not None:
                    os.close(slave)


def run(binary,root,report,cols,rows):
    binary, source, report = Path(binary).resolve(strict=True), Path(root).resolve(strict=True), Path(report).resolve()
    require(binary.is_file() and os.access(binary, os.X_OK), "--binary is not executable")
    require((source / ".reader-fixture").is_file(), "Refusing an unmarked fixture root")
    require(report != source and source not in report.parents,
            "Report directory must be outside the original fixture")
    require(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"),
            "pidfd signaling is required for Reader ownership")
    report.mkdir(parents=True, exist_ok=True)
    owned = Path(tempfile.mkdtemp(prefix=f"navigation-{cols}-", dir=report))
    disposable = owned / "root"
    cleanup = True
    try:
        copy_fixture(source, disposable)
        run_owned(binary, disposable, report, cols, rows)
        files=list((disposable/'.dict-state').glob('*.json'));assert files
        state=json.loads(files[0].read_text());assert 'elephant' in state['saved'];assert state['history_limit']==200
    except ReaderCleanupError as error:
        cleanup = False
        raise ReaderCleanupError(f"{error}; retained at {owned}") from error
    finally:
        if cleanup:
            shutil.rmtree(owned)


def main(argv=None):
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--root',type=Path,required=True);p.add_argument('--report',type=Path,required=True);a=p.parse_args(argv)
    for cols,rows in [(40,24),(80,30),(120,40)]:
        # Each size starts with defaults while exercising save-on-exit.
        run(a.binary,a.root,a.report,cols,rows)
    print('TERMINAL_NAVIGATION_PASS widths=40,80,120 persistence=true')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
