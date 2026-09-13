import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let targetURLString = "https://complicated.taildbe095.ts.net:8443/api/cards/capture"
    // 携带 Gateway 鉴权 Token
    private let authToken = "36a019b34a706c581073c07157aeef9b64738026b920972e4d34d0a27919d548"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.4)
        handleSharedContent()
    }

    private func handleSharedContent() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments, !attachments.isEmpty else {
            self.dismissWithFeedback(success: false, message: "无可用内容")
            return
        }

        // 收集文字或 URL
        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] (item, error) in
                    if let url = item as? URL {
                        self?.sendCapture(text: url.absoluteString, title: extensionItem.attributedContentText?.string ?? "网页链接")
                    }
                }
                return
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] (item, error) in
                    if let text = item as? String {
                        self?.sendCapture(text: text, title: "iOS 划词摘录")
                    }
                }
                return
            }
        }

        // 如果只有标题或富文本
        if let text = extensionItem.attributedContentText?.string, !text.isEmpty {
            sendCapture(text: text, title: "iOS 划词摘录")
        } else {
            dismissWithFeedback(success: false, message: "无法解析分享内容")
        }
    }

    private func sendCapture(text: String, title: String) {
        guard let url = URL(string: targetURLString) else {
            dismissWithFeedback(success: false, message: "URL 错误")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 关键鉴权 Header: 让 Gateway 准确识别并放行转发至 Smart Cards
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "text": text,
            "sourceTitle": title,
            "context": "来自 iOS 系统级分享"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let task = URLSession.shared.dataTask(with: request) { [weak self] (data, response, error) in
            DispatchQueue.main.async {
                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? 0
                
                if error == nil && (statusCode == 200 || statusCode == 201) {
                    self?.dismissWithFeedback(success: true, message: "已存入 Smart Cards ✨")
                } else {
                    self?.dismissWithFeedback(success: false, message: "存入失败 (HTTP \(statusCode))，请检查网关")
                }
            }
        }
        task.resume()
    }

    private func dismissWithFeedback(success: Bool, message: String) {
        let alert = UIAlertController(title: success ? "成功" : "提示", message: message, preferredStyle: .alert)
        present(alert, animated: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                alert.dismiss(animated: true) {
                    self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
            }
        }
    }
}
