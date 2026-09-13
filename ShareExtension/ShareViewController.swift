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
    var urls: [URL] = []
    var attachments: [SharedAttachmentItem] = []
}

class ShareViewController: UIViewController {

    private let gatewayBaseURL = "https://complicated.taildbe095.ts.net:8443"
    // 携带 Gateway 鉴权 Token (与 Gateway & Smart Cards 互通)
    private let authToken = "36a019b34a706c581073c07157aeef9b64738026b920972e4d34d0a27919d548"

    private var progressAlert: UIAlertController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.35)

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

    // MARK: - 多附件异步解析与提取
    private func handleSharedContent() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem], !extensionItems.isEmpty else {
            dismissWithFeedback(success: false, message: "无可用分享内容")
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

        // 解析所有图片
        for (index, provider) in imageProviders.enumerated() {
            group.enter()
            let filename = "image_\(index + 1).jpg"
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { (item, _) in
                defer { group.leave() }
                if let imageURL = item as? URL, let data = try? Data(contentsOf: imageURL), let image = UIImage(data: data) {
                    if let attachment = self.processImage(image, filename: imageURL.lastPathComponent) {
                        DispatchQueue.main.async {
                            shareData.attachments.append(attachment)
                        }
                    }
                } else if let image = item as? UIImage {
                    if let attachment = self.processImage(image, filename: filename) {
                        DispatchQueue.main.async {
                            shareData.attachments.append(attachment)
                        }
                    }
                } else if let data = item as? Data, let image = UIImage(data: data) {
                    if let attachment = self.processImage(image, filename: filename) {
                        DispatchQueue.main.async {
                            shareData.attachments.append(attachment)
                        }
                    }
                }
            }
        }

        // 解析所有网页链接
        for provider in urlProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { (item, _) in
                defer { group.leave() }
                if let url = item as? URL {
                    DispatchQueue.main.async {
                        shareData.urls.append(url)
                    }
                }
            }
        }

        // 解析所有文本
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
                self.dismissWithFeedback(success: false, message: "无法提取分享内容")
            } else {
                self.showMainMenu(with: shareData)
            }
        }
    }

    private func processImage(_ image: UIImage, filename: String) -> SharedAttachmentItem? {
        let maxDimension: CGFloat = 1920.0
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

        guard let jpegData = targetImage.jpegData(compressionQuality: 0.82) else { return nil }
        let base64 = jpegData.base64EncodedString()
        let dataUrl = "data:image/jpeg;base64,\(base64)"
        let safeName = filename.hasSuffix(".jpg") || filename.hasSuffix(".png") ? filename : "\(filename).jpg"

        return SharedAttachmentItem(filename: safeName, mimeType: "image/jpeg", dataUrl: dataUrl, size: jpegData.count)
    }

    // MARK: - 主操作菜单
    private func showMainMenu(with shareData: ParsedShareData) {
        let message: String
        let hasImages = !shareData.attachments.isEmpty
        if hasImages {
            let count = shareData.attachments.count
            message = "已就绪: \(count) 张图片" + (shareData.text.isEmpty ? "" : " · \(shareData.text.prefix(30))...")
        } else if let firstUrl = shareData.urls.first {
            message = "网页: \(firstUrl.absoluteString)"
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

        // 1. 🤖 问 Agent Relay (新建会话并提问)
        alert.addAction(UIAlertAction(title: "🤖 问 Agent Relay (新建会话并提问)", style: .default, handler: { [weak self] _ in
            self?.showAskAgentDialog(with: shareData)
        }))

        // 2. 🚀 在 Agent Relay 中打开并对话 (一键开启新会话)
        alert.addAction(UIAlertAction(title: "🚀 在 Agent Relay 中打开并对话", style: .default, handler: { [weak self] _ in
            let defaultPrompt = hasImages ? "请查看我分享的图片，并帮我分析其中的核心内容与要点。" : (shareData.text.isEmpty ? (shareData.urls.first?.absoluteString ?? "请分析我分享的内容") : shareData.text)
            self?.executeCreateConversation(prompt: defaultPrompt, sharedData: shareData)
        }))

        // 3. 💡 存入 Smart Cards (知识卡片)
        alert.addAction(UIAlertAction(title: "💡 存入 Smart Cards (知识卡片)", style: .default, handler: { [weak self] _ in
            self?.saveToSmartCards(with: shareData)
        }))

        // 4. 📋 复制为 Markdown 摘录
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

    // MARK: - AI 提问与分析二级弹窗
    private func showAskAgentDialog(with shareData: ParsedShareData) {
        let hasImages = !shareData.attachments.isEmpty
        let alert = UIAlertController(
            title: "🤖 问 Agent Relay",
            message: hasImages ? "选择针对这 \(shareData.attachments.count) 张图片的分析模式：" : "选择分析模式或输入自定义指令：",
            preferredStyle: .actionSheet
        )

        let presets: [(label: String, prompt: String)]
        if hasImages {
            presets = [
                ("🔍 详细分析图片内容与关键信息", "请详细分析我分享的图片中的所有关键视觉元素、主体内容与核心信息。"),
                ("📝 提取图中所有文字与表格数据", "请识别并提取这些图片中的所有文字内容、表格数据和结构化信息。"),
                ("🐞 代码截图排查与技术解答", "这是一段代码/错误日志截图，请帮我分析报错原因、定位潜在问题并给出修复代码。"),
                ("💡 提炼要点与行动待办", "请总结图片内容中的要点，并提取出明确的行动建议与待办清单。")
            ]
        } else {
            let baseContent = shareData.text.isEmpty ? (shareData.urls.first?.absoluteString ?? "") : shareData.text
            presets = [
                ("📌 核心观点与总结", "请提炼以下内容的核心观点、主要论据和最终结论：\n\n---\n\(baseContent)"),
                ("🔍 深度概念与背景解析", "请对以下内容进行深度解析、背景解读并指出关键价值：\n\n---\n\(baseContent)"),
                ("✅ 提炼行动项与待办", "请从以下内容中提取所有行动项、待办事项和执行建议：\n\n---\n\(baseContent)"),
                ("💡 批判性视角分析", "请从批判性思维角度分析以下内容的优缺点、潜在风险和漏洞：\n\n---\n\(baseContent)")
            ]
        }

        for preset in presets {
            alert.addAction(UIAlertAction(title: preset.label, style: .default, handler: { [weak self] _ in
                self?.executeCreateConversation(prompt: preset.prompt, sharedData: shareData)
            }))
        }

        alert.addAction(UIAlertAction(title: "✍️ 自定义 Prompt 提问...", style: .default, handler: { [weak self] _ in
            self?.showCustomPromptInput(with: shareData)
        }))

        alert.addAction(UIAlertAction(title: "返回", style: .cancel, handler: { [weak self] _ in
            self?.showMainMenu(with: shareData)
        }))

        configurePopover(for: alert)
        present(alert, animated: true, completion: nil)
    }

    // MARK: - 自定义输入
    private func showCustomPromptInput(with shareData: ParsedShareData) {
        let alert = UIAlertController(
            title: "✍️ 自定义提问",
            message: "输入您想让 Agent 处理或分析的指令：",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "例如：帮我把这段转成需求文档 / 翻译成英文"
            textField.clearButtonMode = .whileEditing
        }

        let submitAction = UIAlertAction(title: "发起对话", style: .default) { [weak self] _ in
            let customPrompt = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prefix = customPrompt.isEmpty ? "请分析以下内容" : customPrompt
            let fullPrompt: String
            if !shareData.attachments.isEmpty {
                fullPrompt = prefix
            } else {
                let baseContent = shareData.text.isEmpty ? (shareData.urls.first?.absoluteString ?? "") : shareData.text
                fullPrompt = "\(prefix)\n\n---\n\(baseContent)"
            }
            self?.executeCreateConversation(prompt: fullPrompt, sharedData: shareData)
        }

        let cancelAction = UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.dismissExtension()
        }

        alert.addAction(submitAction)
        alert.addAction(cancelAction)
        present(alert, animated: true, completion: nil)
    }

    // MARK: - 核心执行流程：上传附件 -> 获取主机 -> 创建会话 -> 发送消息 -> 呼起 App
    private func executeCreateConversation(prompt: String, sharedData: ParsedShareData) {
        showProgressAlert(message: "正在准备上传...")

        uploadAttachments(sharedData.attachments) { [weak self] uploadResult in
            guard let self = self else { return }
            switch uploadResult {
            case .failure(let error):
                self.dismissWithFeedback(success: false, message: "图片上传失败: \(error.localizedDescription)")
            case .success(let uploadedAttachments):
                self.updateProgressAlert(message: "正在获取可用 Agent 主机...")
                self.fetchBootstrap { [weak self] hostId, project in
                    guard let self = self, let hostId = hostId, let project = project else {
                        self?.dismissWithFeedback(success: false, message: "未能连接到可用 Agent 主机，请检查网关")
                        return
                    }

                    self.updateProgressAlert(message: "正在创建新会话...")
                    let convTitle = self.makeConversationTitle(prompt: prompt, imageCount: sharedData.attachments.count)
                    self.createConversation(hostId: hostId, project: project, title: convTitle) { [weak self] convId in
                        guard let self = self, let convId = convId else {
                            self?.dismissWithFeedback(success: false, message: "创建会话失败")
                            return
                        }

                        self.updateProgressAlert(message: "正在发送消息与附件...")
                        self.sendMessage(conversationId: convId, content: prompt, attachments: uploadedAttachments) { [weak self] sendOk in
                            guard let self = self else { return }
                            if sendOk {
                                self.hideProgressAlert {
                                    self.openApp(conversationId: convId)
                                }
                            } else {
                                self.dismissWithFeedback(success: false, message: "消息发送失败")
                            }
                        }
                    }
                }
            }
        }
    }

    private func uploadAttachments(_ items: [SharedAttachmentItem], completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
        if items.isEmpty {
            completion(.success([]))
            return
        }

        var results: [[String: Any]] = []
        let group = DispatchGroup()
        var uploadError: Error?

        for (index, item) in items.enumerated() {
            group.enter()
            self.updateProgressAlert(message: "正在上传图片 (\(index + 1)/\(items.count))...")
            
            guard let url = URL(string: "\(gatewayBaseURL)/api/upload") else {
                group.leave()
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

            let payload: [String: Any] = [
                "filename": item.filename,
                "mimeType": item.mimeType,
                "dataUrl": item.dataUrl
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
                defer { group.leave() }
                if let error = error {
                    uploadError = error
                    return
                }
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async {
                        results.append(json)
                    }
                }
            }
            task.resume()
        }

        group.notify(queue: .main) {
            if let error = uploadError, results.isEmpty {
                completion(.failure(error))
            } else {
                completion(.success(results))
            }
        }
    }

    private func fetchBootstrap(completion: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: "\(gatewayBaseURL)/api/bootstrap") else {
            completion(nil, nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.dataTask(with: request) { (data, response, _) in
            DispatchQueue.main.async {
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let hosts = json["hosts"] as? [[String: Any]], !hosts.isEmpty else {
                    completion(nil, nil)
                    return
                }

                // 优先找已连接在线的项目
                for host in hosts {
                    guard let hostId = host["id"] as? String,
                          let projects = host["projects"] as? [[String: Any]] else { continue }
                    for project in projects {
                        if let name = project["name"] as? String,
                           let connected = project["connected"] as? Bool, connected {
                            completion(hostId, name)
                            return
                        }
                    }
                }

                // 兜底返回第一个主机的第一个项目
                if let firstHost = hosts.first,
                   let hostId = firstHost["id"] as? String,
                   let projects = firstHost["projects"] as? [[String: Any]],
                   let firstProject = projects.first,
                   let projectName = firstProject["name"] as? String {
                    completion(hostId, projectName)
                    return
                }

                completion(nil, nil)
            }
        }
        task.resume()
    }

    private func createConversation(hostId: String, project: String, title: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "\(gatewayBaseURL)/api/conversations") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "hostId": hostId,
            "project": project,
            "title": title
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let task = URLSession.shared.dataTask(with: request) { (data, response, _) in
            DispatchQueue.main.async {
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["id"] as? String else {
                    completion(nil)
                    return
                }
                completion(id)
            }
        }
        task.resume()
    }

    private func sendMessage(conversationId: String, content: String, attachments: [[String: Any]], completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(gatewayBaseURL)/api/conversations/\(conversationId)/messages") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        var payload: [String: Any] = ["content": content]
        if !attachments.isEmpty {
            payload["attachments"] = attachments
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let task = URLSession.shared.dataTask(with: request) { (_, response, error) in
            DispatchQueue.main.async {
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) && error == nil {
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
        task.resume()
    }

    // MARK: - 存入 Smart Cards
    private func saveToSmartCards(with shareData: ParsedShareData) {
        showProgressAlert(message: "正在存入知识库...")

        var text = shareData.text
        if text.isEmpty && !shareData.urls.isEmpty {
            text = shareData.urls.map { $0.absoluteString }.joined(separator: "\n")
        }
        if text.isEmpty && !shareData.attachments.isEmpty {
            text = "[图片分享] 共 \(shareData.attachments.count) 张图片"
        }
        if text.isEmpty {
            text = shareData.title.isEmpty ? "来自 iOS 快速归档" : shareData.title
        }

        guard let url = URL(string: "\(gatewayBaseURL)/api/cards/capture") else {
            dismissWithFeedback(success: false, message: "URL 错误")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")

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
            let links = shareData.urls.map { "[\(shareData.title.isEmpty ? $0.absoluteString : shareData.title)](\($0.absoluteString))" }
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

    // MARK: - 呼起主 App 并进入指定会话
    private func openApp(conversationId: String) {
        guard let url = URL(string: "agentrelay://chat?conversationId=\(conversationId)") else {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self?.dismissExtension()
            }
        })
    }

    // MARK: - 进度条弹窗与辅助反馈
    private func showProgressAlert(message: String) {
        let alert = UIAlertController(title: "正在处理中", message: message, preferredStyle: .alert)
        self.progressAlert = alert
        present(alert, animated: true, completion: nil)
    }

    private func updateProgressAlert(message: String) {
        progressAlert?.message = message
    }

    private func hideProgressAlert(completion: @escaping () -> Void) {
        if let alert = progressAlert {
            alert.dismiss(animated: true) {
                completion()
            }
            self.progressAlert = nil
        } else {
            completion()
        }
    }

    private func dismissWithFeedback(success: Bool, message: String) {
        hideProgressAlert { [weak self] in
            guard let self = self else { return }
            let alert = UIAlertController(title: success ? "成功" : "提示", message: message, preferredStyle: .alert)
            self.present(alert, animated: true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
                    alert.dismiss(animated: true) {
                        self?.dismissExtension()
                    }
                }
            }
        }
    }

    private func dismissExtension() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func makeConversationTitle(prompt: String, imageCount: Int) -> String {
        let clean = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = imageCount > 0 ? "[\(imageCount)图] " : ""
        let snippet = clean.count > 25 ? String(clean.prefix(25)) + "..." : clean
        return "\(prefix)\(snippet.isEmpty ? "快速提问" : snippet)"
    }

    private func configurePopover(for alert: UIAlertController) {
        if let popover = alert.popoverPresentationController {
            popover.sourceView = self.view
            popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
    }
}
