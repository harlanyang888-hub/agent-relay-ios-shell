"""Bounded, filtered USB capture for the ASK/background-call regression."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import threading

parser = argparse.ArgumentParser()
parser.add_argument('--probe', action='store_true')
parser.add_argument('--seconds', type=int, default=120)
args = parser.parse_args()
builds = Path(__file__).resolve().parents[2] / 'agent-relay-ios-shell-builds'
python = builds / 'ios-debug-venv/Scripts/python.exe'
base = [str(python), '-u', '-m', 'pymobiledevice3']
try:
    probe = subprocess.run(base + ['usbmux', 'list'], capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=20)
except subprocess.TimeoutExpired:
    raise SystemExit('USB probe timed out; check Apple Mobile Device service and the USB cable.')
if probe.returncode:
    print((probe.stderr or probe.stdout)[-1800:])
    raise SystemExit('USB probe failed; no phone logs collected.')
try:
    devices = json.loads(probe.stdout)
except ValueError:
    raise SystemExit('USB probe did not return a device list; no phone logs collected.')
print('Connected device count:', len(devices), flush=True)
if args.probe:
    raise SystemExit(0 if devices else 2)
if len(devices) != 1:
    raise SystemExit('Connect exactly one unlocked, trusted iPhone before capture.')
if not 10 <= args.seconds <= 300:
    raise SystemExit('Capture duration must be 10..300 seconds.')

directory = builds / 'ios-background-call-logs'
directory.mkdir(exist_ok=True)
path = directory / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-callkit.log')
pattern = r'(?i)(AgentRelay|agent.?relay|callservicesd|LiveCommunicationKit|CallKit|runningboardd.*(audio|voip|bluetooth))'
process = subprocess.Popen(base + ['syslog', 'live', '--regex', pattern], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
timer = threading.Timer(args.seconds, process.terminate)
timer.daemon = True
timer.start()
lines = 0
print('Filtered capture started:', path, flush=True)
try:
    with path.open('w', encoding='utf-8') as output:
        for line in process.stdout:
            # Bound storage; never collect audio files, HTTP bodies, or cookies.
            if re.search(pattern, line):
                output.write(line[:16000])
                output.flush()
                lines += 1
                if lines >= 5000 or output.tell() > 8_000_000:
                    break
finally:
    timer.cancel()
    if process.poll() is None:
        process.terminate()
    process.wait(timeout=10)
print('Capture complete; matching lines:', lines, 'file:', path)
