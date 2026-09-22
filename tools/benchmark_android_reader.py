#!/usr/bin/env python3
"""Bounded on-device scroll smoke test. Never changes power/lock settings."""
import argparse, json, re, subprocess, time
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('--adb', default='adb')
p.add_argument('--report', type=Path, required=True)
p.add_argument('--variant', choices=['debug', 'performance'], default='debug')
p.add_argument('--uri', default='file:///data/user/0/app.smallthingz.dict/files/corpus-cat.json')
a = p.parse_args()
a.report.mkdir(parents=True, exist_ok=True)
def adb(*args):
    return subprocess.check_output([a.adb, *args], timeout=60)
adb('shell','am','start','-S','-W','-n','app.smallthingz.dict/.MainActivity','-a','android.intent.action.VIEW','-d',a.uri,'--activity-clear-task')
time.sleep(3)
(a.report/'start.png').write_bytes(adb('exec-out','screencap','-p'))
adb('shell','uiautomator','dump','/data/local/tmp/dict-reader-benchmark.xml')
ui = adb('shell','cat','/data/local/tmp/dict-reader-benchmark.xml').decode()
if 'package="app.smallthingz.dict"' not in ui or 'text="cat"' not in ui:
    raise RuntimeError('Reader is not visible at cat; unlock/foreground it before benchmarking')
size = adb('shell','wm','size').decode()
w,h = map(int, re.findall(r'(\d+)x(\d+)', size)[-1])
adb('shell','dumpsys','gfxinfo','app.smallthingz.dict','reset')
start = time.monotonic()
# Repeated swipes include dense linked lists further down the entry.
for reverse in [False, True]:
    for _ in range(12):
        y1,y2 = (int(h*.78),int(h*.28))
        if reverse: y1,y2 = y2,y1
        adb('shell','input','swipe',str(w//2),str(y1),str(w//2),str(y2),'400')
raw = adb('shell','dumpsys','gfxinfo','app.smallthingz.dict','framestats').decode()
(a.report/'gfx.txt').write_text(raw)
(a.report/'end.png').write_bytes(adb('exec-out','screencap','-p'))
def match(pattern):
    m = re.search(pattern,raw)
    return m.group(1) if m else None
result = dict(workload='cat export; 12 forward + 12 backward swipes, 400 ms', variant=a.variant, seconds=time.monotonic()-start,
              frames=match(r'Total frames rendered: (\d+)'), janky=match(r'Janky frames: (\d+)'),
              janky_percent=match(r'Janky frames: \d+ \(([\d.]+)%\)'),
              p50_ms=match(r'50th percentile: (\d+)ms'),p95_ms=match(r'95th percentile: (\d+)ms'),p99_ms=match(r'99th percentile: (\d+)ms'))
if not result['frames'] or int(result['frames']) == 0: raise RuntimeError('No measured frames')
(a.report/'report.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
