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
    // Recording must work offline. Old diagnostic preferences must not gate it.
    static var immediateSystemStart: Bool { enabled }
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
        let device = session.accessories.first(where: { $0.bluetoothIdentifier?.uuidString == saved })
            ?? (saved == nil && session.accessories.count == 1 ? session.accessories.first : nil)
        if let id = device?.bluetoothIdentifier { onAuthorized?(id) }
        else { DeviceDiagnostics.shared.log("LAB ASK 未找到当前绑定；保留选择，不回退到历史设备") }
    }

    func start() {
        session.activate(on: .main) { [weak self] event in
            guard let self = self else { return }
            DeviceDiagnostics.shared.log("LAB ASK event=\(event.eventType.rawValue) error=\(String(describing: event.error))")
            switch event.eventType {
            case .activated:
                self.ready = true
                self.restore()
            case .accessoryAdded:
                if !self.migrating, let id = event.accessory?.bluetoothIdentifier { self.onAuthorized?(id) }
            case .accessoryChanged:
                // Changes also arrive for historical authorizations. They must
                // never replace the device the user most recently selected.
                if !self.migrating, let id = event.accessory?.bluetoothIdentifier {
                    let saved = UserDefaults.standard.string(forKey: BLERecoveryLab.bindingKey)
                    guard id.uuidString == saved else {
                        DeviceDiagnostics.shared.log("LAB ASK 忽略非当前按钮的变化 id=\(id)")
                        return
                    }
                    self.onAuthorized?(id)
                }
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
        descriptor.bluetoothNameSubstring = "AgentRelay-Watch"
        let symbol = UIImage(systemName: "dot.radiowaves.left.and.right")!.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { _ in symbol.draw(in: CGRect(x: 16, y: 16, width: 128, height: 128)) }
        let computer = ASDiscoveryDescriptor()
        computer.bluetoothServiceUUID = CBUUID(string: BLERecoveryLab.service)
        computer.bluetoothNameSubstring = "RN12108"
        let items = [ASPickerDisplayItem(name: "relay watch", productImage: image, descriptor: descriptor),
                     ASPickerDisplayItem(name: "电脑模拟按钮", productImage: image, descriptor: computer)]
        // Adding a new device must discover nearby hardware, never migrate the saved PC identifier.
        DeviceDiagnostics.shared.log("LAB ASK 查找新设备：relay watch / 电脑模拟按钮；已授权=\(session.accessories.count)")
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
