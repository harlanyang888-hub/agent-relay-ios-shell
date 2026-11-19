import UIKit
import CoreBluetooth
import AVFoundation
import AVKit

// 仅记录设备和录音状态，不记录 Cookie、音频或会话内容。
final class DeviceDiagnostics {
    static let shared = DeviceDiagnostics()
    private let key = "device_diagnostics_v1"
    private(set) var lines: [String]
    var onChange: (() -> Void)?
    private var uploadEndpoint: String?
    private var uploadCookie: String?
    private var uploadTimer: Timer?
    private var uploading = false
    private var generation = 0
    private var uploadedGeneration = -1
    private var retryAfter = Date.distantPast
    private let runID = UUID().uuidString
    private var scheduledUpload: DispatchWorkItem?
    private(set) var uploadStatus = "等待登录后上报"
    private var recordingRuntime: [String: Any] = [:]

    func updateRecordingRuntime(recording: Bool, capturedSeconds: Double) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.updateRecordingRuntime(recording: recording, capturedSeconds: capturedSeconds) }
            return
        }
        recordingRuntime = ["recording": recording, "capturedSeconds": capturedSeconds]
        generation += 1
    }

    func configureUpload(endpoint: String, cookie: String?) {
        guard URL(string: endpoint)?.scheme == "https" else { return }
        if uploadEndpoint != endpoint || uploadCookie != cookie { uploadedGeneration = -1 }
        uploadEndpoint = endpoint
        uploadCookie = cookie
        if cookie?.isEmpty != false { uploadStatus = "等待登录后上报" }
        if uploadTimer == nil {
            uploadTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.flushUpload() }
        }
        // Never initialize recording services from inside the logger.
        DispatchQueue.main.async { [weak self] in self?.flushUpload() }
    }

    private func flushUpload() {
        guard !uploading, generation != uploadedGeneration, Date() >= retryAfter,
              let endpoint = uploadEndpoint, let cookie = uploadCookie, !cookie.isEmpty,
              let url = URL(string: endpoint + "/api/client-diagnostics") else { return }
        let sentGeneration = generation
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let now = ISO8601DateFormatter().string(from: Date())
        let entries: [[String: Any]] = lines.suffix(250).map { line in
            let clean = line.replacingOccurrences(of: "(?i)(bearer\\s+|(?:cookie|token|password|authorization)[=:]\\s*)[^\\s]+", with: "$1[redacted]", options: .regularExpression)
            return ["at": String(line.prefix(20)), "uptimeMs": 0, "type": "ios.native", "data": ["message": String(clean.prefix(1000))]]
        }
        let payload: [String: Any] = ["schemaVersion": 1, "generatedAt": now,
            "buildVersion": "\(version) (\(build))", "environment": ["platform": "iOS", "os": UIDevice.current.systemVersion],
            "runtime": recordingRuntime.merging(["runId": runID, "state": UIApplication.shared.applicationState.rawValue]) { _, new in new }, "entries": entries]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 10; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(endpoint, forHTTPHeaderField: "Origin")
        uploading = true
        uploadStatus = "正在上报设备日志"
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Upload device diagnostics") {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        }
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
                guard let self = self else { return }
                self.uploading = false
                if error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   self.uploadEndpoint == endpoint, self.uploadCookie == cookie {
                    self.uploadedGeneration = sentGeneration
                    self.uploadStatus = "最近已上报：" + ISO8601DateFormatter().string(from: Date())
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode
                    self.uploadStatus = code.map { "日志上报 HTTP \($0)，稍后重试" }
                        ?? "日志上报暂不可达，稍后重试"
                    self.retryAfter = Date().addingTimeInterval(30)
                }
            }
        }.resume()
    }

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
        generation += 1
        if lines.count > 250 { lines.removeFirst(lines.count - 250) }
        UserDefaults.standard.set(lines, forKey: key)
        if scheduledUpload == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.scheduledUpload = nil
                self?.flushUpload()
            }
            scheduledUpload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
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
    private var authenticatedIdentity = false
    private var connectionRetry: DispatchWorkItem?
    private var connectionFailures = 0
    private var manuallyDisconnected = false
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
    var isVoiceDeviceReady: Bool { canRunButtonTrial && (!BLERecoveryLab.enabled || authenticatedIdentity) }
    var authorizedButtonIDs: [UUID] {
        guard BLERecoveryLab.usesASK, #available(iOS 18.0, *),
              let binding = accessoryBinding as? RecoveryAccessoryBinding else { return [] }
        return binding.session.accessories.compactMap { $0.bluetoothIdentifier }
    }

    func authorizedButtonName(_ id: UUID) -> String {
        if let peripheral = selected, peripheral.identifier == id,
           peripheral.name?.contains("AgentRelay-Watch") == true { return "relay watch" }
        guard #available(iOS 18.0, *), let binding = accessoryBinding as? RecoveryAccessoryBinding,
              let accessory = binding.session.accessories.first(where: { $0.bluetoothIdentifier == id }) else { return "语音按钮" }
        let name = accessory.displayName
        if name == "Relay 语音手表" || name == "AgentRelay-Watch" { return "relay watch" }
        if name.contains("RN12108") || name.contains("恢复测试") { return "电脑模拟按钮" }
        return name.isEmpty ? "语音按钮" : name
    }

    func addNewAccessory() {
        guard BLERecoveryLab.usesASK, #available(iOS 18.0, *),
              let binding = accessoryBinding as? RecoveryAccessoryBinding else { scan(); return }
        manuallyDisconnected = false
        binding.add()
    }

    func reconnectAuthorizedButton(_ id: UUID) {
        guard authorizedButtonIDs.contains(id) else { return }
        manuallyDisconnected = false
        connectionRetry?.cancel()
        connectionFailures = 0
        if let previous = selected, previous.identifier != id {
            central?.cancelPeripheralConnection(previous)
            selected = nil
            notificationsReady = false
        }
        UserDefaults.standard.set(id.uuidString, forKey: BLERecoveryLab.bindingKey)
        ensureCentral()
        restoreSavedButton()
    }
    var connectionDescription: String {
        guard let peripheral = selected else { return "尚未连接设备" }
        let authentication = BLERecoveryLab.enabled ? " · 加密认证\(authenticatedIdentity ? "已就绪" : "未就绪")" : ""
        return "\(peripheral.name ?? "未命名") · \(peripheral.state == .connected ? "已连接" : "未连接") · 通知\(notificationsReady ? "已就绪" : "未就绪")" + authentication
    }

    private override init() {
        super.init()
        if BLERecoveryLab.usesASK, #available(iOS 18.0, *) {
            let binding = RecoveryAccessoryBinding()
            accessoryBinding = binding
            binding.onAuthorized = { [weak self] id in
                guard let self = self else { return }
                guard !self.manuallyDisconnected else { return }
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
            if manuallyDisconnected {
                manuallyDisconnected = false
                DeviceDiagnostics.shared.log("LAB 重新连接当前已授权按钮，不重复显示添加授权")
                binding.restore()
                return
            }
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
        guard !manuallyDisconnected, central?.state == .poweredOn, testDisconnectUntil == nil else { return }
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
        if data.count == 20, Array(data.prefix(3)) == [65, 82, 3] {
            guard #available(iOS 17.4, *) else { return }
            let watch = WatchVoiceSession.shared
            watch.send = { [weak self, weak peripheral] packet in
                guard let self = self, let peripheral = peripheral,
                      self.selected?.identifier == peripheral.identifier,
                      peripheral.state == .connected else { return }
                if !self.ackWrites.contains(packet) { self.ackWrites.append(packet) }
                self.flushAcknowledgements()
            }
            watch.receive(data)
            return
        }
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
        if error == nil, completed?.count == 17, completed?.last != 4, let event = eventCharacteristic { peripheral.readValue(for: event) }
        flushAcknowledgements()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        guard BLERecoveryLab.enabled else { centralManager(central, didDisconnectPeripheral: peripheral, error: error); return }
        handleDisconnection(central, peripheral: peripheral, error: error, systemReconnecting: isReconnecting)
    }

    private func handleDisconnection(_ central: CBCentralManager, peripheral: CBPeripheral, error: Error?, systemReconnecting: Bool) {
        WatchBatteryStore.shared.disconnected(peripheral.identifier)
        guard peripheral.identifier == selected?.identifier else { return }
        authenticatedIdentity = false
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
            connectionRetry?.cancel()
            connectionFailures = 0
            central.cancelPeripheralConnection(previous)
        }
        selected = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: connectionOptions)
        DeviceDiagnostics.shared.log("BLE 连接 \(peripheral.name ?? "未命名") \(peripheral.identifier)")
    }

    func disconnect() {
        manuallyDisconnected = true
        connectionRetry?.cancel()
        connectionFailures = 0
        testReconnect?.cancel()
        testDisconnectUntil = nil
        finishDisconnectTest()
        guard let peripheral = selected else { return }
        BLEButtonTrial.shared.finish(reason: "用户断开连接")
        central.cancelPeripheralConnection(peripheral)
        selected = nil
        // A transport disconnect must not forget the user's ASK selection.
        if !BLERecoveryLab.usesASK { UserDefaults.standard.removeObject(forKey: BLERecoveryLab.bindingKey) }
        notificationsReady = false
        DeviceDiagnostics.shared.log("BLE 已请求断开")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn, let id = selected?.identifier { WatchBatteryStore.shared.disconnected(id) }
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
        guard !BLERecoveryLab.enabled || peripheral.identifier == selected?.identifier else { return }
        WatchBatteryStore.shared.attach(peripheral.identifier)
        authenticatedIdentity = false
        connectionRetry?.cancel()
        connectionFailures = 0
        DeviceDiagnostics.shared.log("BLE 已连接 \(peripheral.name ?? "未命名")")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DeviceDiagnostics.shared.log("BLE 连接失败 \(String(describing: error))")
        guard BLERecoveryLab.enabled, peripheral.identifier == selected?.identifier,
              central.state == .poweredOn, testDisconnectUntil == nil else { return }
        connectionRetry?.cancel()
        connectionFailures += 1
        guard connectionFailures <= 3 else {
            DeviceDiagnostics.shared.log("LAB 自动重试已达3次；保留当前绑定，等待恢复事件")
            return
        }
        let delay = Double(connectionFailures * 2)
        DeviceDiagnostics.shared.log("LAB 连接重试 id=\(peripheral.identifier) attempt=\(connectionFailures) delay=\(delay)")
        let retry = DispatchWorkItem { [weak self] in
            guard let self = self, self.selected?.identifier == peripheral.identifier,
                  self.central?.state == .poweredOn, peripheral.state == .disconnected,
                  self.testDisconnectUntil == nil else { return }
            self.central.connect(peripheral, options: self.connectionOptions)
        }
        connectionRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
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
        guard peripheral.identifier == selected?.identifier else { return }
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

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral.identifier == selected?.identifier else { return }
        DeviceDiagnostics.shared.log("BLE 服务表已更新，重新发现设备功能")
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        if let error = error { DeviceDiagnostics.shared.log("BLE 特征错误 \(error)"); return }
        for characteristic in service.characteristics ?? [] {
            if service.uuid == buttonService,
               characteristic.uuid == CBUUID(string: "A8D70204-6B44-4E93-A2D5-73F2A34B8180") {
                WatchBatteryStore.shared.attach(peripheral.identifier)
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
                continue
            }
            if BLERecoveryLab.enabled, service.uuid == buttonService {
                if characteristic.uuid == CBUUID(string: BLERecoveryLab.ack) { ackCharacteristic = characteristic }
                if characteristic.uuid == buttonEvent { eventCharacteristic = characteristic }
            }
            DeviceDiagnostics.shared.log("BLE characteristic=\(service.uuid)/\(characteristic.uuid) properties=\(characteristic.properties.rawValue)")
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
            if BLERecoveryLab.enabled, characteristic.uuid == CBUUID(string: BLERecoveryLab.identity) {
                // A subscribed link can still be unencrypted. Retry a protected
                // read after restoration rather than treating subscription as readiness.
                for delay in [1.0, 3.0, 8.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral] in
                        guard let self = self, let peripheral = peripheral,
                              self.selected === peripheral, peripheral.state == .connected,
                              !self.authenticatedIdentity else { return }
                        DeviceDiagnostics.shared.log("BLE 加密认证尚未完成；重试受保护身份读取 delay=\(delay)")
                        peripheral.readValue(for: characteristic)
                    }
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
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
        if characteristic.service?.uuid == buttonService,
           characteristic.uuid == CBUUID(string: "A8D70204-6B44-4E93-A2D5-73F2A34B8180") {
            WatchBatteryStore.shared.receive(characteristic.value, from: peripheral.identifier, error: error)
            DeviceDiagnostics.shared.log("BATTERY \(WatchBatteryStore.shared.title) \(WatchBatteryStore.shared.detail)")
            return
        }
        let service = characteristic.service?.uuid.uuidString ?? "?"
        let data = characteristic.value ?? Data()
        if BLERecoveryLab.enabled, characteristic.uuid == CBUUID(string: BLERecoveryLab.identity) {
            authenticatedIdentity = error == nil && data.count == 16
            DeviceDiagnostics.shared.log("BLE 加密身份验证 ready=\(authenticatedIdentity) bytes=\(data.count) error=\(String(describing: error))")
        }
        if characteristic.service?.uuid == buttonService, characteristic.uuid == buttonEvent {
            if BLERecoveryLab.enabled {
                if error == nil { receiveLabCommand(data, from: peripheral) }
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
    private let microphoneButton = UIButton(type: .system)
    private var inputPicker: AnyObject?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "穿戴设备"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        let scan = UIButton(type: .system)
        scan.setTitle("连接手表 / 按钮", for: .normal)
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
        end.setTitle("结束对话", for: .normal)
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
        if BLERecoveryLab.usesASK { help.text = "BOOT 长按：开始 / 发送本条；短按：暂停 / 继续。PWR 长按：发送并结束对话。中断后的草稿会保留，短按继续、长按发送。首次配对和麦克风授权需要打开 App。" }
        help.font = .systemFont(ofSize: 13)
        help.numberOfLines = 0
        table.dataSource = self
        table.delegate = self
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let linkTest = UIButton(type: .system)
        linkTest.setTitle("断链15秒（验证缓存补交）", for: .normal)
        linkTest.addTarget(self, action: #selector(testLinkLoss), for: .touchUpInside)
        let microphone = microphoneButton
        microphone.setTitle("选择录音麦克风", for: .normal)
        microphone.addTarget(self, action: #selector(chooseMicrophone), for: .touchUpInside)
        let comparison = UIButton(type: .system)
        comparison.setTitle("前台麦克风对照（5 秒）", for: .normal)
        comparison.addTarget(self, action: #selector(compareMicrophone), for: .touchUpInside)
        let pauseResume = UIButton(type: .system)
        pauseResume.setTitle("暂停 / 继续当前录音", for: .normal)
        pauseResume.addTarget(self, action: #selector(pauseResumeRecording), for: .touchUpInside)
        let outbox = UIButton(type: .system)
        outbox.setTitle("待发录音与文件恢复", for: .normal)
        outbox.addTarget(self, action: #selector(showVoiceRecovery), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [controls, microphone] + (BLERecoveryLab.enabled ? [linkTest, comparison] : []) + [help, trialLabel, recordButton] + (BLERecoveryLab.usesASK ? [pauseResume, outbox] : []) + [table, logView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24),
            controls.heightAnchor.constraint(equalToConstant: 40),
            recordButton.heightAnchor.constraint(equalToConstant: 40),
            table.heightAnchor.constraint(equalToConstant: 140),
            logView.heightAnchor.constraint(equalToConstant: 280)
        ])
        BLEProbe.shared.onChange = { [weak self] in self?.table.reloadData() }
        // Service initialization can log synchronously. Defer UI updates so a
        // refresh never re-enters initialization of the same static singleton.
        DeviceDiagnostics.shared.onChange = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
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
            let input = WearableService.shared.recordingInputName
            let inputMode = WearableService.shared.preferredRecordingInputUID == nil
                ? "跟随系统" : (WearableService.shared.preferredRecordingInputName ?? "指定麦克风")
            trialLabel.text! += "\n麦克风设置：\(inputMode)"
            trialLabel.text! += "\n实际录音输入：\(input.isEmpty ? "尚未启用" : input)"
            if WearableService.shared.inputComparisonActive { trialLabel.text! += "\n正在进行五秒前台麦克风对照" }
            if let error = WearableService.shared.recordingInputSelectionError { trialLabel.text! += "\n⚠️ \(error)" }
            if WearableService.shared.isRecording, let warning = WearableService.shared.recordingInputWarning {
                trialLabel.text! += "\n⚠️ \(warning)"
            }
            if BLERecoveryLab.enabled { trialLabel.text! += "\n系统会话启动：\(BLERecoveryLab.immediateSystemStart ? "立即请求（无网络预检）" : "先鉴权再请求（原路径）")" }
            if #available(iOS 17.4, *) { trialLabel.text! += "\n" + VoiceConversationProbe.shared.status }
            if #available(iOS 17.4, *), BLERecoveryLab.usesASK { trialLabel.text! += "\n" + WatchVoiceSession.shared.summary }
            trialLabel.text! += "\n" + DeviceDiagnostics.shared.uploadStatus
            trialLabel.textColor = .label
        }
        trialButton.setTitle(trial.active ? "停止采样并生成报告" : "开始 44 秒大疆按键采样", for: .normal)
        let text = DeviceDiagnostics.shared.text
        if logView.text != text {
            logView.text = text
            if !text.isEmpty { logView.scrollRangeToVisible(NSRange(location: (text as NSString).length - 1, length: 1)) }
        }
        recordButton.setTitle(WearableService.shared.isRecording ? "结束本轮并发送" : "开始说话", for: .normal)
        if #available(iOS 17.4, *), BLERecoveryLab.usesASK, WatchVoiceSession.shared.hasDraft {
            recordButton.setTitle("发送当前录音（保留对话）", for: .normal)
        }
    }

    @objc private func scanBLE() {
        let ids = BLEProbe.shared.authorizedButtonIDs
        guard !ids.isEmpty else { BLEProbe.shared.addNewAccessory(); return }
        let choices = UIAlertController(title: "连接语音设备", message: "第一次连接 ESP32 手表，请选择“配对新手表 / 按钮”。下方是以前授权过的设备。", preferredStyle: .actionSheet)
        choices.addAction(UIAlertAction(title: "配对新手表 / 按钮", style: .default) { _ in BLEProbe.shared.addNewAccessory() })
        let saved = UserDefaults.standard.string(forKey: BLERecoveryLab.bindingKey)
        for (index, id) in ids.enumerated() {
            let title = "\(BLEProbe.shared.authorizedButtonName(id)) · \(index + 1)\(id.uuidString == saved ? "（当前）" : "")"
            choices.addAction(UIAlertAction(title: title, style: .default) { _ in BLEProbe.shared.reconnectAuthorizedButton(id) })
        }
        choices.addAction(UIAlertAction(title: "取消", style: .cancel))
        choices.popoverPresentationController?.sourceView = view
        choices.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(choices, animated: true)
    }
    @objc private func chooseMicrophone() {
        guard !WearableService.shared.inputComparisonActive else { return }
        let session = WearableService.shared.recordingAudioSession
        if #available(iOS 26.0, *) {
            do {
                // Configure the same input-capable category used by watch calls.
                // No recorder, draft, upload or call is started by this settings button.
                // Never reconfigure an opening/active LCK call from the settings UI.
                if VoiceConversationProbe.shared.canChangeLaunchPath {
                    try session.setCategory(.playAndRecord, mode: .voiceChat,
                        options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
                }
                try WearableService.shared.useSystemRecordingInputPicker()
            }
            catch {
                DeviceDiagnostics.shared.log("Audio input picker preparation failed: \(error.localizedDescription)")
                let alert = UIAlertController(title: "麦克风设置未就绪", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "知道了", style: .default))
                present(alert, animated: true)
                return
            }
            let picker: AVInputPickerInteraction
            if let existing = inputPicker as? AVInputPickerInteraction, existing.audioSession === session { picker = existing }
            else {
                if let previous = inputPicker as? AVInputPickerInteraction { microphoneButton.removeInteraction(previous) }
                picker = AVInputPickerInteraction(audioSession: session)
                picker.delegate = self
                microphoneButton.addInteraction(picker)
                inputPicker = picker
            }
            DeviceDiagnostics.shared.log("Audio input native picker presented recording=\(WearableService.shared.isRecording) actual=\(session.currentRoute.inputs.map { $0.portName })")
            picker.present()
            return
        }
        let choices = UIAlertController(title: "录音麦克风", message: "默认跟随 iPhone 的系统输入；也可指定下面任意麦克风，对下一段生效。以实际输入为准；指定设备不可用时会提示，不自动替换。", preferredStyle: .actionSheet)
        choices.addAction(UIAlertAction(title: "跟随系统" + (WearableService.shared.preferredRecordingInputUID == nil ? "（已选）" : ""), style: .default) { _ in
            WearableService.shared.preferredRecordingInputUID = nil
            DeviceDiagnostics.shared.log("Audio input preference=跟随系统")
        })
        for input in session.availableInputs ?? [] {
            let title = input.portName + (input.uid == WearableService.shared.preferredRecordingInputUID ? "（已选）" : "")
            choices.addAction(UIAlertAction(title: title, style: .default) { _ in
                WearableService.shared.preferredRecordingInputUID = input.uid
                WearableService.shared.preferredRecordingInputName = input.portName
                DeviceDiagnostics.shared.log("Audio input preference=\(input.portName)")
            })
        }
        choices.addAction(UIAlertAction(title: "取消", style: .cancel))
        choices.popoverPresentationController?.sourceView = view
        choices.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(choices, animated: true)
    }
    @objc private func testLinkLoss() { BLEProbe.shared.simulateLinkLoss() }
    @objc private func compareMicrophone() {
        if WearableService.shared.inputComparisonActive { WearableService.shared.stopInputComparison(); return }
        guard #available(iOS 17.4, *), VoiceConversationProbe.shared.canChangeLaunchPath,
              !WearableService.shared.isListening else {
            let alert = UIAlertController(title: "先结束当前录音和系统会话", message: "对照测试会录制五秒本地音频，不建立系统通话，也不发送给 Agent。请保持两台音频设备连接。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert, animated: true)
            return
        }
        let choices = UIAlertController(title: "麦克风路由对照", message: "保持两台音频设备连接，每项测试五秒并自动结束，仅本地保存。“仅录音”会暂时停止其他声音，测试结束后释放音频。先测试仅录音，再测最小通话配置。", preferredStyle: .actionSheet)
        choices.addAction(UIAlertAction(title: "仅录音（5秒）", style: .default) { _ in
            WearableService.shared.startInputComparison(profile: .inputOnly)
        })
        choices.addAction(UIAlertAction(title: "最小通话配置（5秒）", style: .default) { _ in
            WearableService.shared.startInputComparison(profile: .hfpOnly)
        })
        choices.addAction(UIAlertAction(title: "原配置（5秒）", style: .default) { _ in
            WearableService.shared.startInputComparison(profile: .baseline)
        })
        choices.addAction(UIAlertAction(title: "取消", style: .cancel))
        choices.popoverPresentationController?.sourceView = view
        choices.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(choices, animated: true)
    }
    @objc private func openVoiceProbe() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                DeviceDiagnostics.shared.log(granted ? "麦克风已授权；连接按钮后可按硬件键开始" : "麦克风未授权，请在系统设置中允许")
            }
        }
    }
    @objc private func endConversation() {
        if #available(iOS 17.4, *) {
            if BLERecoveryLab.usesASK { WatchVoiceSession.shared.phoneEnd() }
            else { VoiceConversationProbe.shared.end() }
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
        if #available(iOS 17.4, *) {
            if BLERecoveryLab.usesASK { WatchVoiceSession.shared.phoneToggle() }
            else { VoiceConversationProbe.shared.handleDedicatedButton() }
        }
        refresh()
    }
    @objc private func pauseResumeRecording() {
        guard #available(iOS 17.4, *), BLERecoveryLab.usesASK else { return }
        if WearableService.shared.isRecording { WatchVoiceSession.shared.phonePause() }
        else if WatchVoiceSession.shared.isPausedDraft { WatchVoiceSession.shared.phoneStart() }
        refresh()
    }
    @objc func showVoiceRecovery() {
        guard #available(iOS 17.4, *) else { return }
        let watch = WatchVoiceSession.shared
        let list = UIAlertController(title: "录音待发箱", message: "待发文件会在网络和登录恢复后继续发送。结果未知的文件只核对回执，不自动重发。", preferredStyle: .actionSheet)
        list.addAction(UIAlertAction(title: "重试待发文件", style: .default) { _ in watch.retryPendingDeliveries() })
        for item in watch.recoveryItems {
            let labels = ["pending": "待发送", "sending": "正在发送", "uncertain": "结果未确认", "needsReview": "需要处理", "unverified": "原始尾段待核对"]
            list.addAction(UIAlertAction(title: "\(labels[item.state] ?? item.state) · \(item.url.lastPathComponent.prefix(30))", style: .default) { [weak self] _ in
                guard let self = self else { return }
                let actions = UIAlertController(title: "恢复录音", message: item.url.lastPathComponent, preferredStyle: .actionSheet)
                if item.canVerify {
                    actions.addAction(UIAlertAction(title: "核对服务器回执", style: .default) { _ in watch.verifyDeliveryReceipt(item.id) })
                }
                actions.addAction(UIAlertAction(title: "导出保留的录音文件", style: .default) { _ in
                    let share = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = self.view
                    self.present(share, animated: true)
                })
                actions.addAction(UIAlertAction(title: "取消", style: .cancel))
                actions.popoverPresentationController?.sourceView = self.view
                self.present(actions, animated: true)
            })
        }
        list.addAction(UIAlertAction(title: "关闭", style: .cancel))
        list.popoverPresentationController?.sourceView = view
        present(list, animated: true)
    }
    @objc private func close() {
        WearableService.shared.stopInputComparison()
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

@available(iOS 26.0, *)
extension DeviceDiagnosticsViewController: AVInputPickerInteraction.Delegate {
    func inputPickerInteractionDidEndDismissing(_ inputPickerInteraction: AVInputPickerInteraction) {
        // A picker dismissal isn't a selection callback. Ask the user to confirm
        // the actual route instead of silently persisting a cancelled/old choice.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.view.window != nil,
                  self.presentedViewController == nil,
                  UIApplication.shared.applicationState == .active else { return }
            let session = inputPickerInteraction.audioSession
            guard let input = session.currentRoute.inputs.first else {
                DeviceDiagnostics.shared.log("Audio input picker dismissed without active input; no preference saved")
                return
            }
            let alert = UIAlertController(title: "记住录音麦克风", message: "当前实际输入：\(input.portName)。设为手表录音麦克风后，下次按手表会自动请求恢复这个设备；请再验证一次锁屏录音。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "记住此麦克风", style: .default) { _ in
                WearableService.shared.preferredRecordingInputUID = input.uid
                WearableService.shared.preferredRecordingInputName = input.portName
                DeviceDiagnostics.shared.log("Audio input picker confirmed name=\(input.portName) uid=\(input.uid)")
                self.refresh()
            })
            alert.addAction(UIAlertAction(title: "仅本次使用", style: .cancel))
            self.present(alert, animated: true)
        }
    }
}
