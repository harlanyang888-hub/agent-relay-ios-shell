import UIKit
import CoreBluetooth
import AVFoundation

// 仅记录设备和录音状态，不记录 Cookie、音频或会话内容。
final class DeviceDiagnostics {
    static let shared = DeviceDiagnostics()
    private let key = "device_diagnostics_v1"
    private(set) var lines: [String]
    var onChange: (() -> Void)?

    private init() {
        lines = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func log(_ message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.log(message) }
            return
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        print("[DeviceDiagnostics] \(line)")
        lines.append(line)
        if lines.count > 250 { lines.removeFirst(lines.count - 250) }
        UserDefaults.standard.set(lines, forKey: key)
        onChange?()
    }

    var text: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Agent Relay \(version) (\(build)); iOS \(UIDevice.current.systemVersion)\n" + lines.joined(separator: "\n")
    }
}

// 第一阶段只观察通知，不把未知数据包映射为录音按键，也不向配件写入命令。
final class BLEProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = BLEProbe()
    private var central: CBCentralManager!
    private(set) var devices: [CBPeripheral] = []
    private(set) var names: [UUID: String] = [:]
    private(set) var signals: [UUID: Int] = [:]
    private var lastRefreshAt: TimeInterval = 0
    private var selected: CBPeripheral?
    private var notificationsReady = false
    private var lastValueLog: [String: (String, TimeInterval)] = [:]
    private var volumeObservation: NSKeyValueObservation?
    private var scanningRequested = false
    private var scanTimeout: Timer?
    private let buttonService = CBUUID(string: "A8D70100-6B44-4E93-A2D5-73F2A34B8180")
    private let buttonEvent = CBUUID(string: "A8D70101-6B44-4E93-A2D5-73F2A34B8180")
    private var buttonSession: Data?
    private var buttonSequence: UInt32 = 0
    var onChange: (() -> Void)?
    var canRunButtonTrial: Bool { selected?.state == .connected && notificationsReady }
    var connectionDescription: String {
        guard let peripheral = selected else { return "尚未连接设备" }
        return "\(peripheral.name ?? "未命名") · \(peripheral.state == .connected ? "已连接" : "未连接") · 通知\(notificationsReady ? "已就绪" : "未就绪")"
    }

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "agent-relay-ble-probe-v1"
        ])
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.old, .new]) { _, change in
            let oldValue = change.oldValue ?? -1
            let newValue = change.newValue ?? -1
            DispatchQueue.main.async {
                BLEButtonTrial.shared.event("SYSTEM_VOLUME old=\(oldValue) new=\(newValue) source=unknown")
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(stopScan),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func scan() {
        scanningRequested = true
        guard central.state == .poweredOn else {
            DeviceDiagnostics.shared.log("BLE 等待蓝牙就绪，state=\(central.state.rawValue)")
            return
        }
        devices.removeAll()
        names.removeAll()
        signals.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DeviceDiagnostics.shared.log("BLE 扫描附近强信号设备（30 秒，RSSI≥-80），把防丢器贴近手机并按键")
        scanTimeout?.invalidate()
        scanTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in self?.stopScan() }
        onChange?()
    }

    @objc func stopScan() {
        scanningRequested = false
        scanTimeout?.invalidate()
        scanTimeout = nil
        central.stopScan()
    }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        if selected?.identifier == peripheral.identifier, peripheral.state == .connected || peripheral.state == .connecting { return }
        BLEButtonTrial.shared.finish(reason: "更换或重新连接设备")
        notificationsReady = false
        lastValueLog.removeAll()
        if let previous = selected, previous.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(previous)
        }
        selected = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        DeviceDiagnostics.shared.log("BLE 连接 \(peripheral.name ?? "未命名") \(peripheral.identifier)")
    }

    func disconnect() {
        guard let peripheral = selected else { return }
        BLEButtonTrial.shared.finish(reason: "用户断开连接")
        central.cancelPeripheralConnection(peripheral)
        selected = nil
        notificationsReady = false
        DeviceDiagnostics.shared.log("BLE 已请求断开")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DeviceDiagnostics.shared.log("BLE state=\(central.state.rawValue)")
        if central.state == .poweredOn, scanningRequested { scan() }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        selected = restored.first
        for peripheral in restored {
            peripheral.delegate = self
            if peripheral.state == .connected { peripheral.discoverServices(nil) }
        }
        DeviceDiagnostics.shared.log("BLE 恢复外设数=\(restored.count)")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard RSSI.intValue < 0, RSSI.intValue >= -80 else { return }
        let isNew = !devices.contains(where: { $0.identifier == peripheral.identifier })
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "未命名"
        if isNew { devices.append(peripheral) }
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        names[peripheral.identifier] = advertisedServices.contains(buttonService) ? "Agent Relay 电脑按钮" : name
        signals[peripheral.identifier] = RSSI.intValue
        if isNew {
            let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let manufacturer = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data())
                .prefix(18).map { String(format: "%02x", $0) }.joined()
            let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber
            DeviceDiagnostics.shared.log("BLE 发现 \(name) RSSI=\(RSSI) id=\(peripheral.identifier) services=\(services) manufacturer=\(manufacturer) connectable=\(connectable?.stringValue ?? "?")")
        }
        let now = ProcessInfo.processInfo.systemUptime
        if isNew || now - lastRefreshAt > 1 {
            lastRefreshAt = now
            // 行顺序保持稳定，避免用户点击时设备因信号变化而换位。
            onChange?()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DeviceDiagnostics.shared.log("BLE 已连接 \(peripheral.name ?? "未命名")")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DeviceDiagnostics.shared.log("BLE 连接失败 \(String(describing: error))")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral.identifier == selected?.identifier {
            notificationsReady = false
            BLEButtonTrial.shared.event("DISCONNECT error=\(String(describing: error))")
            BLEButtonTrial.shared.finish(reason: "设备断开，采样未完成")
        }
        DeviceDiagnostics.shared.log("BLE 断开 \(peripheral.identifier) error=\(String(describing: error))")
        if peripheral.identifier == selected?.identifier,
           peripheral.services?.contains(where: { $0.uuid == buttonService }) == true {
            DeviceDiagnostics.shared.log("BLE 专用按钮等待重连")
            central.connect(peripheral, options: nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { DeviceDiagnostics.shared.log("BLE 服务错误 \(error)"); return }
        for service in peripheral.services ?? [] {
            DeviceDiagnostics.shared.log("BLE service=\(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error { DeviceDiagnostics.shared.log("BLE 特征错误 \(error)"); return }
        for characteristic in service.characteristics ?? [] {
            DeviceDiagnostics.shared.log("BLE characteristic=\(service.uuid)/\(characteristic.uuid) properties=\(characteristic.properties.rawValue)")
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if peripheral.identifier == selected?.identifier, characteristic.uuid == CBUUID(string: "FFF4") || characteristic.uuid == buttonEvent {
            notificationsReady = characteristic.isNotifying && error == nil
        }
        DeviceDiagnostics.shared.log("BLE 订阅 \(characteristic.uuid) enabled=\(characteristic.isNotifying) error=\(String(describing: error))")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        let service = characteristic.service?.uuid.uuidString ?? "?"
        let data = characteristic.value ?? Data()
        if characteristic.service?.uuid == buttonService, characteristic.uuid == buttonEvent {
            guard error == nil, characteristic.isNotifying, data.count == 12,
                  Array(data.prefix(4)) == [0x41, 0x52, 1, 1] else {
                DeviceDiagnostics.shared.log("BLE 专用按钮拒绝无效事件")
                return
            }
            let session = data.subdata(in: 4..<8)
            let sequence = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[8 + $1]) << UInt32($1 * 8) }
            if session == buttonSession, sequence <= buttonSequence {
                DeviceDiagnostics.shared.log("BLE 专用按钮忽略重复事件 seq=\(sequence)")
                return
            }
            buttonSession = session
            buttonSequence = sequence
            DeviceDiagnostics.shared.log("BLE 专用按钮收到 seq=\(sequence) state=\(UIApplication.shared.applicationState.rawValue)")
            if #available(iOS 17.4, *) { VoiceConversationProbe.shared.handleDedicatedButton() }
            return
        }
        BLEButtonTrial.shared.packet(service: service, characteristic: characteristic.uuid.uuidString, data: data, error: error)
        let key = service + "/" + characteristic.uuid.uuidString
        let now = ProcessInfo.processInfo.systemUptime
        if error == nil, let fingerprint = BLEFrameComparison.fingerprint(data) {
            let summaryKey = key + ":" + fingerprint
            if let previous = lastValueLog[summaryKey], now - previous.1 < 5 { return }
            if lastValueLog.count > 128 { lastValueLog.removeAll() }
            lastValueLog[summaryKey] = (fingerprint, now)
        }
        let hex = (characteristic.value ?? Data()).prefix(64).map { String(format: "%02x", $0) }.joined()
        DeviceDiagnostics.shared.log("BLE VALUE \(characteristic.service?.uuid.uuidString ?? "?")/\(characteristic.uuid) hex=\(hex) error=\(String(describing: error))")
    }
}

final class DeviceDiagnosticsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView()
    private let logView = UITextView()
    private let recordButton = UIButton(type: .system)
    private let trialButton = UIButton(type: .system)
    private let trialLabel = UILabel()
    private var lastTrialPhase = -1
    private var refreshTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设备测试"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        let scan = UIButton(type: .system)
        scan.setTitle("扫描 BLE", for: .normal)
        scan.addTarget(self, action: #selector(scanBLE), for: .touchUpInside)
        let disconnect = UIButton(type: .system)
        disconnect.setTitle("断开 BLE", for: .normal)
        disconnect.addTarget(self, action: #selector(disconnectBLE), for: .touchUpInside)
        let copy = UIButton(type: .system)
        copy.setTitle("复制日志", for: .normal)
        copy.addTarget(self, action: #selector(copyLog), for: .touchUpInside)
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "语音验证", style: .plain,
            target: self, action: #selector(openVoiceProbe))
        let controls = UIStackView(arrangedSubviews: [scan, disconnect, copy])
        controls.distribution = .fillEqually
        trialButton.setTitle("开始 44 秒大疆按键采样", for: .normal)
        trialButton.addTarget(self, action: #selector(toggleButtonTrial), for: .touchUpInside)
        let mark = UIButton(type: .system)
        mark.setTitle("标记：刚按了麦克风实体键", for: .normal)
        mark.setTitle("已按实体键", for: .normal)
        mark.addTarget(self, action: #selector(markPhysicalButton), for: .touchUpInside)
        let export = UIButton(type: .system)
        export.setTitle("复制采样报告", for: .normal)
        export.addTarget(self, action: #selector(copyTrial), for: .touchUpInside)
        let trialActions = UIStackView(arrangedSubviews: [mark, export])
        trialActions.distribution = .fillEqually
        trialLabel.numberOfLines = 0
        trialLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        let help = UILabel()
        help.text = "先连接 DJI Mic Mini 2，通知就绪后开始采样。按屏幕提示操作实体键，每阶段只操作一次，再点「已按实体键」。同时观察 BLE、系统媒体键和音量变化。采样不录音、不写入麦克风设置。"
        help.font = .systemFont(ofSize: 13)
        help.numberOfLines = 0
        table.dataSource = self
        table.delegate = self
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let stack = UIStackView(arrangedSubviews: [controls, help, trialButton, trialLabel, trialActions, recordButton, table, logView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 40),
            recordButton.heightAnchor.constraint(equalToConstant: 40),
            table.heightAnchor.constraint(equalTo: stack.heightAnchor, multiplier: 0.18)
        ])
        BLEProbe.shared.onChange = { [weak self] in self?.table.reloadData() }
        DeviceDiagnostics.shared.onChange = { [weak self] in self?.refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let trial = BLEButtonTrial.shared
        trial.advance()
        if trial.active {
            trialLabel.text = "第 \(trial.elapsed) / 44 秒：\(trial.instruction)"
            trialLabel.textColor = trial.phase == 0 || trial.phase == 6 ? .secondaryLabel : .systemOrange
            if trial.phase != lastTrialPhase {
                lastTrialPhase = trial.phase
                if trial.phase > 0, trial.phase < 6 { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            }
        } else {
            trialLabel.text = BLEProbe.shared.connectionDescription + "\n采样结束后点「复制按键采样报告」"
            trialLabel.textColor = .label
        }
        trialButton.setTitle(trial.active ? "停止采样并生成报告" : "开始 44 秒大疆按键采样", for: .normal)
        let text = DeviceDiagnostics.shared.text
        if logView.text != text {
            logView.text = text
            if !text.isEmpty { logView.scrollRangeToVisible(NSRange(location: (text as NSString).length - 1, length: 1)) }
        }
        recordButton.setTitle(WearableService.shared.isRecording ? "结束录音并发送" : "开始录音测试", for: .normal)
    }

    @objc private func scanBLE() { BLEProbe.shared.scan() }
    @objc private func openVoiceProbe() {
        if #available(iOS 17.4, *) {
            navigationController?.pushViewController(VoiceConversationProbeController(), animated: true)
        }
    }
    @objc private func disconnectBLE() { BLEProbe.shared.disconnect() }
    @objc private func copyLog() { UIPasteboard.general.string = DeviceDiagnostics.shared.text }
    @objc private func toggleButtonTrial() {
        if BLEButtonTrial.shared.active { BLEButtonTrial.shared.finish(reason: "用户提前结束") }
        else if BLEProbe.shared.canRunButtonTrial {
            lastTrialPhase = -1
            BLEButtonTrial.shared.start(device: BLEProbe.shared.connectionDescription)
        } else {
            let alert = UIAlertController(title: "先连接大疆麦克风", message: "扫描并点选 DJI Mic Mini 2，等待显示通知已就绪。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert, animated: true)
        }
        refresh()
    }
    @objc private func markPhysicalButton() { BLEButtonTrial.shared.mark(); refresh() }
    @objc private func copyTrial() {
        if BLEButtonTrial.shared.active { BLEButtonTrial.shared.finish(reason: "用户导出时结束") }
        UIPasteboard.general.string = (DeviceDiagnostics.shared.text.components(separatedBy: "\n").first ?? "Agent Relay") + "\n" + BLEButtonTrial.shared.lastReport
        refresh()
    }
    @objc private func toggleRecording() {
        guard !BLEButtonTrial.shared.active else { return }
        if WearableService.shared.isRecording { WearableService.shared.stopRecording() }
        else { WearableService.shared.startRecording() }
        refresh()
    }
    @objc private func close() {
        BLEButtonTrial.shared.finish(reason: "关闭测试页")
        BLEProbe.shared.stopScan()
        refreshTimer?.invalidate()
        DeviceDiagnostics.shared.onChange = nil
        BLEProbe.shared.onChange = nil
        dismiss(animated: true)
    }
    deinit { refreshTimer?.invalidate() }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { BLEProbe.shared.devices.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let peripheral = BLEProbe.shared.devices[indexPath.row]
        let signal = BLEProbe.shared.signals[peripheral.identifier] ?? -100
        cell.textLabel?.text = "\(BLEProbe.shared.names[peripheral.identifier] ?? peripheral.name ?? "未命名") · \(signal) dBm"
        cell.detailTextLabel?.text = peripheral.identifier.uuidString
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        BLEProbe.shared.connect(BLEProbe.shared.devices[indexPath.row])
    }
}
