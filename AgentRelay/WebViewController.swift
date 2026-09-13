import UIKit
import WebKit

class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var activityIndicator: UIActivityIndicatorView!
    private var pendingTargetURL: URL?
    private var pendingShareJSON: String?

    private let targetURLString = "https://complicated.taildbe095.ts.net:8443"

    override func viewDidLoad() {
        super.viewDidLoad()
        // 状态栏与顶层背景色与应用完全一致 (#0a0b0d)
        view.backgroundColor = UIColor(red: 10/255.0, green: 11/255.0, blue: 13/255.0, alpha: 1.0)
        setupWebView()
        setupIndicator()
        loadInitialURL()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = true

        // 开启边缘侧滑返回手势
        webView.allowsBackForwardNavigationGestures = true
        
        view.addSubview(webView)

        // 核心布局：
        // 1. 顶部严格对齐 safeAreaLayoutGuide.topAnchor，物理级避开时间、电量、灵动岛，绝对零重叠！
        // 2. 底部直通 view.bottomAnchor，100% 满屏无黑边！
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func setupIndicator() {
        activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.color = .systemBlue
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func loadInitialURL() {
        let destination = pendingTargetURL ?? URL(string: targetURLString)
        pendingTargetURL = nil
        guard let url = destination else { return }
        activityIndicator.startAnimating()
        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        webView.load(request)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        activityIndicator.stopAnimating()
        if let pending = pendingTargetURL {
            pendingTargetURL = nil
            webView.load(URLRequest(url: pending))
            return
        }
        if let shareJSON = pendingShareJSON {
            pendingShareJSON = nil
            dispatchNativeShare(jsonString: shareJSON)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        activityIndicator.stopAnimating()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" && scheme != "about" {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func handleIncomingURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        let host = components.host?.lowercased() ?? ""
        let path = components.path.lowercased()

        if host == "share" || path == "/share" || host == "chat" || path == "/chat" {
            // 优先检查剪贴板中的原生分享包 (秒级无损跨进程传递)
            if let pasteboardData = UIPasteboard.general.data(forPasteboardType: "com.complicated.agentrelay.share"),
               let jsonString = String(data: pasteboardData, encoding: .utf8), !jsonString.isEmpty {
                UIPasteboard.general.setData(Data(), forPasteboardType: "com.complicated.agentrelay.share")
                dispatchNativeShare(jsonString: jsonString)
                return
            }

            if let conversationId = components.queryItems?.first(where: { $0.name == "conversationId" || $0.name == "conversation" || $0.name == "id" })?.value, !conversationId.isEmpty {
                let targetPath = "/?conversation=\(conversationId)"
                let js = "window.location.href = '\(targetPath)';"
                webView.evaluateJavaScript(js) { [weak self] (_, error) in
                    if error != nil {
                        if let destURL = URL(string: "\(self?.targetURLString ?? "")\(targetPath)") {
                            self?.webView.load(URLRequest(url: destURL))
                        }
                    }
                }
            } else if let text = components.queryItems?.first(where: { $0.name == "text" || $0.name == "prompt" || $0.name == "q" })?.value, !text.isEmpty {
                let payload: [String: Any] = ["text": text]
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let jsonString = String(data: data, encoding: .utf8) {
                    dispatchNativeShare(jsonString: jsonString)
                }
            }
        }
    }

    private var lastDispatchedShareJSON: String?
    private var lastDispatchedShareTime: TimeInterval = 0

    private func dispatchNativeShare(jsonString: String) {
        let now = Date().timeIntervalSince1970
        if lastDispatchedShareJSON == jsonString && (now - lastDispatchedShareTime) < 2.0 {
            return
        }
        lastDispatchedShareJSON = jsonString
        lastDispatchedShareTime = now

        let script = """
        (function() {
            try {
                const detail = \(jsonString);
                window.__AGENT_RELAY_PENDING_SHARE__ = detail;
                window.dispatchEvent(new CustomEvent('agent-relay:native-share', { detail: detail }));
            } catch(e) {
                console.error("Native share dispatch error:", e);
            }
        })();
        """

        if webView == nil || activityIndicator.isAnimating {
            pendingShareJSON = jsonString
        } else {
            webView.evaluateJavaScript(script) { [weak self] (_, error) in
                if error != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self?.webView.evaluateJavaScript(script, completionHandler: nil)
                    }
                }
            }
        }
    }
}
