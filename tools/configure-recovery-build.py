import argparse
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('profile', choices=['legacy', 'ask'])
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
for name in ['AgentRelay/Info.plist', 'ShareExtension/Info.plist']:
    path = root / name
    data = plistlib.loads(path.read_bytes())
    data['CFBundleShortVersionString'] = '1.0.34' if args.profile == 'legacy' else '1.0.44'
    data['CFBundleVersion'] = '35' if args.profile == 'legacy' else '45'
    if name.startswith('AgentRelay/'):
        data['RelayBLERecoveryLab'] = True
        data['RelayUseAccessorySetupKit'] = args.profile == 'ask'
        for key in list(data):
            if key.startswith('NSAccessorySetup'):
                del data[key]
        if args.profile == 'ask':
            data['NSAccessorySetupKitSupports'] = ['Bluetooth']
            data['NSAccessorySetupBluetoothServices'] = ['A8D70200-6B44-4E93-A2D5-73F2A34B8180']
            data['NSAccessorySetupBluetoothNames'] = ['RN12108', 'AgentRelay', 'AgentRelay-Watch']
    path.write_bytes(plistlib.dumps(data, sort_keys=False))
print('Configured recovery lab:', args.profile)
