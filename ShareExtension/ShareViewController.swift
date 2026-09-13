import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let targetURLString = "https://complicated.taildbe095.ts.net:8443/api/cards/capture"

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

        let payload: [String: Any] = [
            "text": text,
            "sourceTitle": title,
            "context": "来自 iOS 系统级分享"
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let task = URLSession.shared.dataTask(with: request) { [weak self] (data, response, error) in
            DispatchQueue.main.async {
                if error == nil {
                    self?.dismissWithFeedback(success: true, message: "已存入 Agent 知识库 ✨")
                } else {
                    self?.dismissWithFeedback(success: false, message: "发送失败，请检查网络")
                }
            }
        }
        task.resume()
    }

    private func dismissWithFeedback(success: Bool, message: String) {
        let alert = UIAlertController(title: success ? "成功" : "提示", message: message, preferredStyle: .alert)
        present(alert, animated: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                alert.dismiss(animated: true) {
                    self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                }
            }
        }
    }
}
