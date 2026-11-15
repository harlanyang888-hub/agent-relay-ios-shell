import UIKit
import CoreBluetooth
import AccessorySetupKit

enum BLERecoveryLab {
    static var enabled: Bool { Bundle.main.object(forInfoDictionaryKey: "RelayBLERecoveryLab") as? Bool == true }
    static var usesASK: Bool { enabled && Bundle.main.object(forInfoDictionaryKey: "RelayUseAccessorySetupKit") as? Bool == true }
    static let service = "A8D70200-6B44-4E93-A2D5-73F2A34B8180"
    static let event = "A8D70201-6B44-4E93-A2D5-73F2A34B8180"
    static let ack = "A8D70202-6B44-4E93-A2D5-73F2A34B8180"
    static let identity = "A8D70203-6B44-4E93-A2D5-73F2A34B8180"
    static var bindingKey: String { enabled ? "relay_lab_button_id_v2" : "relay_dedicated_button_id" }
    static var immediateSystemStart: Bool {
        get { enabled && (UserDefaults.standard.object(forKey: "relay_lab_immediate_system_start") as? Bool ?? true) }
        set { UserDefaults.standard.set(newValue, forKey: "relay_lab_immediate_system_start") }
    }
}

@available(iOS 18.0, *)
final class RecoveryAccessoryBinding {
    let session = ASAccessorySession()
    var onAuthorized: ((UUID) -> Void)?
    var onBeforePicker: (() -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var ready = false
    private var presenting = false
    private var migrating = false

    func restore() {
        guard ready, !migrating else { return }
        let saved = UserDefaults.standard.string(forKey: BLERecoveryLab.bindingKey)
        let device = session.accessories.first(where: { $0.bluetoothIdentifier?.uuidString == saved }) ?? session.accessories.first
        if let id = device?.bluetoothIdentifier { onAuthorized?(id) }
    }

    func start() {
        session.activate(on: .main) { [weak self] event in
            guard let self = self else { return }
            DeviceDiagnostics.shared.log("LAB ASK event=\(event.eventType.rawValue) error=\(String(describing: event.error))")
            switch event.eventType {
            case .activated:
                self.ready = true
                self.restore()
            case .accessoryAdded, .accessoryChanged:
                if !self.migrating, let id = event.accessory?.bluetoothIdentifier { self.onAuthorized?(id) }
            case .migrationComplete:
                self.migrating = false
                self.restore()
            case .pickerDidDismiss:
                self.presenting = false
                self.onDismiss?()
            case .invalidated:
                self.ready = false
            default: break
            }
        }
    }

    func add() {
        guard ready, !presenting, UIApplication.shared.applicationState == .active else {
            DeviceDiagnostics.shared.log("LAB ASK 需要前台且系统授权会话已就绪")
            return
        }
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = CBUUID(string: BLERecoveryLab.service)
        let symbol = UIImage(systemName: "dot.radiowaves.left.and.right")!.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { _ in symbol.draw(in: CGRect(x: 16, y: 16, width: 128, height: 128)) }
        var items = [ASPickerDisplayItem(name: "Agent Relay 恢复测试按钮", productImage: image, descriptor: descriptor)]
        if session.accessories.isEmpty,
           let saved = UserDefaults.standard.string(forKey: BLERecoveryLab.bindingKey), let id = UUID(uuidString: saved) {
            let item = ASMigrationDisplayItem(name: "已连接的恢复测试按钮", productImage: image, descriptor: descriptor)
            item.peripheralIdentifier = id
            items = [item]
            migrating = true
        }
        presenting = true
        onBeforePicker?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.session.showPicker(for: items) { error in
                if let error = error {
                    self.presenting = false
                    self.migrating = false
                    let ns = error as NSError
                    DeviceDiagnostics.shared.log("LAB ASK picker failed domain=\(ns.domain) code=\(ns.code)")
                    self.onDismiss?()
                }
            }
        }
    }
}
