import UIKit
import Social
import UniformTypeIdentifiers
import ImageIO

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
    private var loadingIndicator: UIActivityIndicatorView?
    private var isProcessing = false
    private var hasHandled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.35)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
        tapGesture.cancelsTouchesInView = false
        view.addGestureRecognizer(tapGesture)

        setupLoadingIndicator()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasHandled else { return }
        hasHandled = true
        handleSharedContent()
    }

    private func setupLoadingIndicator() {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.color = .white
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        self.loadingIndicator = indicator
    }

    @objc private func handleBackgroundTap() {
        // Prevent accidental dismissal while processing files or showing alerts
        if isProcessing || presentedViewController != nil || progressAlert != nil {
            return
        }
        dismissExtension()
    }

    // MARK: - 多附件异步提取与安全降采样
    private func handleSharedContent() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem], !extensionItems.isEmpty else {
            dismissExtension()
            return
        }

        isProcessing = true
        loadingIndicator?.startAnimating()

        var shareData = ParsedShareData()
        let group = DispatchGroup()

        var imageProviders: [NSItemProvider] = []
        var urlProviders: [NSItemProvider] = []
        var textProviders: [NSItemProvider] = []
        var fileProviders: [NSItemProvider] = []

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
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        urlProviders.append(provider)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        textProviders.append(provider)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) || provider.hasItemConformingToTypeIdentifier(UTType.content.identifier) {
                        fileProviders.append(provider)
                    }
                }
            }
        }

        // 1. 解析图片 (采用 ImageIO 极速低内存降采样，严防 iOS 扩展 60MB 内存溢出)
        for (index, provider) in imageProviders.enumerated() {
            group.enter()
            let defaultName = "image_\(index + 1).jpg"
            let typeId = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) ?? UTType.image.identifier
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { [weak self] (item, _) in
                guard let self = self else {
                    group.leave()
                    return
                }
                let fileItem = self.processImageItem(item, defaultName: defaultName)
                DispatchQueue.main.async {
                    if let fileItem = fileItem {
                        shareData.attachments.append(fileItem)
                    }
                    group.leave()
                }
            }
        }

        // 2. 解析通用文件 (PDF, 文档, 压缩包等，带 Security-Scoped 权限支持)
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            let defaultName = "file_\(index + 1).bin"
            let typeId = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
            provider.loadItem(forTypeIdentifier: typeId, options: nil) { [weak self] (item, _) in
                guard let self = self else {
                    group.leave()
                    return
                }
                let fileItem = self.processGenericFileItem(item, defaultName: defaultName)
                DispatchQueue.main.async {
                    if let fileItem = fileItem {
                        shareData.attachments.append(fileItem)
                    }
                    group.leave()
                }
            }
        }

        // 3. 解析网页链接
        for provider in urlProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { (item, _) in
                let url = item as? URL
                DispatchQueue.main.async {
                    if let url = url {
                        shareData.urls.append(url.absoluteString)
                    }
                    group.leave()
                }
            }
        }

        // 4. 解析纯文本
        for provider in textProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { (item, _) in
                let text = item as? String
                DispatchQueue.main.async {
                    if let text = text {
                        if shareData.text.isEmpty {
                            shareData.text = text
                        } else {
                            shareData.text += "\n" + text
                        }
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isProcessing = false
            self.loadingIndicator?.stopAnimating()

            if shareData.attachments.isEmpty && shareData.urls.isEmpty && shareData.text.isEmpty && shareData.title.isEmpty {
                // 如果没有成功读取到任何有效内容，弹出提示而不是闪退/直接退出
                let alert = UIAlertController(title: "提示", message: "未能读取所选文件内容，请检查文件权限或重试", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "确定", style: .default, handler: { _ in
                    self.dismissExtension()
                }))
                self.present(alert, animated: true, completion: nil)
            } else {
                self.showMainMenu(with: shareData)
            }
        }
    }

    // MARK: - 内存安全型图片处理 (ImageIO)
    private func processImageItem(_ item: NSSecureCoding?, defaultName: String) -> SharedAttachmentItem? {
        if let imageURL = item as? URL {
            let filename = imageURL.lastPathComponent.isEmpty ? defaultName : imageURL.lastPathComponent
            let hasSecurityScope = imageURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    imageURL.stopAccessingSecurityScopedResource()
                }
            }
            return downsampleImage(from: imageURL, filename: filename)
        } else if let image = item as? UIImage {
            return downsampleUIImage(image, filename: defaultName)
        } else if let data = item as? Data {
            return downsampleImageData(data, filename: defaultName)
        }
        return nil
    }

    private func downsampleImage(from url: URL, filename: String, maxDimension: CGFloat = 1600.0) -> SharedAttachmentItem? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            if let data = try? Data(contentsOf: url) {
                return downsampleImageData(data, filename: filename, maxDimension: maxDimension)
            }
            return nil
        }
        return createThumbnailItem(from: source, filename: filename, maxDimension: maxDimension)
    }

    private func downsampleImageData(_ data: Data, filename: String, maxDimension: CGFloat = 1600.0) -> SharedAttachmentItem? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return createThumbnailItem(from: source, filename: filename, maxDimension: maxDimension)
    }

    private func downsampleUIImage(_ image: UIImage, filename: String, maxDimension: CGFloat = 1600.0) -> SharedAttachmentItem? {
        if image.size.width <= maxDimension && image.size.height <= maxDimension {
            guard let jpegData = image.jpegData(compressionQuality: 0.8) else { return nil }
            let base64 = jpegData.base64EncodedString()
            let dataUrl = "data:image/jpeg;base64,\(base64)"
            let safeName = filename.hasSuffix(".jpg") || filename.hasSuffix(".png") ? filename : "\(filename).jpg"
            return SharedAttachmentItem(filename: safeName, mimeType: "image/jpeg", dataUrl: dataUrl, size: jpegData.count)
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return downsampleImageData(data, filename: filename, maxDimension: maxDimension)
    }

    private func createThumbnailItem(from source: CGImageSource, filename: String, maxDimension: CGFloat) -> SharedAttachmentItem? {
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.8) else { return nil }
        let base64 = jpegData.base64EncodedString()
        let dataUrl = "data:image/jpeg;base64,\(base64)"
        let safeName = (filename.hasSuffix(".jpg") || filename.hasSuffix(".png") || filename.hasSuffix(".jpeg")) ? filename : "\(filename).jpg"
        return SharedAttachmentItem(filename: safeName, mimeType: "image/jpeg", dataUrl: dataUrl, size: jpegData.count)
    }

    // MARK: - 安全型普通文件处理
    private func processGenericFileItem(_ item: NSSecureCoding?, defaultName: String) -> SharedAttachmentItem? {
        if let fileURL = item as? URL {
            let filename = fileURL.lastPathComponent.isEmpty ? defaultName : fileURL.lastPathComponent
            let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return encodeGenericFile(data: data, filename: filename, mimeType: mimeType)
        } else if let data = item as? Data {
            return encodeGenericFile(data: data, filename: defaultName, mimeType: "application/octet-stream")
        }
        return nil
    }

    private func encodeGenericFile(data: Data, filename: String, mimeType: String) -> SharedAttachmentItem? {
        guard data.count <= 25 * 1024 * 1024 else { return nil }
        let base64 = data.base64EncodedString()
        let dataUrl = "data:\(mimeType);base64,\(base64)"
        return SharedAttachmentItem(filename: filename, mimeType: mimeType, dataUrl: dataUrl, size: data.count)
    }

    // MARK: - 主操作选择面板
    private func showMainMenu(with shareData: ParsedShareData) {
        let message: String
        let hasAttachments = !shareData.attachments.isEmpty
        if hasAttachments {
            let count = shareData.attachments.count
            message = "已选择 \(count) 个附件" + (shareData.text.isEmpty ? "" : " · \(shareData.text.prefix(30))...")
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

        let shareId = UUID().uuidString
        let payload: [String: Any] = [
            "shareId": shareId,
            "timestamp": Date().timeIntervalSince1970,
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

        var attachmentsPayload: [[String: Any]] = []
        for item in shareData.attachments {
            attachmentsPayload.append([
                "filename": item.filename,
                "mimeType": item.mimeType,
                "dataUrl": item.dataUrl,
                "size": item.size
            ])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15.0

        var payload: [String: Any] = [
            "text": text,
            "sourceTitle": shareData.title.isEmpty ? "iOS 快速归档" : shareData.title,
            "context": "来自 iOS 系统级分享",
            "sourceKind": attachmentsPayload.isEmpty ? "manual" : "image_share"
        ]
        if !attachmentsPayload.isEmpty {
            payload["images"] = attachmentsPayload
            payload["attachments"] = attachmentsPayload
        }
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
            let bounds = self.view.bounds
            let centerX = bounds.midX > 0 ? bounds.midX : 200
            let centerY = bounds.midY > 0 ? bounds.midY : 300
            popover.sourceRect = CGRect(x: centerX, y: centerY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
    }
}
