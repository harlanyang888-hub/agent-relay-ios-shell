import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0, alpha: 0.15)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleSharedContent()
    }

    // MARK: - 极速提取并直通跳转主应用 (零阻塞，毫秒级唤起)
    private func handleSharedContent() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem], !extensionItems.isEmpty else {
            dismissExtension()
            return
        }

        var textContent = ""
        var titleContent = ""
        var urls: [String] = []
        var imageProviders: [NSItemProvider] = []
        var filesPayload: [[String: Any]] = []

        let group = DispatchGroup()

        for item in extensionItems {
            if let attributed = item.attributedContentText?.string, !attributed.isEmpty {
                if titleContent.isEmpty {
                    titleContent = attributed
                } else if textContent.isEmpty {
                    textContent = attributed
                }
            }
            if let attachments = item.attachments {
                for provider in attachments {
                    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                        imageProviders.append(provider)
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        group.enter()
                        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { (urlItem, _) in
                            defer { group.leave() }
                            if let url = urlItem as? URL {
                                urls.append(url.absoluteString)
                            }
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        group.enter()
                        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { (textItem, _) in
                            defer { group.leave() }
                            if let text = textItem as? String {
                                if textContent.isEmpty {
                                    textContent = text
                                } else {
                                    textContent += "\n" + text
                                }
                            }
                        }
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
                        filesPayload.append(fileItem)
                    }
                } else if let image = item as? UIImage {
                    if let fileItem = self.compressAndEncodeImage(image, filename: defaultName) {
                        filesPayload.append(fileItem)
                    }
                } else if let data = item as? Data, let image = UIImage(data: data) {
                    if let fileItem = self.compressAndEncodeImage(image, filename: defaultName) {
                        filesPayload.append(fileItem)
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }

            if textContent.isEmpty && !urls.isEmpty {
                textContent = urls.joined(separator: "\n")
            }

            let payload: [String: Any] = [
                "text": textContent,
                "title": titleContent,
                "files": filesPayload
            ]

            // 将分享内容存入剪贴板专属格式 (内存快速传递给主应用)
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
                UIPasteboard.general.setData(jsonData, forPasteboardType: "com.complicated.agentrelay.share")
            }

            // 立即唤起主应用
            self.openMainApp()
        }
    }

    private func compressAndEncodeImage(_ image: UIImage, filename: String) -> [String: Any]? {
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

        return [
            "name": safeName,
            "type": "image/jpeg",
            "dataUrl": dataUrl
        ]
    }

    private func openMainApp() {
        guard let url = URL(string: "agentrelay://share") else {
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

    private func dismissExtension() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
