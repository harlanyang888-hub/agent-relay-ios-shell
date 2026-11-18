import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var webViewController: WebViewController?
    private var pendingInterfaceURL: URL?
    var nativeAudioIsolationActive: Bool { BLERecoveryLab.nativeAudioIsolation && webViewController == nil }
    private var lastHandledURLString: String?
    private var lastHandledTime: TimeInterval = 0
    private var pendingRecordingAction: String?
    private var pendingRecordingContext: [String: String] = [:]

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if BLERecoveryLab.enabled || launchOptions?[.bluetoothCentrals] != nil || UserDefaults.standard.string(forKey: "relay_dedicated_button_id") != nil {
            _ = BLEProbe.shared
        }
        DeviceDiagnostics.shared.log("App 启动 state=\(application.applicationState.rawValue)")
        DeviceDiagnostics.shared.log("App launch keys=\(launchOptions?.keys.map { $0.rawValue } ?? [])")
        DeviceDiagnostics.shared.log("App comparison=pre-ASK；不自动预建系统会话")
        if BLERecoveryLab.enabled {
            DeviceDiagnostics.shared.log("LAB BOOT pid=\(ProcessInfo.processInfo.processIdentifier) run=\(UUID().uuidString) ASK=\(BLERecoveryLab.usesASK) protectedData=\(application.isProtectedDataAvailable)")
        }
        window = UIWindow(frame: UIScreen.main.bounds)

        // 空闲不占用音频；专用 BLE 按键按需建立系统语音会话。

        if BLERecoveryLab.nativeAudioIsolation {
            DeviceDiagnostics.shared.log("AUDIO ISOLATION boot nativeOnly=true webViewCreated=false preparedTonePlayers=false")
            window?.rootViewController = UINavigationController(rootViewController: DeviceDiagnosticsViewController())
        } else {
            let webVC = WebViewController()
            self.webViewController = webVC
            window?.rootViewController = webVC
        }
        window?.makeKeyAndVisible()

        if let launchURL = launchOptions?[.url] as? URL {
            handleIncomingURLSafely(launchURL)
        }
        return true
    }

    @discardableResult
    func showWebInterface() -> Bool {
        guard !WearableService.shared.isRecording, !WearableService.shared.inputComparisonActive else { return false }
        if #available(iOS 17.4, *),
           !VoiceConversationProbe.shared.canChangeLaunchPath || !VoiceConversationProbe.shared.audioReleaseConfirmed { return false }
        if webViewController == nil {
            DeviceDiagnostics.shared.log("AUDIO ISOLATION user opened web interface; nativeOnly=false for remainder of process")
            let webVC = WebViewController()
            webViewController = webVC
            window?.rootViewController = webVC
            window?.makeKeyAndVisible()
            webVC.loadViewIfNeeded()
        }
        if let pending = pendingInterfaceURL {
            pendingInterfaceURL = nil
            webViewController?.handleIncomingURL(pending)
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        DeviceDiagnostics.shared.log("App entered background category=\(AVAudioSession.sharedInstance().category.rawValue) recording=\(WearableService.shared.isRecording)")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        DeviceDiagnostics.shared.log("App became active category=\(AVAudioSession.sharedInstance().category.rawValue)")
        performPendingRecordingAction()
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        handleIncomingURLSafely(url)
        return true
    }

    private func handleIncomingURLSafely(_ url: URL) {
        let now = Date().timeIntervalSince1970
        let urlStr = url.absoluteString
        // 防抖：1.5 秒内相同 URL 不重复触发
        if lastHandledURLString == urlStr && (now - lastHandledTime) < 1.5 {
            return
        }
        lastHandledURLString = urlStr
        lastHandledTime = now

        if url.scheme?.lowercased() == "agentrelay", url.host?.lowercased() == "record",
           ["/start", "/stop", "/cancel"].contains(url.path.lowercased()) {
            pendingRecordingAction = url.path.lowercased()
            let allowed = ["hostId", "project", "cwd", "prompt", "conversationId", "title"]
            pendingRecordingContext = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                if allowed.contains(item.name), let value = item.value, !value.isEmpty {
                    pendingRecordingContext[item.name] = value
                }
            }
            performPendingRecordingAction()
            return
        }
        if let webVC = webViewController { webVC.handleIncomingURL(url) }
        else {
            pendingInterfaceURL = url
            if !showWebInterface() { DeviceDiagnostics.shared.log("AUDIO ISOLATION deferred web link until audio is released") }
        }
    }

    private func performPendingRecordingAction() {
        // URL 打开时可能仍处于 inactive；等前台激活后再取得麦克风。
        guard UIApplication.shared.applicationState == .active,
              let action = pendingRecordingAction else { return }
        pendingRecordingAction = nil
        let context = pendingRecordingContext
        pendingRecordingContext = [:]
        if action == "/start" {
            WearableService.shared.startShortcutRecording(context: context)
        } else {
            WearableService.shared.stopRecording(shouldProcess: action == "/stop")
        }
    }
}
