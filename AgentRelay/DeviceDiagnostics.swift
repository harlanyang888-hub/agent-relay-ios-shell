import UIKit
import CoreBluetooth
import AVFoundation
import AccessorySetupKit

@available(iOS 18.0, *)
private final class HardwareAccessoryBinding {
    let session = ASAccessorySession()
    private(set) var ready = false
    var onAuthorized: ((UUID) -> Void)?
    var onRemoved: ((UUID) -> Void)?
    var onChange: (() -> Void)?
    var onBeforePicker: (() -> Void)?
    private(set) var status = "正在读取系统设备授权"
    private var presenting = false
    private var migrating = false

    func start() {
        session.activate(on: .main) { [weak self] event in
            guard let self = self else { return }
            DeviceDiagnostics.shared.log("ASK event=\(event.eventType.rawValue) error=\(String(describing: event.error))")
            switch event.eventType {
            case .activated:
                self.ready = true
                self.status = self.session.accessories.isEmpty ? "尚未系统授权，请添加按钮" : "系统设备授权已恢复"
                let saved = UserDefaults.standard.string(forKey: "relay_dedicated_button_id")
                let accessory = self.session.accessories.first(where: { $0.bluetoothIdentifier?.uuidString == saved }) ?? self.session.accessories.first
                if let id = accessory?.bluetoothIdentifier { self.onAuthorized?(id) }
            case .accessoryAdded, .accessoryChanged:
                guard !self.migrating else { self.onChange?(); return }
                if let id = event.accessory?.bluetoothIdentifier {
                    self.status = "设备已获系统授权"
                    self.onAuthorized?(id)
                }
            case .accessoryRemoved:
                self.status = "系统设备授权已移除"
                if let id = event.accessory?.bluetoothIdentifier { self.onRemoved?(id) }
            case .invalidated:
                self.ready = false
                self.status = "系统设备会话失效，请重新打开 App"
            case .pickerDidDismiss:
                self.presenting = false
                if self.session.accessories.isEmpty { self.status = "尚未完成系统授权，请重试添加按钮" }
            case .pickerDidPresent:
                self.status = "请在苹果系统弹窗中确认设备"
            case .migrationComplete:
                self.migrating = false
                self.status = "旧设备已迁移到系统授权"
                if let id = self.session.accessories.first?.bluetoothIdentifier { self.onAuthorized?(id) }
            default: break
            }
            self.onChange?()
        }
    }

