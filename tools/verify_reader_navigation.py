#!/usr/bin/env python3
"""PTY acceptance for navigation, folds, games, persistence and narrow layouts."""
import argparse,codecs,os,pty,select,subprocess,termios,time
from pathlib import Path
import pyte

def run(binary,root,report,cols,rows):
    master,slave=pty.openpty();termios.tcsetwinsize(slave,(rows,cols))
    child=subprocess.Popen([str(binary),'tui','elephant','--root',str(root),'--color','always'],stdin=slave,stdout=slave,stderr=slave,env={**os.environ,'TERM':'xterm-256color'},start_new_session=True);os.close(slave)
    screen=pyte.Screen(cols,rows);stream=pyte.Stream(screen);decoder=codecs.getincrementaldecoder('utf-8')('replace')
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
        if child.poll() is None:child.kill();child.wait()
        os.close(master)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--root',type=Path,required=True);p.add_argument('--report',type=Path,required=True);a=p.parse_args();a.report.mkdir(parents=True,exist_ok=True)
    for cols,rows in [(40,24),(80,30),(120,40)]:
        # Each size starts with defaults while exercising save-on-exit.
        import shutil
        shutil.rmtree(a.root/'.dict-state',ignore_errors=True)
        run(a.binary.resolve(),a.root.resolve(),a.report,cols,rows)
        import json
        files=list((a.root/'.dict-state').glob('*.json'));assert files
        state=json.loads(files[0].read_text());assert 'elephant' in state['saved'];assert state['history_limit']==200
    print('TERMINAL_NAVIGATION_PASS widths=40,80,120 persistence=true')
