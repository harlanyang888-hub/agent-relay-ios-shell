import Foundation

struct WatchBatterySample {
    let receivedAt: Date
    let present: Bool
    let usb: Bool
    let charging: Bool
    let percent: Int?
    let millivolts: Int?

    init?(packet: Data, now: Date = Date()) {
        let b = Array(packet)
        guard b.count == 12, b[0] == 1, b[1] & 1 != 0 else { return nil }
        receivedAt = now
        present = b[1] & 2 != 0
        usb = b[1] & 4 != 0
        charging = present && b[1] & 8 != 0
        percent = present && b[2] <= 100 ? Int(b[2]) : nil
        let mv = Int(b[4]) | Int(b[5]) << 8
        millivolts = present && b[1] & 16 != 0 && (2000...5000).contains(mv) ? mv : nil
    }
}

// Telemetry has no authority over capture, connections, or command receipts.
final class WatchBatteryStore {
    static let shared = WatchBatteryStore()
    static let changed = Notification.Name("RelayWatchBatteryChanged")
    private(set) var sample: WatchBatterySample?
    private(set) var connected = false
    private(set) var deviceID: UUID?
    private(set) var available = false
    private(set) var pendingRefreshToken: UInt16?
    private(set) var refreshError: String?
    private var refreshTimeout: DispatchWorkItem?
    private var refreshSequence = UInt16.random(in: 1...UInt16.max)
    private var lastReplyToken: UInt16 = 0
    var isRefreshing: Bool { pendingRefreshToken != nil }

    func beginRefresh(_ id: UUID) -> UInt16? {
        guard connected, deviceID == id, pendingRefreshToken == nil else { return nil }
        repeat { refreshSequence &+= 1 } while refreshSequence == 0 || refreshSequence == lastReplyToken
        let token = refreshSequence
        pendingRefreshToken = token; refreshError = nil
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.deviceID == id, self.pendingRefreshToken == token else { return }
            self.failRefresh("刷新超时")
        }
        refreshTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        notify(); return token
    }
    func failRefresh(_ message: String) {
        refreshTimeout?.cancel(); refreshTimeout = nil; pendingRefreshToken = nil
        refreshError = message; notify()
    }

    func attach(_ id: UUID) {
        refreshTimeout?.cancel(); refreshTimeout = nil; pendingRefreshToken = nil; refreshError = nil
        if deviceID != id { sample = nil }
        deviceID = id; connected = true; available = false
        notify()
    }
    func disconnected(_ id: UUID) {
        guard deviceID == id else { return }
        refreshTimeout?.cancel(); refreshTimeout = nil; pendingRefreshToken = nil
        connected = false; notify()
    }
    func receive(_ data: Data?, from id: UUID, error: Error?) {
        guard deviceID == id, connected else { return }
        available = true
        sample = error == nil ? data.flatMap { WatchBatterySample(packet: $0) } : nil
        if error == nil, let data = data, data.count == 12, data.first == 1 {
            let bytes = Array(data)
            let token = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
            lastReplyToken = token
            if let pending = pendingRefreshToken, token == pending {
                refreshTimeout?.cancel(); refreshTimeout = nil; pendingRefreshToken = nil
                refreshError = sample == nil ? "暂时无法读取电量" : nil
            } else if pendingRefreshToken == nil, sample != nil { refreshError = nil }
        }
        recordSample()
        notify()
    }
    var historyURL: URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return root.appendingPathComponent("watch-battery.jsonl")
    }
    private func recordSample() {
        guard let url = historyURL else { return }
        var row: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()),
            "valid": sample != nil, "device": deviceID?.uuidString ?? "unknown",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
        if let sample = sample {
            row["batteryPresent"] = sample.present; row["usb"] = sample.usb; row["charging"] = sample.charging
            row["percent"] = sample.percent; row["millivolts"] = sample.millivolts
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 1_000_000 {
                // A bounded telemetry log; this never touches recordings or journals.
                let old = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").suffix(1500).joined(separator: "\n") + "\n"
                try Data(old.utf8).write(to: url, options: .atomic)
            }
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url) }
            else {
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            }
        } catch { /* Telemetry persistence must not affect the recording path. */ }
    }
    var title: String {
        guard let sample = sample else { return "电量未知" }
        guard sample.present else { return "未检测到电池" }
        guard let percent = sample.percent else { return "电量未知" }
        return "\(percent)%"
    }
    var detail: String {
        if isRefreshing { return "刷新中" }
        if let error = refreshError { return error }
        guard let sample = sample else { return available ? "暂时无法读取电池数据" : "等待手表电量数据" }
        let age = max(0, Int(Date().timeIntervalSince(sample.receivedAt)))
        let freshness = !connected ? "已断开" : age > 180 ? "读数已过期" : age < 60 ? "刚刚更新" : "\(age / 60)分钟前"
        let power = sample.charging ? "充电中" : sample.usb ? "USB 已连接" : "电池供电"
        let voltage = sample.millivolts.map { " · \(String(format: "%.2f", Double($0) / 1000))V" } ?? ""
        return "\(power)\(voltage) · \(freshness)"
    }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
}
