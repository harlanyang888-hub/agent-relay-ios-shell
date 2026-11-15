"""Persistent, ordered recovery-test commands; no Windows dependencies."""
import json
import os
from pathlib import Path
import secrets
import struct
import time
import uuid

HEADER = b'AR\x02'
START, STOP = 1, 2
APPLIED, FAILED, EXPIRED, RECEIVED = 1, 2, 3, 4


def decode(packet):
    if len(packet) != 16 or packet[:3] != HEADER or packet[3] not in (START, STOP):
        raise ValueError('invalid command')
    sequence, expires = struct.unpack('<II', packet[8:])
    if not sequence:
        raise ValueError('invalid sequence')
    return {'action': packet[3], 'nonce': packet[4:8].hex(), 'sequence': sequence, 'expires': expires}


class CommandQueue:
    def __init__(self, path, clock=time.time):
        self.path, self.clock = Path(path), clock
        if self.path.exists():
            self.data = json.loads(self.path.read_text(encoding='utf-8'))
            assert self.data['version'] == 2
            uuid.UUID(self.data['device_id'])
            assert len(bytes.fromhex(self.data['nonce'])) == 4
            for entry in self.data['pending']:
                decode(bytes.fromhex(entry['packet']))
        else:
            self.data = {'version': 2, 'device_id': str(uuid.uuid4()), 'nonce': secrets.token_hex(4),
                         'sequence': 0, 'pending': [], 'history': [], 'last_packet': None}
            self.save()

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix('.tmp')
        with temporary.open('w', encoding='utf-8') as stream:
            json.dump(self.data, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, self.path)

    def _history(self, packet, status):
        self.data['history'].append({'packet': packet.hex(), 'status': status, 'at': self.clock()})
        self.data['history'] = self.data['history'][-64:]

    def expire(self):
        expired = [x for x in self.data['pending'] if decode(bytes.fromhex(x['packet']))['expires'] <= self.clock()]
        if expired:
            for entry in expired:
                self._history(bytes.fromhex(entry['packet']), EXPIRED)
            self.data['pending'] = [x for x in self.data['pending'] if x not in expired]
            self.save()

    def enqueue(self, action, ttl=120):
        if action not in (START, STOP) or not 1 <= ttl <= 300:
            raise ValueError('invalid action or TTL')
        self.expire()
        if len(self.data['pending']) >= 16:
            raise ValueError('queue full')
        if self.data['sequence'] >= 0xffffffff:
            if self.data['pending']:
                raise ValueError('sequence exhausted')
            self.data['sequence'] = 0
            self.data['nonce'] = secrets.token_hex(4)
        self.data['sequence'] += 1
        packet = HEADER + bytes([action]) + bytes.fromhex(self.data['nonce']) + struct.pack(
            '<II', self.data['sequence'], int(self.clock() + ttl))
        self.data['pending'].append({'packet': packet.hex(), 'received': False})
        self.data['last_packet'] = packet.hex()
        self.save()
        return packet

    def head(self):
        self.expire()
        return bytes.fromhex(self.data['pending'][0]['packet']) if self.data['pending'] else b''

    def acknowledge(self, data):
        if len(data) != 17 or data[-1] not in (APPLIED, FAILED, EXPIRED, RECEIVED):
            raise ValueError('invalid acknowledgement')
        packet, status = data[:16], data[-1]
        decode(packet)
        # Late duplicate confirmations are safe; never remove a different head.
        if any(x['packet'] == packet.hex() for x in self.data['history']):
            return 'duplicate'
        self.expire()
        if not self.data['pending'] or self.data['pending'][0]['packet'] != packet.hex():
            raise ValueError('acknowledgement does not match queue head')
        if status == RECEIVED:
            self.data['pending'][0]['received'] = True
        else:
            self.data['pending'].pop(0)
            self._history(packet, status)
        self.save()
        return 'received' if status == RECEIVED else 'terminal'

    def snapshot(self):
        self.expire()
        return dict(self.data)
