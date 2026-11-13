import UIKit
import CoreBluetooth

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
    private var selected: CBPeripheral?
    private var scanningRequested = false
    private var scanTimeout: Timer?
    var onChange: (() -> Void)?

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "agent-relay-ble-probe-v1"
        ])
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
        central.scanForPeripherals(withServices: nil, options: nil)
        DeviceDiagnostics.shared.log("BLE 前台扫描开始（30 秒），请按防丢器按钮")
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
        if let previous = selected, previous.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(previous)
        }
        selected = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        DeviceDiagnostics.shared.log("BLE 连接 \(peripheral.name ?? "未命名") \(peripheral.identifier)")
    }

    func disconnect() {
        if let peripheral = selected { central.cancelPeripheralConnection(peripheral) }
        selected = nil
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
        guard !devices.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        devices.append(peripheral)
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "未命名"
        DeviceDiagnostics.shared.log("BLE 发现 \(name) RSSI=\(RSSI) id=\(peripheral.identifier)")
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DeviceDiagnostics.shared.log("BLE 已连接 \(peripheral.name ?? "未命名")")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DeviceDiagnostics.shared.log("BLE 连接失败 \(String(describing: error))")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DeviceDiagnostics.shared.log("BLE 断开 \(peripheral.identifier) error=\(String(describing: error))")
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
        DeviceDiagnostics.shared.log("BLE 订阅 \(characteristic.uuid) enabled=\(characteristic.isNotifying) error=\(String(describing: error))")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let hex = (characteristic.value ?? Data()).prefix(64).map { String(format: "%02x", $0) }.joined()
        DeviceDiagnostics.shared.log("BLE VALUE \(characteristic.service?.uuid.uuidString ?? "?")/\(characteristic.uuid) hex=\(hex) error=\(String(describing: error))")
    }
}

final class DeviceDiagnosticsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView()
    private let logView = UITextView()
    private let recordButton = UIButton(type: .system)
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
        let controls = UIStackView(arrangedSubviews: [scan, disconnect, copy])
        controls.distribution = .fillEqually
        let help = UILabel()
        help.text = "BLE 仅观测：扫描后点选防丢器，按单击/双击/长按，再复制日志。录音测试会发送给 Agent。"
        help.font = .systemFont(ofSize: 13)
        help.numberOfLines = 0
        table.dataSource = self
        table.delegate = self
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let stack = UIStackView(arrangedSubviews: [controls, recordButton, help, table, logView])
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
            table.heightAnchor.constraint(equalTo: stack.heightAnchor, multiplier: 0.25)
        ])
        BLEProbe.shared.onChange = { [weak self] in self?.table.reloadData() }
        DeviceDiagnostics.shared.onChange = { [weak self] in self?.refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let text = DeviceDiagnostics.shared.text
        if logView.text != text {
            logView.text = text
            if !text.isEmpty { logView.scrollRangeToVisible(NSRange(location: (text as NSString).length - 1, length: 1)) }
        }
        recordButton.setTitle(WearableService.shared.isRecording ? "结束录音并发送" : "开始录音测试", for: .normal)
    }

    @objc private func scanBLE() { BLEProbe.shared.scan() }
    @objc private func disconnectBLE() { BLEProbe.shared.disconnect() }
    @objc private func copyLog() { UIPasteboard.general.string = DeviceDiagnostics.shared.text }
    @objc private func toggleRecording() {
        if WearableService.shared.isRecording { WearableService.shared.stopRecording() }
        else { WearableService.shared.startRecording() }
        refresh()
    }
    @objc private func close() {
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
        cell.textLabel?.text = peripheral.name ?? "未命名 BLE 设备"
        cell.detailTextLabel?.text = peripheral.identifier.uuidString
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        BLEProbe.shared.connect(BLEProbe.shared.devices[indexPath.row])
    }
}
