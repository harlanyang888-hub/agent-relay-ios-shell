import Foundation

struct WatchRequest: Equatable {
    enum Action: UInt8 { case sync = 0, bootLong = 1, bootShort = 2, end = 3 }
    let packet: Data
    let action: Action
    let sequence: UInt16
    let epoch: UInt32
    let revision: UInt16
    let expires: UInt32
    var key: String { packet.subdata(in: 4..<10).map { String(format: "%02x", $0) }.joined() }

    init?(_ data: Data) {
        guard data.count == 20, Array(data.prefix(3)) == [65, 82, 3],
              let action = Action(rawValue: data[3]), data.watchUInt32(4) != 0,
              data.watchUInt16(8) != 0 else { return nil }
        let expires = data.watchUInt32(16)
        guard action == .sync ? expires == 0 : expires > 0 else { return nil }
        self.packet = data; self.action = action; self.sequence = data.watchUInt16(8)
        self.epoch = data.watchUInt32(10); self.revision = data.watchUInt16(14); self.expires = expires
    }
    func expired(at time: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        action != .sync && Double(expires) <= time
    }
}

struct WatchReply {
    enum Result: UInt8 { case snapshot = 0, applied = 1, rejected = 2, received = 4 }
    enum Capture: UInt8 { case idle = 0, starting = 1, recording = 2, paused = 3, finalizing = 4 }
    let result: Result
    let sequence: UInt16
    let epoch: UInt32
    let revision: UInt16
    let capture: Capture
    var flags: UInt8 = 0
    var error: UInt8 = 0
    func encoded(at time: TimeInterval = Date().timeIntervalSince1970) -> Data {
        var data = Data([65, 82, 3, result.rawValue])
        data.watchAppend(sequence); data.watchAppend(epoch); data.watchAppend(revision)
        data.watchAppend(UInt32(clamping: Int64(time)))
        data.append(contentsOf: [capture.rawValue, flags, error, 0])
        return data
    }
}

final class WatchReceipts {
    private struct Entry: Codable { let key: String; let packet: Data; let succeeded: Bool; let error: UInt8 }
    private let defaults: UserDefaults
    private var entries: [Entry]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: "watch_v3_receipts").flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }
    func result(for request: WatchRequest) -> (Bool, UInt8)? {
        guard let old = entries.last(where: { $0.key == request.key }) else { return nil }
        return old.packet == request.packet ? (old.succeeded, old.error) : (false, 3)
    }
    func record(_ request: WatchRequest, succeeded: Bool, error: UInt8) {
        var all = entries.filter { $0.key != request.key }
        all.append(Entry(key: request.key, packet: request.packet, succeeded: succeeded, error: error))
        entries = Array(all.suffix(64))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "watch_v3_receipts") }
    }
}

extension Data {
    func watchUInt16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func watchUInt32(_ offset: Int) -> UInt32 { UInt32(watchUInt16(offset)) | UInt32(watchUInt16(offset + 2)) << 16 }
    mutating func watchAppend<T: FixedWidthInteger>(_ number: T) {
        var value = number.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
