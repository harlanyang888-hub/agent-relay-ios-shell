import Foundation

struct BLELabCommand: Equatable {
    enum Action: UInt8 { case start = 1, stop = 2 }
    let packet: Data
    let action: Action
    let expires: TimeInterval
    var key: String { packet.subdata(in: 4..<12).map { String(format: "%02x", $0) }.joined() }
    var expired: Bool { expires <= Date().timeIntervalSince1970 }

    init?(_ data: Data) {
        guard data.count == 16, Array(data.prefix(3)) == [0x41, 0x52, 2],
              let action = Action(rawValue: data[3]) else { return nil }
        func number(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32(8 * $1) }
        }
        guard number(8) != 0 else { return nil }
        packet = data
        self.action = action
        expires = TimeInterval(number(12))
    }

    func acknowledgement(_ status: UInt8) -> Data { packet + Data([status]) }
}

// Persist terminal results before acknowledging, so a lost ACK cannot repeat an action.
final class BLELabReceipts {
    private struct Receipt: Codable { let key: String; let packet: Data; let status: UInt8 }
    private let defaults: UserDefaults
    private let key: String
    init(defaults: UserDefaults = .standard, key: String = "relay_lab_receipts_v2") {
        self.defaults = defaults
        self.key = key
    }
    private var entries: [Receipt] {
        guard let data = defaults.data(forKey: key), let result = try? JSONDecoder().decode([Receipt].self, from: data) else { return [] }
        return result
    }
    func result(for command: BLELabCommand) -> UInt8? {
        guard let receipt = entries.last(where: { $0.key == command.key }) else { return nil }
        return receipt.packet == command.packet ? receipt.status : 2
    }
    func record(_ command: BLELabCommand, status: UInt8) {
        guard (1...3).contains(status) else { return }
        var updated = entries.filter { $0.key != command.key }
        updated.append(Receipt(key: command.key, packet: command.packet, status: status))
        if let data = try? JSONEncoder().encode(Array(updated.suffix(64))) { defaults.set(data, forKey: key) }
    }
}
