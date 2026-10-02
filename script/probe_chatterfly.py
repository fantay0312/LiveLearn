#!/usr/bin/env python3
"""Explicit live check using a caller-supplied PCM fixture, never ambient microphone audio."""
import argparse
import json
import os
import selectors
import subprocess
import time
import uuid
import base64
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--executable', required=True)
parser.add_argument('--pcm', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--profile', help='Optional explicit profile JSON for another compatible private-pipe engine')
parser.add_argument('--live', action='store_true', required=True)
args = parser.parse_args()
pcm = Path(args.pcm).read_bytes()
child = subprocess.Popen([args.executable, 'stdio', '--live', '--diagnostics'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
selector = selectors.DefaultSelector()
selector.register(child.stdout, selectors.EVENT_READ)
events, pending = [], b''
success = False
started = time.monotonic()
streaming = False
finished = False
offset = 0
next_audio = started

def send(value):
    child.stdin.write((json.dumps(value, separators=(',', ':')) + '\n').encode())
    child.stdin.flush()

try:
    profile = json.loads(Path(args.profile).read_text()) if args.profile else {'device_id': str(uuid.uuid4()), 'token': ''}
    profile.setdefault('token', '')
    send({'type': 'start', 'profile': profile})
    while time.monotonic() - started < 40:
        if selector.select(0.01):
            data = os.read(child.stdout.fileno(), 8192)
            if not data:
                break
            pending += data
            while b'\n' in pending:
                line, pending = pending.split(b'\n', 1)
                event = json.loads(line)
                event['elapsed_ms'] = round((time.monotonic() - started) * 1000)
                events.append(event)
                if event['type'] == 'ready':
                    streaming = True
                    next_audio = time.monotonic()
            if events[-1]['type'] in ('final', 'error'):
                break
        if streaming and not finished and time.monotonic() >= next_audio:
            if offset < len(pcm):
                send({'type': 'audio', 'pcm': base64.b64encode(pcm[offset:offset + 1280]).decode()})
                offset += 1280
                next_audio += 0.04
            else:
                send({'type': 'finish'})
                finished = True
    success = bool(events and events[-1]['type'] == 'final' and events[-1].get('text'))
finally:
    if child.poll() is None:
        child.terminate()
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
    Path(args.output).write_text(json.dumps({'success': success, 'fixture': str(Path(args.pcm)), 'events': events}, ensure_ascii=False, indent=2))
print(json.dumps({'success': success, 'event_types': [x['type'] for x in events], 'last': events[-1] if events else None}, ensure_ascii=False))
raise SystemExit(0 if success else 1)
