import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var webViewController: WebViewController?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        let viewController = WebViewController()
        self.webViewController = viewController
        window?.rootViewController = viewController
        window?.makeKeyAndVisible()

        if let launchURL = launchOptions?[.url] as? URL {
            viewController.handleIncomingURL(launchURL)
        }
        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        webViewController?.handleIncomingURL(url)
        return true
    }
}
