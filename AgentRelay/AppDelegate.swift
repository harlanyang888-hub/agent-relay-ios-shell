import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var webViewController: WebViewController?
    private var lastHandledURLString: String?
    private var lastHandledTime: TimeInterval = 0
    private var pendingRecordingAction: String?
    private var pendingRecordingContext: [String: String] = [:]

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 即使本地缓存丢失，也从系统外设授权列表恢复；不建立音频会话。
        _ = BLEProbe.shared
        DeviceDiagnostics.shared.log("App 启动 state=\(application.applicationState.rawValue)")
        DeviceDiagnostics.shared.log("App launch keys=\(launchOptions?.keys.map { $0.rawValue } ?? [])")
        if let launchURL = launchOptions?[.url] as? URL {
            handleIncomingURLSafely(launchURL)
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Agent Relay", sessionRole: connectingSceneSession.role)
        config.delegateClass = RelaySceneDelegate.self
        return config
    }

    func attachWindow(to scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        let webVC = WebViewController()
        webViewController = webVC
        window.rootViewController = webVC
        self.window = window
        window.makeKeyAndVisible()
        DeviceDiagnostics.shared.log("App window attached scene=\(scene.activationState.rawValue)")
        return window
    }

    func handleSceneURL(_ url: URL) { handleIncomingURLSafely(url) }

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
        webViewController?.handleIncomingURL(url)
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

final class RelaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var app: AppDelegate? { UIApplication.shared.delegate as? AppDelegate }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene, let app = app else { return }
        window = app.attachWindow(to: windowScene)
        for context in connectionOptions.urlContexts { app.handleSceneURL(context.url) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) { app?.applicationDidBecomeActive(UIApplication.shared) }
    func sceneDidEnterBackground(_ scene: UIScene) { app?.applicationDidEnterBackground(UIApplication.shared) }
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { app?.handleSceneURL(context.url) }
    }
}
