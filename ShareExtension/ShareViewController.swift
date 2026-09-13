import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let targetURLString = "https://complicated.taildbe095.ts.net:8443/api/cards/capture"
    // 携带 Gateway 鉴权 Token (与 Smart Cards 互联)
    private let authToken = "36a019b34a706c581073c07157aeef9b64738026b920972e4d34d0a27919d548"

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

    // MARK: - 内容解析
    private func handleSharedContent() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments, !attachments.isEmpty else {
            // 如果只有富文本或标题
            if let text = (extensionContext?.inputItems.first as? NSExtensionItem)?.attributedContentText?.string, !text.isEmpty {
                showMainMenu(text: text, title: "iOS 划词摘录")
            } else {
                dismissWithFeedback(success: false, message: "无可用内容")
            }
            return
        }

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] (item, _) in
                    DispatchQueue.main.async {
                        if let url = item as? URL {
                            let title = extensionItem.attributedContentText?.string ?? "网页链接"
                            self?.showMainMenu(text: url.absoluteString, title: title)
                        } else {
                            self?.dismissWithFeedback(success: false, message: "无法解析网页链接")
                        }
                    }
                }
                return
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] (item, _) in
                    DispatchQueue.main.async {
                        if let text = item as? String {
                            self?.showMainMenu(text: text, title: "iOS 划词摘录")
                        } else {
                            self?.dismissWithFeedback(success: false, message: "无法解析文本内容")
                        }
                    }
                }
                return
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] (item, _) in
                    DispatchQueue.main.async {
                        if let imageURL = item as? URL {
                            self?.showMainMenu(text: "[图片分享] \(imageURL.lastPathComponent)", title: "iOS 图片分享")
                        } else {
                            self?.showMainMenu(text: "[图片分享] 来自 iOS 系统相册/截图", title: "iOS 图片分享")
                        }
                    }
                }
                return
            }
        }

        if let text = extensionItem.attributedContentText?.string, !text.isEmpty {
            showMainMenu(text: text, title: "iOS 划词摘录")
        } else {
            dismissWithFeedback(success: false, message: "无法解析分享内容")
        }
    }

    // MARK: - 主操作菜单
    private func showMainMenu(text: String, title: String) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = cleanText.count > 60 ? String(cleanText.prefix(60)) + "..." : cleanText
        let message = "已提取: \(snippet)"

        let alert = UIAlertController(
            title: "Agent Relay 智能中继",
            message: message,
            preferredStyle: .actionSheet
        )

        // 1. 存入知识卡片 (Smart Cards)
        alert.addAction(UIAlertAction(title: "💡 存入 Smart Cards (知识卡片)", style: .default, handler: { [weak self] _ in
            self?.sendCapture(text: cleanText, title: title, context: "来自 iOS 快速归档")
        }))

        // 2. 问 Agent Relay (AI 总结与分析)
        alert.addAction(UIAlertAction(title: "🤖 问 Agent Relay (AI 总结与分析)", style: .default, handler: { [weak self] _ in
            self?.showAskAgentDialog(text: cleanText, title: title)
        }))

        // 3. 在主 App 中打开对话
        alert.addAction(UIAlertAction(title: "🚀 在 Agent Relay 中打开并对话", style: .default, handler: { [weak self] _ in
            self?.openApp(with: cleanText)
        }))

        // 4. 复制为 Markdown 摘录
        alert.addAction(UIAlertAction(title: "📋 复制为 Markdown 摘录", style: .default, handler: { [weak self] _ in
            self?.copyAsMarkdown(text: cleanText, title: title)
        }))

        // 取消
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: { [weak self] _ in
            self?.dismissExtension()
        }))

        configurePopover(for: alert)
        present(alert, animated: true, completion: nil)
    }

    // MARK: - AI 提问与分析二级弹窗
    private func showAskAgentDialog(text: String, title: String) {
        let alert = UIAlertController(
            title: "🤖 问 Agent Relay",
            message: "请选择分析模式或输入自定义指令：",
            preferredStyle: .actionSheet
        )

        let presets: [(label: String, promptPrefix: String)] = [
            ("📌 核心观点与总结", "请提炼以下内容的核心观点、主要论据和最终结论："),
            ("🔍 概念深度解析", "请对以下内容进行深度解析、背景解读并指出关键价值："),
            ("✅ 提炼行动项与待办", "请从以下内容中提取所有行动项、待办事项和执行建议："),
            ("💡 批判性视角分析", "请从批判性思维角度分析以下内容的优缺点、潜在风险和漏洞：")
        ]

        for preset in presets {
            alert.addAction(UIAlertAction(title: preset.label, style: .default, handler: { [weak self] _ in
                let combinedText = "\(preset.promptPrefix)\n\n---\n\(text)"
                self?.sendCapture(text: combinedText, title: title, context: "来自 iOS 快捷 AI 分析 (\(preset.label))")
            }))
        }

        alert.addAction(UIAlertAction(title: "✍️ 自定义 Prompt 提问...", style: .default, handler: { [weak self] _ in
            self?.showCustomPromptInput(text: text, title: title)
        }))

        alert.addAction(UIAlertAction(title: "返回", style: .cancel, handler: { [weak self] _ in
            self?.showMainMenu(text: text, title: title)
        }))

        configurePopover(for: alert)
        present(alert, animated: true, completion: nil)
    }

    // MARK: - 自定义输入
    private func showCustomPromptInput(text: String, title: String) {
        let alert = UIAlertController(
            title: "✍️ 自定义提问",
            message: "输入您想让 Agent 处理或分析的指令：",
            preferredStyle: .alert
        )

        alert.addTextField { textField in
            textField.placeholder = "例如：帮我把这段转成需求文档 / 翻译成英文"
            textField.clearButtonMode = .whileEditing
        }

        let submitAction = UIAlertAction(title: "发送分析", style: .default) { [weak self] _ in
            let customPrompt = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prefix = customPrompt.isEmpty ? "请分析以下内容：" : "\(customPrompt)\n\n---\n"
            let combinedText = "\(prefix)\(text)"
            self?.sendCapture(text: combinedText, title: title, context: "来自 iOS 自定义 AI 提问")
        }

        let cancelAction = UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.dismissExtension()
        }

        alert.addAction(submitAction)
        alert.addAction(cancelAction)
        present(alert, animated: true, completion: nil)
    }

    // MARK: - 复制 Markdown
    private func copyAsMarkdown(text: String, title: String) {
        let markdown: String
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            markdown = "[\(title)](\(text))"
        } else {
            let quote = text.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
            markdown = "\(quote)\n\n— 来源: \(title)"
        }
        UIPasteboard.general.string = markdown
        dismissWithFeedback(success: true, message: "已复制 Markdown 摘录 📋")
    }

    // MARK: - 呼起主 App
    private func openApp(with text: String) {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "agentrelay://chat?text=\(encoded)") else {
            dismissExtension()
            return
        }

        // 尝试通过 extensionContext 打开 URL
        self.extensionContext?.open(url, completionHandler: { [weak self] success in
            if !success {
                // 如果 extensionContext.open 受限，尝试通过响应者链兜底
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.dismissExtension()
            }
        })
    }

    // MARK: - 提交到 Gateway / Smart Cards
    private func sendCapture(text: String, title: String, context: String) {
        guard let url = URL(string: targetURLString) else {
            dismissWithFeedback(success: false, message: "网关 URL 配置错误")
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
            "context": context
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let task = URLSession.shared.dataTask(with: request) { [weak self] (_, response, error) in
            DispatchQueue.main.async {
                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? 0

                if error == nil && (statusCode == 200 || statusCode == 201) {
                    self?.dismissWithFeedback(success: true, message: "已成功存入 Smart Cards ✨")
                } else {
                    self?.dismissWithFeedback(success: false, message: "存入失败 (HTTP \(statusCode))，请检查网关")
                }
            }
        }
        task.resume()
    }

    // MARK: - 辅助反馈与退出
    private func dismissWithFeedback(success: Bool, message: String) {
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
