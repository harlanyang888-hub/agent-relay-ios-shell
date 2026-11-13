import Foundation

func bytes(_ hex: String) -> Data {
    var result = Data()
    var cursor = hex.startIndex
    while cursor < hex.endIndex {
        let end = hex.index(cursor, offsetBy: 2)
        result.append(UInt8(hex[cursor..<end], radix: 16)!)
        cursor = end
    }
    return result
}

let first = bytes("550e04663a02d7a0005b040acd7c")
let second = bytes("550e04663a02c1a4005b040a970b")
let fingerprint = BLEFrameComparison.fingerprint(first)
precondition(fingerprint != nil, "Known captured frame must pass both checksums")
precondition(fingerprint == BLEFrameComparison.fingerprint(second), "Counter-only differences must not look like a button")
var damaged = first
damaged[11] ^= 1
precondition(BLEFrameComparison.fingerprint(damaged) == nil, "Corrupted payload must remain unclassified")
precondition(BLEFrameComparison.fingerprint(first.prefix(8)) == nil, "Fragment must remain raw")
precondition(BLEFrameComparison.fingerprint(first + second) == nil, "Combined notifications must remain raw")
var changed = [UInt8](first.dropLast(2))
changed[11] ^= 1
let crc = BLEFrameComparison.crc16(changed, seed: 0x3692)
changed.append(UInt8(crc & 0xff))
changed.append(UInt8(crc >> 8))
let changedFingerprint = BLEFrameComparison.fingerprint(Data(changed))
precondition(changedFingerprint != nil && changedFingerprint != fingerprint, "A valid payload change must survive normalization")

let trial = BLEButtonTrial.shared
trial.start(device: "test")
trial.packet(service: "FFF0", characteristic: "FFF4", data: first, error: nil)
trial.mark()
trial.finish(reason: "test finished")
precondition(!trial.active)
precondition(trial.lastReport.contains("RAW FFF0/FFF4"))
precondition(trial.lastReport.contains("MARK"))
precondition(trial.lastReport.contains(first.map { String(format: "%02x", $0) }.joined()))
let completed = trial.lastReport
trial.finish(reason: "duplicate finish")
precondition(trial.lastReport == completed, "Repeated finish must not overwrite a completed capture")
UserDefaults.standard.removeObject(forKey: "ble_last_button_trial")
print("BLE comparison and trial capture checks passed")