    func addOrReconnect() {
        guard ready else {
            DeviceDiagnostics.shared.log("ASK 尚未激活，暂不能显示授权")
            return
        }
        guard !presenting else {
            DeviceDiagnostics.shared.log("ASK 正在等待系统选择器，请勿重复添加")
            return
        }
        guard UIApplication.shared.applicationState == .active,
              UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) else {
            status = "请保持穿戴设备页面在前台，再添加按钮"
            DeviceDiagnostics.shared.log("ASK picker deferred state=\(UIApplication.shared.applicationState.rawValue) scenes=\(UIApplication.shared.connectedScenes.count)")
            onChange?()
            return
        }
        UserDefaults.standard.set(false, forKey: "relay_button_connection_paused")
        let saved = UserDefaults.standard.string(forKey: "relay_dedicated_button_id")
        // “添加”始终允许选择当前设备；旧设备重连由后台恢复逻辑负责。
        let image = UIImage(systemName: "dot.radiowaves.left.and.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 96))!
            .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        let productImage = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { _ in
            image.draw(in: CGRect(x: 16, y: 16, width: 128, height: 128))
        }
        let discovery = ASDiscoveryDescriptor()
        discovery.bluetoothServiceUUID = CBUUID(string: "A8D70100-6B44-4E93-A2D5-73F2A34B8180")
        var items = [ASPickerDisplayItem(name: "Agent Relay 语音按钮", productImage: productImage, descriptor: discovery)]
        if session.accessories.isEmpty, let saved = saved, let id = UUID(uuidString: saved) {
            let descriptor = ASDiscoveryDescriptor()
            descriptor.bluetoothServiceUUID = CBUUID(string: "A8D70100-6B44-4E93-A2D5-73F2A34B8180")
            let migration = ASMigrationDisplayItem(name: "之前连接的 Agent Relay 按钮", productImage: productImage, descriptor: descriptor)
            migration.peripheralIdentifier = id
            items = [migration]
            migrating = true
            DeviceDiagnostics.shared.log("ASK 迁移之前连接的设备 id=\(id)")
        } else {
            migrating = false
            DeviceDiagnostics.shared.log("ASK 发现当前广播（专用服务 UUID，不按缓存名称筛选），已有授权数=\(session.accessories.count)")
        }
        presenting = true
        status = "正在请求系统授权，等待设备选择器"
        onChange?()
        onBeforePicker?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            guard UIApplication.shared.applicationState == .active else { self.presenting = false; return }
            DeviceDiagnostics.shared.log("ASK picker request state=\(UIApplication.shared.applicationState.rawValue) activeScenes=\(UIApplication.shared.connectedScenes.filter { $0.activationState == .foregroundActive }.count)")
            self.session.showPicker(for: items) { [weak self] error in
            DeviceDiagnostics.shared.log("ASK picker completion error=\(String(describing: error))")
            self?.presenting = false
            if let error = error {
                self?.migrating = false
                self?.status = "设备授权未完成：\(error.localizedDescription)"
                let ns = error as NSError
                DeviceDiagnostics.shared.log("ASK picker failed domain=\(ns.domain) code=\(ns.code) state=\(UIApplication.shared.applicationState.rawValue) detail=\(ns.userInfo)")
            }
            self?.onChange?()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, self.presenting, self.session.accessories.isEmpty else { return }
            self.status = "系统授权仍未完成，请复制日志；暂不能将此设备视为已绑定"
            DeviceDiagnostics.shared.log("ASK 选择器等待超过30秒，未获得系统授权 state=\(UIApplication.shared.applicationState.rawValue)")
            self.onChange?()
        }
    }
}

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
    private var accessoryBinding: AnyObject?
    private var reconnectWork: DispatchWorkItem?
    var onChange: (() -> Void)?
    var canRunButtonTrial: Bool { selected?.state == .connected && notificationsReady }
    var connectionDescription: String {
        guard let peripheral = selected else {
            if #available(iOS 18.0, *), let binding = accessoryBinding as? HardwareAccessoryBinding { return binding.status }
            return "尚未连接设备"
        }
        let connection: String
        switch peripheral.state {
        case .connected: connection = "已连接"
        case .connecting: connection = "已授权，正在连接；若设备身份已变化，请添加当前设备"
        default: connection = "未连接"
        }
        return "\(peripheral.name ?? "未命名") · \(connection) · 通知\(notificationsReady ? "已就绪" : "未就绪")"
    }

    private override init() {
        super.init()
        if #available(iOS 18.0, *) {
            let binding = HardwareAccessoryBinding()
            accessoryBinding = binding
            binding.onAuthorized = { [weak self] id in
                if let previous = self?.selected, previous.identifier != id {
                    self?.central?.cancelPeripheralConnection(previous)
                    self?.selected = nil
                    self?.notificationsReady = false
                }
                UserDefaults.standard.set(id.uuidString, forKey: "relay_dedicated_button_id")
                self?.restoreDedicatedButton()
            }
            binding.onRemoved = { [weak self] id in
                guard UserDefaults.standard.string(forKey: "relay_dedicated_button_id") == id.uuidString else { return }
                self?.disconnect()
                UserDefaults.standard.removeObject(forKey: "relay_dedicated_button_id")
                self?.onChange?()
            }
            binding.onChange = { [weak self] in self?.onChange?() }
            binding.onBeforePicker = { [weak self] in self?.releaseCentralForSetup() }
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
        if #available(iOS 18.0, *), let binding = accessoryBinding as? HardwareAccessoryBinding {
            binding.addOrReconnect()
            return
        }
        ensureCentral()
        scanningRequested = true
        guard central.state == .poweredOn else {
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

    @objc func stopScan() {
        scanningRequested = false
        scanTimeout?.invalidate()
        scanTimeout = nil
        central?.stopScan()
    }

    private func ensureCentral() {
        guard central == nil else { return }
        DeviceDiagnostics.shared.log("BLE 创建管理器（授权恢复／连接阶段）")
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "agent-relay-ble-probe-v1"
        ])
    }

    private func releaseCentralForSetup() {
        reconnectWork?.cancel()
        stopScan()
        if let peripheral = selected { central?.cancelPeripheralConnection(peripheral) }
        selected?.delegate = nil
        selected = nil
        notificationsReady = false
        central?.delegate = nil
        central = nil
        DeviceDiagnostics.shared.log("BLE 已释放旧管理器，准备系统授权")
    }

    func connect(_ peripheral: CBPeripheral) {
        if #available(iOS 18.0, *), let binding = accessoryBinding as? HardwareAccessoryBinding {
            guard binding.session.accessories.contains(where: { $0.bluetoothIdentifier == peripheral.identifier }) else {
                DeviceDiagnostics.shared.log("BLE 设备尚未系统授权，请添加按钮")
                return
            }
        }
        reconnectWork?.cancel()
        UserDefaults.standard.set(false, forKey: "relay_button_connection_paused")
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
        reconnectWork?.cancel()
        stopScan()
        UserDefaults.standard.set(true, forKey: "relay_button_connection_paused")
        guard let peripheral = selected else { return }
        BLEButtonTrial.shared.finish(reason: "用户断开连接")
        central.cancelPeripheralConnection(peripheral)
        selected = nil
        notificationsReady = false
        DeviceDiagnostics.shared.log("BLE 已请求断开")
        onChange?()
    }

    private func restoreDedicatedButton() {
        guard !UserDefaults.standard.bool(forKey: "relay_button_connection_paused"),
              let text = UserDefaults.standard.string(forKey: "relay_dedicated_button_id"),
              let id = UUID(uuidString: text) else { return }
        if #available(iOS 18.0, *), let binding = accessoryBinding as? HardwareAccessoryBinding {
            guard binding.ready, binding.session.accessories.contains(where: { $0.bluetoothIdentifier == id }) else { return }
        }
        ensureCentral()
        guard central.state == .poweredOn else { return }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
            DeviceDiagnostics.shared.log("BLE 已保存授权但暂无法取回外设，等待系统恢复")
            return
        }
        DeviceDiagnostics.shared.log("BLE 恢复已授权按钮 \(id)")
        if peripheral.state == .connected {
            selected = peripheral
            peripheral.delegate = self
            peripheral.discoverServices([buttonService])
        } else { connect(peripheral) }
        onChange?()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        DeviceDiagnostics.shared.log("BLE state=\(central.state.rawValue)")
        if central.state == .poweredOn { restoreDedicatedButton() }
        if central.state == .poweredOn, scanningRequested { scan() }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        let saved = UserDefaults.standard.string(forKey: "relay_dedicated_button_id")
        selected = restored.first(where: { $0.identifier.uuidString == saved })
        for peripheral in restored where peripheral.identifier.uuidString == saved {
            peripheral.delegate = self
            if UserDefaults.standard.bool(forKey: "relay_button_connection_paused") { central.cancelPeripheralConnection(peripheral); selected = nil }
            else if peripheral.state == .connected { peripheral.discoverServices([buttonService]) }
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
        scheduleReconnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral.identifier == selected?.identifier {
            notificationsReady = false
            BLEButtonTrial.shared.event("DISCONNECT error=\(String(describing: error))")
            BLEButtonTrial.shared.finish(reason: "设备断开，采样未完成")
        }
        DeviceDiagnostics.shared.log("BLE 断开 \(peripheral.identifier) error=\(String(describing: error))")
        if peripheral.identifier == selected?.identifier,
           UserDefaults.standard.string(forKey: "relay_dedicated_button_id") == peripheral.identifier.uuidString {
            DeviceDiagnostics.shared.log("BLE 专用按钮等待重连")
            scheduleReconnect(peripheral)
        }
    }

    private func scheduleReconnect(_ peripheral: CBPeripheral) {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.selected?.identifier == peripheral.identifier else { return }
            self.restoreDedicatedButton()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { DeviceDiagnostics.shared.log("BLE 服务错误 \(error)"); return }
        for service in peripheral.services ?? [] {
            if service.uuid == buttonService {
                UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "relay_dedicated_button_id")
                names[peripheral.identifier] = "Agent Relay 电脑按钮"
                onChange?()
            }
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
        end.setTitle("结束会话", for: .normal)
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
        help.font = .systemFont(ofSize: 13)
        help.numberOfLines = 0
        table.dataSource = self
        table.delegate = self
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let stack = UIStackView(arrangedSubviews: [controls, help, trialLabel, recordButton, table, logView])
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
