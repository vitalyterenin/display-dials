#!/usr/bin/env python3
"""Default checks never create display windows. --live tests ONLY the tiny HDR marker.

Run after `swift build`. Live checks cover EOF, missed heartbeat, SIGKILL, stall, and bounded mode;
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
parser.add_argument('--sustained', action='store_true', help='Run the full-desktop overlay at 1.10 for 90 seconds.')
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

if not (args.live or args.sustained):
    raise SystemExit(0)


def live_case(mode):
    command = [str(binary), '--boost-worker']
    if mode != 'sustained': command += ['--trigger-only']
    if mode == 'timeout': command += ['--bounded-check']
    if mode == 'stall': command += ['--stall-check']
    child = subprocess.Popen(command,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, bufsize=1)
    reports = []

    def consume():
        for line in child.stdout:
            reports.append(json.loads(line))

    reader = threading.Thread(target=consume)
    reader.start()
    started = time.monotonic()
    limit = 90 if mode == 'sustained' else 33 if mode == 'timeout' else 3
    next_progress = 15
    try:
        while child.poll() is None and time.monotonic() - started < limit:
            try:
                child.stdin.write(json.dumps({'factor':1.10 if mode == 'sustained' else 1.01})+'\n')
                child.stdin.flush()
            except BrokenPipeError:
                break
            time.sleep(0.25)
            if mode == 'sustained' and time.monotonic() - started >= next_progress:
                print(f'Sustained check: {next_progress}s; latest status: {reports[-1] if reports else None}', flush=True)
                next_progress += 15
        if mode == 'crash' and child.poll() is None:
            child.kill()
        elif mode in ('eof','sustained'):
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
    elif mode == 'stall':
        assert child.returncode == 75, child.returncode
    else:
        assert reports[-1]['phase'] == 'off', reports[-1]
        assert reports[-1]['reason'] == ('timeout' if mode == 'timeout' else 'heartbeat'), reports[-1]
        assert child.returncode == 0, child.returncode
    if mode == 'sustained':
        steady = [r for r in reports if r['phase']=='active' and r.get('elapsed',0) > 5]
        assert steady and max(r['elapsed'] for r in steady) >= 85, reports[-1]
        print(f"Sustained gain range after startup: {min(r['factor'] for r in steady):.4f}–{max(r['factor'] for r in steady):.4f}", flush=True)
    print(f'PASS: {mode}; worker exited; {len(reports)} status reports.', flush=True)


if args.live:
    for mode in ('eof', 'heartbeat', 'crash', 'stall', 'timeout'):
        live_case(mode)
if args.sustained:
    live_case('sustained')
