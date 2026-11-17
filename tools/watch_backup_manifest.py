"""Validate and describe the full factory backup before flashing development code."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import struct

parser = argparse.ArgumentParser()
parser.add_argument('backup', type=Path)
args = parser.parse_args()
data = args.backup.read_bytes()
if len(data) != 32 * 1024 * 1024 or data[0] != 0xE9:
    raise SystemExit('Backup size or ESP image header is invalid; do not flash')
partitions = []
for offset in range(0x8000, 0x8C00, 32):
    magic, kind, subtype, start, size, name, flags = struct.unpack_from('<HBBII16sI', data, offset)
    if magic != 0x50AA:
        break
    if start + size > len(data):
        raise SystemExit('Partition extends beyond the backup; do not flash')
    partitions.append(dict(name=name.rstrip(b'\0').decode('ascii'), type=kind, subtype=subtype,
                           offset=start, size=size, flags=flags))
if not any(p['type'] == 0 for p in partitions):
    raise SystemExit('No application partition found; do not flash')
manifest = dict(created_at=datetime.now(timezone.utc).isoformat(), chip='ESP32-S3',
                bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), partitions=partitions)
destination = args.backup.with_suffix('.json')
destination.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print(json.dumps(manifest, indent=2))
print('Manifest:', destination)
