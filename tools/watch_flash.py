"""Flash the verified development artifact after validating a full factory backup."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--port', required=True)
parser.add_argument('--artifact', required=True, type=Path)
parser.add_argument('--backup', required=True, type=Path)
args = parser.parse_args()
root = args.artifact.resolve()
manifest = json.loads(args.backup.with_suffix('.json').read_text(encoding='utf-8'))
data = args.backup.read_bytes()
if len(data) != 33554432 or hashlib.sha256(data).hexdigest() != manifest['sha256']:
    raise SystemExit('Full backup verification failed')
build = json.loads((root / 'build.json').read_text(encoding='utf-8'))
if build['conclusion'] != 'success':
    raise SystemExit('Firmware build was not successful')
config = json.loads((root / 'flasher_args.json').read_text(encoding='utf-8'))
files = config['flash_files']
if set(files) != {'0x0', '0x8000', '0x10000'}:
    raise SystemExit('Unexpected flash layout; review before writing')
command = [sys.executable, str(Path(__file__).with_name('watch_esptool.py')),
           '--chip', 'esp32s3', '--port', args.port, '--baud', '921600', 'write-flash',
           '--flash-mode', 'dio', '--flash-size', '32MB', '--flash-freq', '80m']
for offset, name in sorted(files.items(), key=lambda pair: int(pair[0], 16)):
    path = (root / name).resolve()
    if root not in path.parents or not path.is_file() or path.stat().st_size < 1024:
        raise SystemExit('Firmware artifact is missing or invalid')
    command.extend([offset, str(path)])
print('Backup verified:', args.backup, flush=True)
print('Firmware commit:', build['headSha'], flush=True)
print('Writing bootloader, partition table and application; no full erase or NVS erase.', flush=True)
raise SystemExit(subprocess.run(command).returncode)
