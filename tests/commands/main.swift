import Foundation

let packet = Data([0x41, 0x52, 2, 1, 1, 2, 3, 4, 1, 0, 0, 0, 0xff, 0xff, 0xff, 0x7f])
let command = BLELabCommand(packet)!
precondition(command.action == .start && !command.expired)
precondition(command.acknowledgement(1) == packet + Data([1]))
precondition(BLELabCommand(packet.dropLast()) == nil)
var invalid = packet; invalid[3] = 9
precondition(BLELabCommand(invalid) == nil)
invalid = packet; invalid[8] = 0
precondition(BLELabCommand(invalid) == nil)
let suite = "BLELabTests-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
let first = BLELabReceipts(defaults: defaults)
first.record(command, status: 4)
precondition(first.result(for: command) == nil, "received is not executed")
first.record(command, status: 1)
let restored = BLELabReceipts(defaults: defaults)
precondition(restored.result(for: command) == 1, "terminal receipt must survive object recreation")
var changed = packet; changed[3] = 2
precondition(restored.result(for: BLELabCommand(changed)!) == 2, "conflicting command ID must fail closed")
changed[8] = 2
precondition(restored.result(for: BLELabCommand(changed)!) == nil)
defaults.removePersistentDomain(forName: suite)
print("Recovery command validation and durable deduplication checks passed")
