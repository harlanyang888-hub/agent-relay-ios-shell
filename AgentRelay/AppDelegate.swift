import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var webViewController: WebViewController?
    private var lastHandledURLString: String?
    private var lastHandledTime: TimeInterval = 0

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        let viewController = WebViewController()
        self.webViewController = viewController
        window?.rootViewController = viewController
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
        // Debounce identical URL within 1.5 seconds to prevent cold launch double triggers
        if lastHandledURLString == urlStr && (now - lastHandledTime) < 1.5 {
            return
        }
        lastHandledURLString = urlStr
        lastHandledTime = now
        webViewController?.handleIncomingURL(url)
    }
}
