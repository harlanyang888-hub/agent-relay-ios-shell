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

    func attach(_ id: UUID) {
        if deviceID != id { sample = nil }
        deviceID = id; connected = true; available = false
        notify()
    }
    func disconnected(_ id: UUID) {
        guard deviceID == id else { return }
        connected = false; notify()
    }
    func receive(_ data: Data?, from id: UUID, error: Error?) {
        guard deviceID == id, connected else { return }
        available = true
        sample = error == nil ? data.flatMap { WatchBatterySample(packet: $0) } : nil
        notify()
    }
    var title: String {
        guard let sample = sample else { return "电量未知" }
        guard sample.present else { return "未检测到电池" }
        guard let percent = sample.percent else { return "电量未知" }
        return "\(percent)%"
    }
    var detail: String {
        guard let sample = sample else { return available ? "暂时无法读取电池数据" : "等待手表电量数据" }
        let age = max(0, Int(Date().timeIntervalSince(sample.receivedAt)))
        let freshness = !connected ? "已断开 · 上次读数" : age > 180 ? "读数已过期" : "刚刚更新"
        let power = sample.charging ? "充电中" : sample.usb ? "USB 已连接" : "电池供电"
        let voltage = sample.millivolts.map { " · \(String(format: "%.2f", Double($0) / 1000))V" } ?? ""
        return "\(power)\(voltage) · \(freshness) · \(age / 60)分钟前"
    }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
}
