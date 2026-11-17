"""Read development watch logs; does not change firmware or pairing storage."""
import argparse
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'agent-relay-ios-shell-builds' / 'esp-tools-deps'))
import serial

parser = argparse.ArgumentParser()
parser.add_argument('--port', default='COM4')
parser.add_argument('--seconds', type=float, default=20)
parser.add_argument('--log', type=Path)
parser.add_argument('--reset', action='store_true', help='Reset the connected watch to capture boot diagnostics')
args = parser.parse_args()
connection = serial.Serial()
connection.port = args.port
connection.baudrate = 115200
connection.timeout = 0.25
connection.dtr = False
connection.rts = False
connection.open()
if args.reset:
    from esptool.reset import HardReset
    HardReset(connection, uses_usb=True)()
output = args.log.open('a', encoding='utf-8') if args.log else None
try:
    deadline = time.monotonic() + args.seconds
    while time.monotonic() < deadline:
        data = connection.read(connection.in_waiting or 1)
        if data:
            text = data.decode('utf-8', errors='replace')
            print(text, end='', flush=True)
            if output:
                output.write(text)
                output.flush()
finally:
    connection.close()
    if output:
        output.close()
