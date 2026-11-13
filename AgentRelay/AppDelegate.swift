import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var webViewController: WebViewController?
    private var lastHandledURLString: String?
    private var lastHandledTime: TimeInterval = 0

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if launchOptions?[.bluetoothCentrals] != nil { _ = BLEProbe.shared }
        DeviceDiagnostics.shared.log("App 启动 state=\(application.applicationState.rawValue)")
        DeviceDiagnostics.shared.log("App launch keys=\(launchOptions?.keys.map { $0.rawValue } ?? [])")
        window = UIWindow(frame: UIScreen.main.bounds)

        // 前台启动时配置待机和录音共用的音频会话。
        WearableService.shared.startListening()

        let webVC = WebViewController()
        self.webViewController = webVC

        window?.rootViewController = webVC
        window?.makeKeyAndVisible()

        if let launchURL = launchOptions?[.url] as? URL {
            handleIncomingURLSafely(launchURL)
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        DeviceDiagnostics.shared.log("App entered background category=\(AVAudioSession.sharedInstance().category.rawValue) recording=\(WearableService.shared.isRecording)")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        DeviceDiagnostics.shared.log("App became active category=\(AVAudioSession.sharedInstance().category.rawValue)")
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

        webViewController?.handleIncomingURL(url)
    }
}
