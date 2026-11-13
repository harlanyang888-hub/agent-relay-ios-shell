import Foundation

// 比较工具，不把状态包或差异自动解释为按键。
enum BLEFrameComparison {
    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0x77
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8c : crc >> 1 }
        }
        return crc
    }

    static func crc16(_ bytes: [UInt8], seed: UInt16) -> UInt16 {
        var crc = seed
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        return crc
    }

    static func fingerprint(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 13, bytes[0] == 0x55,
              (Int(bytes[1]) | (Int(bytes[2] & 3) << 8)) == bytes.count,
              crc8(Array(bytes.prefix(3))) == bytes[3],
              crc16(bytes, seed: 0x3692) == 0 || crc16(bytes, seed: 0) == 0xbb01 else { return nil }
        // 仅比较：屏蔽候选序号与帧尾校验。原始通知另行完整保存。
        return (Array(bytes.prefix(6)) + [0, 0] + Array(bytes[8..<(bytes.count - 2)]))
            .map { String(format: "%02x", $0) }.joined()
    }
}

final class BLEButtonTrial {
    static let shared = BLEButtonTrial()
    static let phaseNames = ["基线：不要按键", "短按连接键一次①", "短按连接键一次②", "短按连接键一次③",
                             "双击电源键①，观察降噪灯", "双击电源键②，观察降噪灯", "收尾：不要按键"]
    private(set) var active = false
    private var startedAt: TimeInterval = 0
    private var rows: [String] = []
    private var counts: [[String: Int]] = Array(repeating: [:], count: 7)
    private var unknownCounts = Array(repeating: 0, count: 7)
    private var marks = Array(repeating: 0, count: 7)
    private var lastPhase = -1
    private(set) var lastReport: String

    private init() { lastReport = UserDefaults.standard.string(forKey: "ble_last_button_trial") ?? "尚无完整按键采样" }
    var elapsed: Int { Int(max(0, ProcessInfo.processInfo.systemUptime - startedAt)) }
    var phase: Int {
        switch elapsed {
        case ..<8: return 0
        case ..<14: return 1
        case ..<20: return 2
        case ..<26: return 3
        case ..<32: return 4
        case ..<38: return 5
        default: return 6
        }
    }
    var instruction: String { Self.phaseNames[phase] }

    func start(device: String) {
        active = true
        startedAt = ProcessInfo.processInfo.systemUptime
        rows = ["设备=\(device)", "提示时间是计划操作窗口，不代表已检测到硬件按键；MARK 是用户手动确认。"]
        counts = Array(repeating: [:], count: 7)
        unknownCounts = Array(repeating: 0, count: 7)
        marks = Array(repeating: 0, count: 7)
        lastPhase = -1
        advance()
    }

    func advance() {
        guard active else { return }
        if elapsed >= 44 { finish(reason: "完成"); return }
        if phase != lastPhase {
            lastPhase = phase
            event("CUE \(instruction)")
        }
    }

    func event(_ message: String) {
        guard active, rows.count < 4000 else { return }
        let seconds = ProcessInfo.processInfo.systemUptime - startedAt
        rows.append(String(format: "+%.3fs phase=%d %@", seconds, phase, message))
    }

    func mark() {
        guard active else { return }
        marks[phase] += 1
        event("MARK 用户确认刚操作了麦克风实体键")
    }

    func packet(service: String, characteristic: String, data: Data, error: Error?) {
        guard active else { return }
        advance()
        guard active else { return }
        let key = service + "/" + characteristic
        let hex = data.map { String(format: "%02x", $0) }.joined()
        if error == nil, let fingerprint = BLEFrameComparison.fingerprint(data) {
            counts[phase][key + ":" + fingerprint, default: 0] += 1
        } else { unknownCounts[phase] += 1 }
        event("RAW \(key) hex=\(hex) error=\(String(describing: error))")
    }

    func finish(reason: String) {
        guard active else { return }
        event("END \(reason)")
        active = false
        let baseline = Set(counts[0].keys)
        var report = ["大疆按键分阶段采样：\(reason)", "日期=\(ISO8601DateFormatter().string(from: Date()))",
                      "仅对完整且校验通过的帧屏蔽候选序号和尾部校验；差异不是已确认的按键。"]
        for index in counts.indices {
            let extra = Set(counts[index].keys).subtracting(baseline).sorted()
            report.append("阶段\(index) \(Self.phaseNames[index])：通知=\(counts[index].values.reduce(0, +)) 不可归一化=\(unknownCounts[index]) 手动标记=\(marks[index]) 新指纹数=\(extra.count)")
            for key in extra { report.append("  NEW \(key) count=\(counts[index][key] ?? 0)") }
        }
        report.append("--- 完整原始记录 ---")
        report.append(contentsOf: rows)
        lastReport = report.joined(separator: "\n")
        UserDefaults.standard.set(lastReport, forKey: "ble_last_button_trial")
    }
}
