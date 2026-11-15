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
    private let buttonService = CBUUID(string: BLERecoveryLab.enabled ? BLERecoveryLab.service : "A8D70100-6B44-4E93-A2D5-73F2A34B8180")
    private let buttonEvent = CBUUID(string: BLERecoveryLab.enabled ? BLERecoveryLab.event : "A8D70101-6B44-4E93-A2D5-73F2A34B8180")
    private var accessoryBinding: AnyObject?
    private var eventCharacteristic: CBCharacteristic?
    private var ackCharacteristic: CBCharacteristic?
    private let receipts = BLELabReceipts()
    private var pendingCommandKey: String?
    private var ackWrites: [Data] = []
    private var writingAck = false
    private var testDisconnectUntil: Date?
    private var testReconnect: DispatchWorkItem?
    private var testBackgroundTask: UIBackgroundTaskIdentifier = .invalid
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
        if BLERecoveryLab.usesASK, #available(iOS 18.0, *) {
            let binding = RecoveryAccessoryBinding()
            accessoryBinding = binding
            binding.onAuthorized = { [weak self] id in
                guard let self = self else { return }
                if let old = self.selected, old.identifier != id {
                    self.central?.cancelPeripheralConnection(old)
                    self.selected = nil
                    self.notificationsReady = false
                }
                UserDefaults.standard.set(id.uuidString, forKey: BLERecoveryLab.bindingKey)
                self.ensureCentral()
                self.restoreSavedButton()
            }
            binding.onBeforePicker = { [weak self] in
                self?.testReconnect?.cancel()
                self?.testDisconnectUntil = nil
                self?.finishDisconnectTest()
                if let selected = self?.selected { self?.central?.cancelPeripheralConnection(selected) }
                self?.selected?.delegate = nil
                self?.selected = nil
                self?.central?.delegate = nil
                self?.central = nil
                self?.notificationsReady = false
                self?.eventCharacteristic = nil
                self?.ackCharacteristic = nil
                self?.ackWrites.removeAll()
                self?.writingAck = false
            }
            binding.onDismiss = { [weak binding] in binding?.restore() }
            binding.start()
        } else { ensureCentral() }
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
        if BLERecoveryLab.usesASK, #available(iOS 18.0, *), let binding = accessoryBinding as? RecoveryAccessoryBinding {
            binding.add()
            return
        }
        scanningRequested = true
        guard central?.state == .poweredOn else {
            DeviceDiagnostics.shared.log("BLE 等待蓝牙就绪，state=\(central.state.rawValue)")
            return
        }
        devices.removeAll()
        names.removeAll()
        signals.removeAll()
        central.scanForPeripherals(withServices: [buttonService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DeviceDiagnostics.shared.log("BLE 扫描专用语音按钮（30 秒）")
        scanTimeout?.invalidate()
        scanTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in self?.stopScan() }
        onChange?()
    }

    private func ensureCentral() {
        guard central == nil else { return }
        let identifier = BLERecoveryLab.enabled ? "agent-relay-ble-recovery-v2" : "agent-relay-ble-probe-v1"
        DeviceDiagnostics.shared.log("LAB 创建蓝牙管理器 restoreID=\(identifier) ASK=\(BLERecoveryLab.usesASK)")
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: identifier])
    }

    private var connectionOptions: [String: Any]? {
        if BLERecoveryLab.enabled, #available(iOS 17.0, *) { return [CBConnectPeripheralOptionEnableAutoReconnect: true] }
        return nil
    }

    private func restoreSavedButton() {
        guard central?.state == .poweredOn, testDisconnectUntil == nil else { return }
        if let selected = selected {
            if selected.state == .connected && !notificationsReady { selected.discoverServices([buttonService]) }
            else if selected.state == .disconnected { central.connect(selected, options: connectionOptions) }
            return
        }
        guard let saved = UserDefaults.standard.string(forKey: BLERecoveryLab.bindingKey), let id = UUID(uuidString: saved),
              let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        DeviceDiagnostics.shared.log("BLE 自动恢复已绑定按钮 \(id)")
        connect(peripheral)
    }

    func simulateLinkLoss() {
        guard BLERecoveryLab.enabled, let peripheral = selected, peripheral.state == .connected else { return }
        testReconnect?.cancel()
        testDisconnectUntil = Date().addingTimeInterval(15)
        notificationsReady = false
        central.cancelPeripheralConnection(peripheral)
        testBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BLE link recovery test") { [weak self] in self?.finishDisconnectTest() }
        DeviceDiagnostics.shared.log("LAB 主动断链15秒；现在可锁屏并在电脑排队开始命令。本项不代表强退唤起")
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.selected?.identifier == peripheral.identifier else { return }
            self.testDisconnectUntil = nil
            if peripheral.state == .connected || peripheral.state == .connecting {
                self.finishDisconnectTest()
                return
            }
            self.central?.connect(peripheral, options: self.connectionOptions)
            DeviceDiagnostics.shared.log("LAB 已提交恢复连接请求，等待系统连接回调")
        }
        testReconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func finishDisconnectTest() {
        if testBackgroundTask != .invalid { UIApplication.shared.endBackgroundTask(testBackgroundTask); testBackgroundTask = .invalid }
    }

    private func receiveLabCommand(_ data: Data, from peripheral: CBPeripheral) {
        guard !data.isEmpty, notificationsReady, ackCharacteristic != nil else { return }
        guard let command = BLELabCommand(data) else { DeviceDiagnostics.shared.log("LAB 拒绝无效命令"); return }
        if let cached = receipts.result(for: command) {
            DeviceDiagnostics.shared.log("LAB 重复命令 id=\(command.key)，只补确认，不重复执行")
            queueAcknowledgement(command, status: cached)
            return
        }
        if command.expired {
            receipts.record(command, status: 3)
            queueAcknowledgement(command, status: 3)
            DeviceDiagnostics.shared.log("LAB 过期命令 id=\(command.key)，不录音")
            return
        }
        if let pending = pendingCommandKey {
            if pending == command.key { queueAcknowledgement(command, status: 4) }
            return
        }
        pendingCommandKey = command.key
        queueAcknowledgement(command, status: 4)
        DeviceDiagnostics.shared.log("LAB 收到命令 id=\(command.key) action=\(command.action.rawValue) pid=\(ProcessInfo.processInfo.processIdentifier) state=\(UIApplication.shared.applicationState.rawValue)")
        guard #available(iOS 17.4, *) else { pendingCommandKey = nil; queueAcknowledgement(command, status: 2); return }
        VoiceConversationProbe.shared.executeLabCommand(command) { [weak self] success, message in
            guard let self = self else { return }
            let status: UInt8 = success ? 1 : 2
            self.receipts.record(command, status: status)
            self.pendingCommandKey = nil
            self.queueAcknowledgement(command, status: status)
            DeviceDiagnostics.shared.log("LAB 命令执行结果 id=\(command.key) success=\(success) detail=\(message)")
        }
    }

    private func queueAcknowledgement(_ command: BLELabCommand, status: UInt8) {
        guard selected?.state == .connected, ackCharacteristic != nil else { return }
        let data = command.acknowledgement(status)
        if !ackWrites.contains(data) { ackWrites.append(data) }
        flushAcknowledgements()
    }

    private func flushAcknowledgements() {
        guard !writingAck, let first = ackWrites.first, let characteristic = ackCharacteristic,
              let selected = selected, selected.state == .connected else { return }
        writingAck = true
        selected.writeValue(first, for: characteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == selected?.identifier, characteristic.uuid == CBUUID(string: BLERecoveryLab.ack) else { return }
        writingAck = false
        let completed = ackWrites.isEmpty ? nil : ackWrites.removeFirst()
        DeviceDiagnostics.shared.log("LAB ACK 写入结果 error=\(String(describing: error))")
        if error == nil, completed?.last != 4, let event = eventCharacteristic { peripheral.readValue(for: event) }
        flushAcknowledgements()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        guard BLERecoveryLab.enabled else { centralManager(central, didDisconnectPeripheral: peripheral, error: error); return }
        handleDisconnection(central, peripheral: peripheral, error: error, systemReconnecting: isReconnecting)
    }

    private func handleDisconnection(_ central: CBCentralManager, peripheral: CBPeripheral, error: Error?, systemReconnecting: Bool) {
        guard peripheral.identifier == selected?.identifier else { return }
        notificationsReady = false
        eventCharacteristic = nil
        ackCharacteristic = nil
        ackWrites.removeAll()
        writingAck = false
        DeviceDiagnostics.shared.log("LAB 连接断开 systemReconnecting=\(systemReconnecting) test=\(testDisconnectUntil != nil) error=\(String(describing: error))")
        if let until = testDisconnectUntil, until > Date() { return }
        if !systemReconnecting { central.connect(peripheral, options: connectionOptions) }
    }

    @objc func stopScan() {
        scanningRequested = false
        scanTimeout?.invalidate()
        scanTimeout = nil
        central?.stopScan()
    }

    func connect(_ peripheral: CBPeripheral) {
        if BLERecoveryLab.usesASK, #available(iOS 18.0, *), let binding = accessoryBinding as? RecoveryAccessoryBinding {
            guard binding.session.accessories.contains(where: { $0.bluetoothIdentifier == peripheral.identifier }) else { return }
        }
        if testDisconnectUntil != nil {
            testReconnect?.cancel()
            testDisconnectUntil = nil
            finishDisconnectTest()
            DeviceDiagnostics.shared.log("LAB 手动连接取消15秒断链测试，避免重复恢复连接")
        }
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
        central.connect(peripheral, options: connectionOptions)
        DeviceDiagnostics.shared.log("BLE 连接 \(peripheral.name ?? "未命名") \(peripheral.identifier)")
    }

    func disconnect() {
        testReconnect?.cancel()
        testDisconnectUntil = nil
        finishDisconnectTest()
        guard let peripheral = selected else { return }
        BLEButtonTrial.shared.finish(reason: "用户断开连接")
        central.cancelPeripheralConnection(peripheral)
        selected = nil
        UserDefaults.standard.removeObject(forKey: BLERecoveryLab.bindingKey)
        notificationsReady = false
        DeviceDiagnostics.shared.log("BLE 已请求断开")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DeviceDiagnostics.shared.log("BLE state=\(central.state.rawValue)")
        if central.state == .poweredOn { restoreSavedButton() }
        if central.state == .poweredOn, scanningRequested { scan() }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let saved = UserDefaults.standard.string(forKey: BLERecoveryLab.bindingKey)
        selected = BLERecoveryLab.enabled ? restored.first(where: { $0.identifier.uuidString == saved }) : restored.first
        for peripheral in restored where !BLERecoveryLab.enabled || peripheral.identifier.uuidString == saved {
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
        if BLERecoveryLab.enabled { handleDisconnection(central, peripheral: peripheral, error: error, systemReconnecting: false); return }
        if peripheral.identifier == selected?.identifier {
            notificationsReady = false
            BLEButtonTrial.shared.event("DISCONNECT error=\(String(describing: error))")
            BLEButtonTrial.shared.finish(reason: "设备断开，采样未完成")
        }
        DeviceDiagnostics.shared.log("BLE 断开 \(peripheral.identifier) error=\(String(describing: error))")
        if peripheral.identifier == selected?.identifier,
           peripheral.services?.contains(where: { $0.uuid == buttonService }) == true {
            DeviceDiagnostics.shared.log("BLE 专用按钮等待重连")
            if let until = testDisconnectUntil, until > Date() { return }
            central.connect(peripheral, options: connectionOptions)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { DeviceDiagnostics.shared.log("BLE 服务错误 \(error)"); return }
        for service in peripheral.services ?? [] {
            if service.uuid == buttonService {
                UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: BLERecoveryLab.bindingKey)
                names[peripheral.identifier] = BLERecoveryLab.enabled ? "Agent Relay 恢复测试按钮" : "Agent Relay 电脑按钮"
                onChange?()
            }
            DeviceDiagnostics.shared.log("BLE service=\(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error { DeviceDiagnostics.shared.log("BLE 特征错误 \(error)"); return }
        for characteristic in service.characteristics ?? [] {
            if BLERecoveryLab.enabled, service.uuid == buttonService {
                if characteristic.uuid == CBUUID(string: BLERecoveryLab.ack) { ackCharacteristic = characteristic }
                if characteristic.uuid == buttonEvent { eventCharacteristic = characteristic }
            }
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
        if BLERecoveryLab.enabled, characteristic.uuid == buttonEvent, notificationsReady {
            peripheral.readValue(for: characteristic)
            if testDisconnectUntil == nil { finishDisconnectTest() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        let service = characteristic.service?.uuid.uuidString ?? "?"
        let data = characteristic.value ?? Data()
        if characteristic.service?.uuid == buttonService, characteristic.uuid == buttonEvent {
            if BLERecoveryLab.enabled {
                receiveLabCommand(data, from: peripheral)
                return
            }
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
        title = "穿戴设备"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        let scan = UIButton(type: .system)
        scan.setTitle("添加按钮", for: .normal)
        scan.addTarget(self, action: #selector(scanBLE), for: .touchUpInside)
        let disconnect = UIButton(type: .system)
        disconnect.setTitle("断开按钮", for: .normal)
        disconnect.addTarget(self, action: #selector(disconnectBLE), for: .touchUpInside)
        let copy = UIButton(type: .system)
        copy.setTitle("复制日志", for: .normal)
        copy.addTarget(self, action: #selector(copyLog), for: .touchUpInside)
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "麦克风授权", style: .plain,
            target: self, action: #selector(openVoiceProbe))
        let end = UIButton(type: .system)
        end.setTitle("结束并发送", for: .normal)
        end.addTarget(self, action: #selector(endConversation), for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [scan, disconnect, end, copy])
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
        help.text = "首次使用先登录、授权麦克风并添加按钮。之后按硬件键自动建立语音会话并开始说话，再按结束本轮并发送。锁屏和其他 App 中也可尝试触发。iOS 18 手动划掉 App 后需重新打开。"
        if BLERecoveryLab.enabled { help.text = "恢复链路测试 · \(BLERecoveryLab.usesASK ? "ASK 系统授权" : "普通蓝牙恢复")。连接电脑恢复模拟器后，可锁屏点电脑的开始/结束。断链15秒仅验证重连与补交；iOS 18 强退后仍需手动重开。" }
        help.font = .systemFont(ofSize: 13)
        help.numberOfLines = 0
        table.dataSource = self
        table.delegate = self
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let linkTest = UIButton(type: .system)
        linkTest.setTitle("断链15秒（验证缓存补交）", for: .normal)
        linkTest.addTarget(self, action: #selector(testLinkLoss), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [controls] + (BLERecoveryLab.enabled ? [linkTest] : []) + [help, trialLabel, recordButton, table, logView])
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
            trialLabel.text = BLEProbe.shared.connectionDescription
            if #available(iOS 17.4, *) { trialLabel.text! += "\n" + VoiceConversationProbe.shared.status }
            trialLabel.textColor = .label
        }
        trialButton.setTitle(trial.active ? "停止采样并生成报告" : "开始 44 秒大疆按键采样", for: .normal)
        let text = DeviceDiagnostics.shared.text
        if logView.text != text {
            logView.text = text
            if !text.isEmpty { logView.scrollRangeToVisible(NSRange(location: (text as NSString).length - 1, length: 1)) }
        }
        recordButton.setTitle(WearableService.shared.isRecording ? "结束本轮并发送" : "开始说话", for: .normal)
    }

    @objc private func scanBLE() { BLEProbe.shared.scan() }
    @objc private func testLinkLoss() { BLEProbe.shared.simulateLinkLoss() }
    @objc private func openVoiceProbe() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                DeviceDiagnostics.shared.log(granted ? "麦克风已授权；连接按钮后可按硬件键开始" : "麦克风未授权，请在系统设置中允许")
            }
        }
    }
    @objc private func endConversation() {
        if #available(iOS 17.4, *) { VoiceConversationProbe.shared.end() }
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
        if #available(iOS 17.4, *) { VoiceConversationProbe.shared.handleDedicatedButton() }
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
