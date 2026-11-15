import tempfile
import unittest
from pathlib import Path
from ble_command_queue import CommandQueue, START, STOP, APPLIED, RECEIVED, FAILED, EXPIRED, decode


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = 1000
        self.path = Path(self.temp.name) / 'queue.json'
        self.queue = CommandQueue(self.path, lambda: self.now)

    def test_offline_command_survives_process_restart(self):
        packet = self.queue.enqueue(START)
        other = CommandQueue(self.path, lambda: self.now)
        self.assertEqual(other.head(), packet)
        self.assertEqual(other.data['device_id'], self.queue.data['device_id'])
        self.assertEqual(other.data['nonce'], self.queue.data['nonce'])

    def test_receipt_does_not_remove_command_and_terminal_ack_does(self):
        first, second = self.queue.enqueue(START), self.queue.enqueue(STOP)
        self.queue.acknowledge(first + bytes([RECEIVED]))
        self.assertEqual(self.queue.head(), first)
        self.queue.acknowledge(first + bytes([APPLIED]))
        self.assertEqual(self.queue.head(), second)
        self.assertEqual(self.queue.acknowledge(first + bytes([APPLIED])), 'duplicate')
        self.assertEqual(self.queue.head(), second)

    def test_mismatched_ack_cannot_drop_head(self):
        first, second = self.queue.enqueue(START), self.queue.enqueue(STOP)
        with self.assertRaises(ValueError):
            self.queue.acknowledge(second + bytes([APPLIED]))
        self.assertEqual(self.queue.head(), first)

    def test_expiry_prevents_delayed_recording(self):
        self.queue.enqueue(START, ttl=5)
        self.now += 6
        self.assertEqual(self.queue.head(), b'')
        self.assertEqual(self.queue.data['history'][-1]['status'], EXPIRED)

    def test_failed_command_is_visible_without_retry_loop(self):
        packet = self.queue.enqueue(START)
        self.queue.acknowledge(packet + bytes([FAILED]))
        self.assertEqual(self.queue.head(), b'')
        self.assertEqual(self.queue.data['history'][-1]['status'], FAILED)

    def test_protocol_rejects_invalid_packets(self):
        packet = self.queue.enqueue(START)
        self.assertEqual(decode(packet)['sequence'], 1)
        for invalid in (b'', packet[:-1], packet + b'x', b'XX' + packet[2:], packet[:3] + b'\x09' + packet[4:]):
            with self.assertRaises(ValueError):
                decode(invalid)


if __name__ == '__main__':
    unittest.main()
