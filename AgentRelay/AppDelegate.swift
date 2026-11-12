import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var webViewController: WebViewController?
    private var lastHandledURLString: String?
    private var lastHandledTime: TimeInterval = 0

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)

        // 启动即刻拉起穿戴监听（.playback A2DP 模式）
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
