import Foundation

func packet(_ flags: UInt8, _ percent: UInt8, _ mv: UInt16 = 0) -> Data {
    Data([1, flags, percent, 0, UInt8(mv & 255), UInt8(mv >> 8), 0, 0, 0, 0, 0, 0])
}
let id = UUID(), other = UUID()
let store = WatchBatteryStore.shared
assert(WatchBatterySample(packet: Data()) == nil)
assert(WatchBatterySample(packet: packet(0, 0)) == nil)
store.attach(id)
store.receive(packet(3 | 16, 73, 3950), from: id, error: nil)
assert(store.sample?.percent == 73 && store.sample?.millivolts == 3950)
store.receive(packet(3, 255), from: id, error: nil)
assert(store.sample?.percent == nil && store.sample?.millivolts == nil)
store.receive(packet(1 | 4, 100), from: id, error: nil)
assert(store.sample?.present == false && store.sample?.percent == nil)
store.receive(packet(3 | 4 | 8, 0), from: id, error: nil)
assert(store.sample?.percent == 0 && store.sample?.charging == true)
store.disconnected(id)
store.receive(packet(3, 99), from: id, error: nil)
assert(store.sample?.percent == 0 && !store.connected)
store.attach(other)
assert(store.sample == nil)
store.receive(packet(3, 99), from: id, error: nil)
assert(store.sample == nil)
store.receive(packet(3, 55), from: other, error: nil)
store.receive(nil, from: other, error: NSError(domain: "test", code: 1))
assert(store.sample == nil && store.title == "电量未知")
print("Battery unknown, charging, reconnect, stale-device and decode checks passed")
