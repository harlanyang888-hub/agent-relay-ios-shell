import UIKit
import Social
import UniformTypeIdentifiers

struct SharedAttachmentItem {
    let filename: String
    let mimeType: String
    let dataUrl: String
    let size: Int
}

struct ParsedShareData {
    var text: String = ""
    var title: String = ""
    var urls: [String] = []
    var attachments: [SharedAttachmentItem] = []
}

class ShareViewController: UIViewController {

    private let targetURLString = "https://complicated.taildbe095.ts.net:8443/api/cards/capture"
    private let authToken = "36a019b34a706c581073c07157aeef9b64738026b920972e4d34d0a27919d548"

    private var progressAlert: UIAlertController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.3)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
        view.addGestureRecognizer(tapGesture)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedContent()
    }

    @objc private func handleBackgroundTap() {
        dismissExtension()
    }

    // MARK: - 多附件异步提取
    private func handleSharedContent() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem], !extensionItems.isEmpty else {
            dismissExtension()
            return
        }

        var shareData = ParsedShareData()
        let group = DispatchGroup()

        var imageProviders: [NSItemProvider] = []
        var urlProviders: [NSItemProvider] = []
        var textProviders: [NSItemProvider] = []

        for item in extensionItems {
            if let attributed = item.attributedContentText?.string, !attributed.isEmpty {
                if shareData.title.isEmpty {
                    shareData.title = attributed
                } else if shareData.text.isEmpty {
                    shareData.text = attributed
                }
            }
            if let attachments = item.attachments {
                for provider in attachments {
                    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        imageProviders.append(provider)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        urlProviders.append(provider)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        textProviders.append(provider)
                    }
                }
            }
        }

        // 解析多张图片
        for (index, provider) in imageProviders.enumerated() {
            group.enter()
            let defaultName = "image_\(index + 1).jpg"
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { (item, _) in
                defer { group.leave() }
                if let imageURL = item as? URL, let data = try? Data(contentsOf: imageURL), let image = UIImage(data: data) {
                    if let fileItem = self.compressAndEncodeImage(image, filename: imageURL.lastPathComponent) {
                        DispatchQueue.main.async {
                            shareData.attachments.append(fileItem)
                        }
                    }
                } else if let image = item as? UIImage {
                    if let fileItem = self.compressAndEncodeImage(image, filename: defaultName) {
                        DispatchQueue.main.async {
                            shareData.attachments.append(fileItem)
                        }
                    }
                } else if let data = item as? Data, let image = UIImage(data: data) {
                    if let fileItem = self.compressAndEncodeImage(image, filename: defaultName) {
                        DispatchQueue.main.async {
                            shareData.attachments.append(fileItem)
                        }
                    }
                }
            }
        }

        // 解析网页链接
        for provider in urlProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { (item, _) in
                defer { group.leave() }
                if let url = item as? URL {
                    DispatchQueue.main.async {
                        shareData.urls.append(url.absoluteString)
                    }
                }
            }
        }

        // 解析纯文本
        for provider in textProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { (item, _) in
                defer { group.leave() }
                if let text = item as? String {
                    DispatchQueue.main.async {
                        if shareData.text.isEmpty {
                            shareData.text = text
                        } else {
                            shareData.text += "\n" + text
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            if shareData.attachments.isEmpty && shareData.urls.isEmpty && shareData.text.isEmpty && shareData.title.isEmpty {
                self.dismissExtension()
            } else {
                self.showMainMenu(with: shareData)
            }
        }
    }

    private func compressAndEncodeImage(_ image: UIImage, filename: String) -> SharedAttachmentItem? {
        let maxDimension: CGFloat = 1600.0
        var targetImage = image
        if image.size.width > maxDimension || image.size.height > maxDimension {
            let scale = min(maxDimension / image.size.width, maxDimension / image.size.height)
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            if let resized = UIGraphicsGetImageFromCurrentImageContext() {
                targetImage = resized
            }
            UIGraphicsEndImageContext()
        }

        guard let jpegData = targetImage.jpegData(compressionQuality: 0.8) else { return nil }
        let base64 = jpegData.base64EncodedString()
        let dataUrl = "data:image/jpeg;base64,\(base64)"
        let safeName = filename.hasSuffix(".jpg") || filename.hasSuffix(".png") ? filename : "\(filename).jpg"

        return SharedAttachmentItem(filename: safeName, mimeType: "image/jpeg", dataUrl: dataUrl, size: jpegData.count)
    }

    // MARK: - 主操作选择面板
    private func showMainMenu(with shareData: ParsedShareData) {
        let message: String
        let hasImages = !shareData.attachments.isEmpty
        if hasImages {
            let count = shareData.attachments.count
            message = "已选择 \(count) 张图片" + (shareData.text.isEmpty ? "" : " · \(shareData.text.prefix(30))...")
        } else if let firstUrl = shareData.urls.first {
            message = "网页: \(firstUrl)"
        } else {
            let text = shareData.text.isEmpty ? shareData.title : shareData.text
            let snippet = text.count > 60 ? String(text.prefix(60)) + "..." : text
            message = "已提取: \(snippet)"
        }

        let alert = UIAlertController(
            title: "Agent Relay 智能中继",
            message: message,
            preferredStyle: .actionSheet
        )

        // 1. 发送到当前对话 (快速载入当前 Composer)
        alert.addAction(UIAlertAction(title: "💬 发送到当前会话", style: .default, handler: { [weak self] _ in
            self?.passToMainAppAndOpen(shareData: shareData, mode: "chat")
        }))

        // 2. 新建会话 / 选择 Agent (进 App 弹出 Agent 选择器并挂载附件)
        alert.addAction(UIAlertAction(title: "➕ 新建会话 (选择 Agent)", style: .default, handler: { [weak self] _ in
            self?.passToMainAppAndOpen(shareData: shareData, mode: "picker")
        }))

        // 3. 存入 Smart Cards (知识卡片)
        alert.addAction(UIAlertAction(title: "💡 存入 Smart Cards (知识卡片)", style: .default, handler: { [weak self] _ in
            self?.saveToSmartCards(with: shareData)
        }))

        // 4. 复制为 Markdown 摘录
        alert.addAction(UIAlertAction(title: "📋 复制为 Markdown 摘录", style: .default, handler: { [weak self] _ in
            self?.copyAsMarkdown(with: shareData)
        }))

        // 取消
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: { [weak self] _ in
            self?.dismissExtension()
        }))

        configurePopover(for: alert)
        present(alert, animated: true, completion: nil)
    }

    // MARK: - 极速跨进程传递给主应用
    private func passToMainAppAndOpen(shareData: ParsedShareData, mode: String) {
        var filesPayload: [[String: Any]] = []
        for item in shareData.attachments {
            filesPayload.append([
                "name": item.filename,
                "type": item.mimeType,
                "dataUrl": item.dataUrl
            ])
        }

        var textContent = shareData.text
        if textContent.isEmpty && !shareData.urls.isEmpty {
            textContent = shareData.urls.joined(separator: "\n")
        }

        let payload: [String: Any] = [
            "text": textContent,
            "title": shareData.title,
            "files": filesPayload,
            "mode": mode
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
            UIPasteboard.general.setData(jsonData, forPasteboardType: "com.complicated.agentrelay.share")
        }

        guard let url = URL(string: "agentrelay://share?mode=\(mode)") else {
            dismissExtension()
            return
        }

        self.extensionContext?.open(url, completionHandler: { [weak self] success in
            if !success {
                var responder: UIResponder? = self
                let selector = NSSelectorFromString("openURL:")
                while responder != nil {
                    if responder!.responds(to: selector) {
                        responder!.perform(selector, with: url)
                        break
                    }
                    responder = responder?.next
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.dismissExtension()
            }
        })
    }

    // MARK: - 存入 Smart Cards
    private func saveToSmartCards(with shareData: ParsedShareData) {
        showProgressAlert(message: "正在存入知识库...")

        var text = shareData.text
        if text.isEmpty && !shareData.urls.isEmpty {
            text = shareData.urls.joined(separator: "\n")
        }
        if text.isEmpty && !shareData.attachments.isEmpty {
            text = "[图片分享] 共 \(shareData.attachments.count) 张图片\n" + shareData.attachments.map { $0.filename }.joined(separator: ", ")
        }
        if text.isEmpty {
            text = shareData.title.isEmpty ? "来自 iOS 快速归档" : shareData.title
        }

        guard let url = URL(string: targetURLString) else {
            dismissWithFeedback(success: false, message: "URL 错误")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 6.0

        let payload: [String: Any] = [
            "text": text,
            "sourceTitle": shareData.title.isEmpty ? "iOS 快速归档" : shareData.title,
            "context": "来自 iOS 系统级分享"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let task = URLSession.shared.dataTask(with: request) { [weak self] (_, response, error) in
            DispatchQueue.main.async {
                let http = response as? HTTPURLResponse
                let statusCode = http?.statusCode ?? 0
                if error == nil && (statusCode == 200 || statusCode == 201) {
                    self?.dismissWithFeedback(success: true, message: "已成功存入 Smart Cards ✨")
                } else {
                    self?.dismissWithFeedback(success: false, message: "存入失败 (HTTP \(statusCode))")
                }
            }
        }
        task.resume()
    }

    // MARK: - 复制 Markdown
    private func copyAsMarkdown(with shareData: ParsedShareData) {
        var parts: [String] = []
        if !shareData.urls.isEmpty {
            let links = shareData.urls.map { "[\(shareData.title.isEmpty ? $0 : shareData.title)](\($0))" }
            parts.append(contentsOf: links)
        }
        if !shareData.text.isEmpty {
            let quote = shareData.text.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
            parts.append(quote)
        }
        if !shareData.attachments.isEmpty {
            parts.append("> [附件图片 \(shareData.attachments.count) 张]")
        }

        let markdown = parts.joined(separator: "\n\n")
        UIPasteboard.general.string = markdown
        dismissWithFeedback(success: true, message: "已复制 Markdown 摘录 📋")
    }

    // MARK: - 辅助反馈与退出
    private func showProgressAlert(message: String) {
        let alert = UIAlertController(title: "正在处理中", message: message, preferredStyle: .alert)
        self.progressAlert = alert
        present(alert, animated: true, completion: nil)
    }

    private func dismissWithFeedback(success: Bool, message: String) {
        if let progress = progressAlert {
            progress.dismiss(animated: true) { [weak self] in
                self?.presentResultAlert(success: success, message: message)
            }
            self.progressAlert = nil
        } else {
            presentResultAlert(success: success, message: message)
        }
    }

    private func presentResultAlert(success: Bool, message: String) {
        let alert = UIAlertController(title: success ? "成功" : "提示", message: message, preferredStyle: .alert)
        present(alert, animated: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
                alert.dismiss(animated: true) {
                    self?.dismissExtension()
                }
            }
        }
    }

    private func dismissExtension() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func configurePopover(for alert: UIAlertController) {
        if let popover = alert.popoverPresentationController {
            popover.sourceView = self.view
            popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
    }
}
