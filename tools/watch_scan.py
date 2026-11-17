"""Confirm the physical watch's advertisement without changing its connection."""
import argparse
import json
from pathlib import Path
import sys
import time

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'agent-relay-ios-shell-builds'/'watch-scan-deps'))
from winrt.windows.devices.bluetooth.advertisement import BluetoothLEAdvertisementWatcher, BluetoothLEScanningMode

parser=argparse.ArgumentParser()
parser.add_argument('--address',required=True)
parser.add_argument('--seconds',type=float,default=8)
args=parser.parse_args()
address=int(args.address.replace(':',''),16)
seen=[]
def received(sender,event):
    if event.bluetooth_address==address:
        seen.append(dict(address=f'{event.bluetooth_address:012x}',name=event.advertisement.local_name,
                         rssi=event.raw_signal_strength_in_dbm,services=[str(x) for x in event.advertisement.service_uuids]))
watcher=BluetoothLEAdvertisementWatcher()
watcher.scanning_mode=BluetoothLEScanningMode.ACTIVE
token=watcher.add_received(received)
watcher.start()
try:
    time.sleep(args.seconds)
finally:
    watcher.stop()
    watcher.remove_received(token)
print(json.dumps(dict(observations=len(seen),last=seen[-1] if seen else None,
    names=sorted({x['name'] for x in seen if x['name']}),
    services=sorted({service for x in seen for service in x['services']}))))
