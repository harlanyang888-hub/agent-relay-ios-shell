import UIKit
import WebKit

class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WearableServiceDelegate {
    private var webView: WKWebView!
    private var activityIndicator: UIActivityIndicatorView!
    private var pendingTargetURL: URL?
    private var pendingShareJSON: String?

    private let targetURLString = "https://complicated.taildbe095.ts.net:8443"

    override func viewDidLoad() {
        super.viewDidLoad()
        // 状态栏与顶层背景色与应用完全一致 (#0a0b0d)
        view.backgroundColor = UIColor(red: 10/255.0, green: 11/255.0, blue: 13/255.0, alpha: 1.0)
        
        WearableService.shared.delegate = self
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

        // 注册双向 Bridge
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "wearableBridge")

        // 注入 Native Bridge 标记与帮助类
        let bridgeScriptSource = """
        (function() {
            window.__IS_WEARABLE_NATIVE_SHELL__ = true;
            window.wearableNativeBridge = {
                startListening: function() {
                    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wearableBridge && window.webkit.messageHandlers.wearableBridge.postMessage({ action: 'startListening' });
                },
                stopListening: function() {
                    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wearableBridge && window.webkit.messageHandlers.wearableBridge.postMessage({ action: 'stopListening' });
                },
                startRecording: function() {
                    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wearableBridge && window.webkit.messageHandlers.wearableBridge.postMessage({ action: 'startRecording' });
                },
                stopRecording: function() {
                    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wearableBridge && window.webkit.messageHandlers.wearableBridge.postMessage({ action: 'stopRecording' });
                },
                playAudio: function(url, base64) {
                    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wearableBridge && window.webkit.messageHandlers.wearableBridge.postMessage({ action: 'playAudio', url: url, base64: base64 });
                },
                stopAudio: function() {
                    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wearableBridge && window.webkit.messageHandlers.wearableBridge.postMessage({ action: 'stopAudio' });
                },
                getDeviceStatus: function() {
                    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wearableBridge && window.webkit.messageHandlers.wearableBridge.postMessage({ action: 'getDeviceStatus' });
                },
                vibrate: function() {
                    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wearableBridge && window.webkit.messageHandlers.wearableBridge.postMessage({ action: 'vibrate' });
                },
                beep: function(type) {
                    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wearableBridge && window.webkit.messageHandlers.wearableBridge.postMessage({ action: 'beep', type: type });
                },
                syncContext: function(data) {
                    window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wearableBridge && window.webkit.messageHandlers.wearableBridge.postMessage(Object.assign({ action: 'syncContext' }, data || {}));
                }
            };
        })();
        """
        let userScript = WKUserScript(source: bridgeScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        userContentController.addUserScript(userScript)
        configuration.userContentController = userContentController

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

        // 页面加载完成后同步 Cookie 与设备状态
        syncCookiesToWearable()
        WearableService.shared.notifyStatusChanged()
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

    // MARK: - WKScriptMessageHandler (Web -> Native)
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "wearableBridge", let body = message.body as? [String: Any], let action = body["action"] as? String else {
            return
        }

        switch action {
        case "startListening":
            WearableService.shared.startListening()
        case "stopListening":
            WearableService.shared.stopListening()
        case "startRecording":
            WearableService.shared.startRecording()
        case "stopRecording":
            WearableService.shared.stopRecording(shouldProcess: true)
        case "playAudio":
            let url = body["url"] as? String
            let base64 = body["base64"] as? String
            WearableService.shared.playAudioStream(urlString: url, base64Data: base64)
        case "stopAudio":
            WearableService.shared.stopAudioPlayback()
        case "getDeviceStatus":
            WearableService.shared.notifyStatusChanged()
        case "vibrate":
            WearableService.shared.triggerFeedbackHaptic()
        case "beep":
            let type = body["type"] as? String ?? "start"
            if type == "end" {
                WearableService.shared.playBeepEnd()
            } else {
                WearableService.shared.playBeepStart()
            }
        case "syncContext":
            if let convId = body["conversationId"] as? String, !convId.isEmpty {
                WearableService.shared.currentConversationId = convId
                print("[WebViewController] 同步当前会话 ID: \(convId)")
            }
            if let cookie = body["cookie"] as? String, !cookie.isEmpty {
                WearableService.shared.authCookie = cookie
            }
            syncCookiesToWearable()
        default:
            print("[WebViewController] 未知 Bridge 指令: \(action)")
        }
    }

    private func syncCookiesToWearable() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let cookieHeaders = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            if !cookieHeaders.isEmpty {
                WearableService.shared.authCookie = cookieHeaders
                print("[WebViewController] 成功同步 WKWebView Cookies (\(cookies.count) 条)")
            }
        }
    }

    // MARK: - WearableServiceDelegate (Native -> Web)
    func wearableServiceDidChangeDeviceStatus(connected: Bool, deviceName: String, isListening: Bool, isRecording: Bool) {
        let payload: [String: Any] = [
            "connected": connected,
            "deviceName": deviceName,
            "isListening": isListening,
            "isRecording": isRecording
        ]
        dispatchJSEvent(eventName: "wearable:deviceStatus", payload: payload)
    }

    func wearableServiceDidCaptureButton(name: String, appState: String) {
        let payload: [String: Any] = [
            "event": name,
            "appState": appState,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        dispatchJSEvent(eventName: "wearable:hardwareButton", payload: payload)
    }

    func wearableServiceDidFinishRecording(base64: String, mimeType: String, transcript: String, duration: TimeInterval) {
        let payload: [String: Any] = [
            "base64": base64,
            "mimeType": mimeType,
            "transcript": transcript,
            "duration": duration
        ]
        dispatchJSEvent(eventName: "wearable:audioRecorded", payload: payload)
    }

    func wearableServiceDidFinishPlayback() {
        let payload: [String: Any] = [
            "status": "ended"
        ]
        dispatchJSEvent(eventName: "wearable:playbackEnded", payload: payload)
    }

    private func dispatchJSEvent(eventName: String, payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        let script = """
        (function() {
            try {
                const detail = \(jsonString);
                window.dispatchEvent(new CustomEvent('\(eventName)', { detail: detail }));
            } catch(e) {
                console.error("Bridge dispatch error for \(eventName):", e);
            }
        })();
        """

        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // MARK: - 深度链接与分享集成
    func handleIncomingURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        let host = components.host?.lowercased() ?? ""
        let path = components.path.lowercased()

        if host == "share" || path == "/share" || host == "chat" || path == "/chat" {
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
