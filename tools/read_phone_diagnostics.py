"""Read native iOS reports from the existing authenticated gateway's disk over SSH.

No cookie or SSH key is printed. Requires paramiko and an existing SSH identity.
"""
import argparse
import base64
import json
from pathlib import Path
import paramiko

parser = argparse.ArgumentParser()
parser.add_argument('--host', default='100.98.27.76')
parser.add_argument('--user', default='root')
parser.add_argument('--key', type=Path, default=Path.home() / '.ssh/id_ed25519')
parser.add_argument('--lines', type=int, default=100)
args = parser.parse_args()
remote = '''
import json
from pathlib import Path
files = sorted(Path('/var/lib/agent-relay/client-diagnostics').glob('*.json'), key=lambda p:p.stat().st_mtime, reverse=True)
for path in files[:50]:
    try:
        item = json.loads(path.read_text())
        report = item.get('report', {})
        if report.get('environment', {}).get('platform') != 'iOS': continue
        print(json.dumps(item, ensure_ascii=True)); break
    except (OSError, ValueError): continue
else: print('{}')
'''
encoded = base64.b64encode(remote.encode()).decode()
client = paramiko.SSHClient()
client.load_system_host_keys()
try:
    client.connect(args.host, username=args.user, key_filename=str(args.key), timeout=15)
    _, stdout, stderr = client.exec_command("python3 -c \"import base64;exec(base64.b64decode('" + encoded + "'))\"", timeout=20)
    data = stdout.read().decode()
    if stdout.channel.recv_exit_status() != 0:
        raise SystemExit('Remote diagnostic read failed: ' + stderr.read().decode()[:500])
    item = json.loads(data)
    if not item:
        print('No native iOS report received yet. Install the reporting build and open the logged-in app once.')
    else:
        report = item['report']
        print(json.dumps({k: item[k] for k in ('reportId', 'receivedAt')}, ensure_ascii=False))
        print(json.dumps({k: report[k] for k in ('buildVersion', 'generatedAt', 'runtime')}, ensure_ascii=False))
        for entry in report.get('entries', [])[-max(1, min(args.lines, 250)):]:
            print(entry.get('data', {}).get('message', ''))
finally:
    client.close()
