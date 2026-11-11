import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var tabBarController: UITabBarController?
    private var wearableViewController: WearablePoCViewController?
    private var webViewController: WebViewController?
    private var lastHandledURLString: String?
    private var lastHandledTime: TimeInterval = 0

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)

        let wearableVC = WearablePoCViewController()
        self.wearableViewController = wearableVC
        wearableVC.tabBarItem = UITabBarItem(
            title: "穿戴验证",
            image: UIImage(systemName: "headphones"),
            selectedImage: UIImage(systemName: "headphones.circle.fill")
        )

        let webVC = WebViewController()
        self.webViewController = webVC
        webVC.tabBarItem = UITabBarItem(
            title: "Agent Relay",
            image: UIImage(systemName: "network"),
            selectedImage: UIImage(systemName: "network.badge.shield.half.filled")
        )

        let tabController = UITabBarController()
        tabController.viewControllers = [wearableVC, webVC]
        tabController.tabBar.barStyle = .black
        tabController.tabBar.isTranslucent = true
        tabController.tabBar.tintColor = UIColor(red: 16/255.0, green: 185/255.0, blue: 129/255.0, alpha: 1.0) // #10b981
        tabController.tabBar.unselectedItemTintColor = UIColor(white: 0.6, alpha: 1.0)
        tabController.tabBar.backgroundColor = UIColor(red: 15/255.0, green: 17/255.0, blue: 23/255.0, alpha: 0.95)

        self.tabBarController = tabController
        window?.rootViewController = tabController
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

        // 切换到 Web 视图处理深度链接
        tabBarController?.selectedIndex = 1
        webViewController?.handleIncomingURL(url)
    }
}
