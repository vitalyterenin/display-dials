#!/usr/bin/env python3
"""Default checks never create display windows. --live tests ONLY the tiny HDR marker.

Run after `swift build`. Live checks cover EOF, missed heartbeat, SIGKILL, and TTL;
they do not verify absolute luminance, colors, thermal behavior, or fullscreen Spaces.
"""
import argparse
import json
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', action='store_true')
args = parser.parse_args()
binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()) / 'DisplayDials'


def check_no_windows(payload, expected):
    result = subprocess.run([str(binary), '--boost-worker'], input=payload,
                            capture_output=True, text=True, timeout=5, check=True)
    report = json.loads(result.stdout.strip().splitlines()[-1])
    assert report['phase'] == 'off' and report['reason'] == expected, report


check_no_windows('', 'heartbeat')
check_no_windows('not json\n', 'invalidInput')
check_no_windows('{"factor":0}\n', 'invalidInput')
print('PASS: EOF / malformed input / zero gain fail before renderer creation.', flush=True)

if not args.live:
    raise SystemExit(0)


def live_case(mode):
    child = subprocess.Popen([str(binary), '--boost-worker', '--trigger-only'],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, bufsize=1)
    reports = []

    def consume():
        for line in child.stdout:
            reports.append(json.loads(line))

    reader = threading.Thread(target=consume)
    reader.start()
    started = time.monotonic()
    limit = 33 if mode == 'timeout' else 3
    try:
        while child.poll() is None and time.monotonic() - started < limit:
            try:
                child.stdin.write('{"factor":1.01}\n')
                child.stdin.flush()
            except BrokenPipeError:
                break
            time.sleep(0.25)
        if mode == 'crash' and child.poll() is None:
            child.kill()
        elif mode == 'eof':
            child.stdin.close()
        # 'heartbeat' deliberately keeps stdin open without writing.
        child.wait(timeout=4)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        if not child.stdin.closed:
            child.stdin.close()
        reader.join(timeout=2)
    assert any(r['phase'] == 'active' and r.get('presentedFrames', 0) > 0 for r in reports), reports
    if mode == 'crash':
        assert child.returncode == -9, child.returncode
    else:
        assert reports[-1]['phase'] == 'off', reports[-1]
        assert reports[-1]['reason'] == ('timeout' if mode == 'timeout' else 'heartbeat'), reports[-1]
        assert child.returncode == 0, child.returncode
    print(f'PASS: {mode}; worker exited; {len(reports)} status reports.', flush=True)


for mode in ('eof', 'heartbeat', 'crash', 'timeout'):
    live_case(mode)
