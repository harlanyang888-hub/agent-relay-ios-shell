import UIKit
import AVFoundation
import Network

@available(iOS 17.4, *)
final class WatchVoiceSession {
    static let shared = WatchVoiceSession()
    private struct Draft: Codable {
        var id = UUID().uuidString
        var session: String
        var segments: [String] = []
        var current: String?
    }
    private struct Delivery: Codable {
        var id: String
        var session: String
        var file: String
        var duration: Double
        var endpoint: String
        var destination: [String: String]
        // 'uncertain' is intentionally not retried against the legacy non-idempotent API.
        var state = "pending"
    }
    private struct Journal: Codable {
        var session: String?
        var draft: Draft?
        var conversations: [String: String] = [:]
        var deliveries: [Delivery] = []
        var unverifiedFiles: [String] = []
    }
    private let directory: URL
    private let recordings: URL
    private var journal = Journal()
    private var storageReady = true
    private var starting = false
    private var finalizing = false
    private var uploading = false
    private var epoch = UInt32.random(in: 1...UInt32.max)
    private var revision: UInt16 = 1
    private var fingerprint = ""
    private let receipts = WatchReceipts()
    private var pending: WatchRequest?
    private let monitor = NWPathMonitor()
    var send: ((Data) -> Void)?
    private(set) var lastError: String?
    var summary: String {
        let uncertain = journal.deliveries.filter { $0.state == "uncertain" }.count
        let name: String
        switch capture {
        case .idle: name = "待命"
        case .starting: name = "正在启动"
        case .recording: name = "录音中"
        case .paused: name = "草稿已暂停"
        case .finalizing: name = "正在保存"
        }
        return "手表：\(name) · 待发 \(journal.deliveries.count) · 结果未确认 \(uncertain)" + (lastError.map { "\n" + $0 } ?? "")
    }

    private init() {
        let fm = FileManager.default
        directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WatchVoice")
        recordings = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
        do {
            for path in [directory, recordings] {
                try fm.createDirectory(at: path, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            }
            let file = directory.appendingPathComponent("journal.json")
            if fm.fileExists(atPath: file.path) { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file)) }
            for i in journal.deliveries.indices where journal.deliveries[i].state == "sending" { journal.deliveries[i].state = "uncertain" }
            if let current = journal.draft?.current {
                let url = recordings.appendingPathComponent(current)
                if let file = try? AVAudioFile(forReading: url), file.length > 0 {
                    journal.draft?.segments.append(current)
                } else {
                    journal.unverifiedFiles.append(current)
                    lastError = "上次录音尾段未通过恢复校验；原文件已保留"
                }
                journal.draft?.current = nil
            }
            if journal.draft?.segments.isEmpty == true { journal.draft = nil }
            try save()
        } catch { storageReady = false; lastError = "草稿存储不可用：\(error.localizedDescription)" }
        if journal.draft != nil { attachRecorder() }
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { DispatchQueue.main.async { self?.flushDeliveries() } }
        }
        monitor.start(queue: DispatchQueue(label: "relay.watch.network"))
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.flushDeliveries() }
    }

    private func save() throws {
        guard storageReady else { throw WatchFailure.storage }
        let path = directory.appendingPathComponent("journal.json")
        try JSONEncoder().encode(journal).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path.path)
    }
    private func log(_ text: String) { DeviceDiagnostics.shared.log("WATCH " + text) }
    private var capture: WatchReply.Capture {
        if finalizing { return .finalizing }
        if starting { return .starting }
        if WearableService.shared.isRecording { return .recording }
        return journal.draft == nil ? .idle : .paused
    }
    private func updateRevision() {
        let value = "\(capture.rawValue):\(journal.draft?.id ?? ""):\(journal.session ?? ""):\(VoiceConversationProbe.shared.callUUID?.uuidString ?? ""):\(journal.deliveries.count)"
        if value != fingerprint {
            fingerprint = value
            if revision == .max { epoch = UInt32.random(in: 1...UInt32.max); revision = 1 }
            else { revision += 1 }
        }
    }
    private func reply(_ request: WatchRequest, _ result: WatchReply.Result, error: UInt8 = 0) {
        updateRevision()
        var packet = WatchReply(result: result, sequence: request.sequence, epoch: epoch, revision: revision, capture: capture)
        if journal.session != nil { packet.flags |= 1 }
        if !journal.deliveries.isEmpty { packet.flags |= 2 }
        packet.error = error
        send?(packet.encoded())
    }
    private func finish(_ request: WatchRequest, succeeded: Bool, error: UInt8 = 0) {
        if pending?.packet == request.packet { pending = nil }
        starting = false
        receipts.record(request, succeeded: succeeded, error: error)
        reply(request, succeeded ? .applied : .rejected, error: error)
    }

    func receive(_ data: Data) {
        guard let request = WatchRequest(data) else { log("拒绝无效 v3 数据包"); return }
        if request.action == .sync { reply(request, .snapshot); flushDeliveries(); return }
        if let result = receipts.result(for: request) {
            reply(request, result.0 ? .applied : .rejected, error: result.1); return
        }
        if let old = pending {
            reply(request, old.packet == request.packet ? .received : .rejected, error: old.packet == request.packet ? 0 : 4)
            return
        }
        updateRevision()
        guard storageReady, !request.expired(), request.epoch == epoch, request.revision == revision,
              !starting, !finalizing else { reply(request, .rejected, error: storageReady ? 3 : 8); return }
        pending = request
        reply(request, .received)
        switch request.action {
        case .sync: break
        case .bootShort:
            if WearableService.shared.isRecording, journal.draft != nil {
                let success = pauseDraft()
                VoiceConversationProbe.shared.pauseAndSend()
                finish(request, succeeded: success, error: success ? 0 : 8)
            } else if journal.draft != nil { start(request) }
            else { finish(request, succeeded: false, error: 5) }
        case .bootLong:
            if journal.draft != nil {
                finalize(ending: false) { [weak self] ok in self?.finish(request, succeeded: ok, error: ok ? 0 : 8) }
            } else if WearableService.shared.isRecording { finish(request, succeeded: false, error: 4) }
            else { start(request) }
        case .end:
            finalize(ending: true) { [weak self] ok in
                guard let self = self else { return }
                if ok { VoiceConversationProbe.shared.end(); self.confirmEnded(request) }
                else { self.finish(request, succeeded: false, error: 8) }
            }
        }
    }

    private func attachRecorder() {
        let service = WearableService.shared
        service.watchRecordingStarted = { [weak self] url in
            guard let self = self, self.journal.draft != nil else { return false }
            self.journal.draft?.current = url.lastPathComponent
            do { try self.save(); return true }
            catch { self.lastError = error.localizedDescription; return false }
        }
        service.watchStopRequested = { [weak self] send in
            guard let self = self else { return }
            if send { self.finalize(ending: false) { _ in } }
            else { _ = self.pauseDraft() }
        }
        service.watchEndRequested = { [weak self] in self?.finalize(ending: true) { _ in } }
    }
    private func detachRecorder() {
        WearableService.shared.watchRecordingStarted = nil
        WearableService.shared.watchStopRequested = nil
        WearableService.shared.watchEndRequested = nil
    }
    private func start(_ request: WatchRequest) {
        let before = journal
        do {
            if journal.session == nil { journal.session = UUID().uuidString }
            if journal.draft == nil { journal.draft = Draft(session: journal.session!) }
            try save()
        } catch { journal = before; lastError = error.localizedDescription; finish(request, succeeded: false, error: 8); return }
        attachRecorder()
        starting = true
        // Reuse the proven LCK activation path, frame-growth confirmation and expiry guard.
        var packet = Data([65, 82, 2, 1])
        packet.append(request.packet.subdata(in: 4..<8))
        packet.watchAppend(UInt32(request.sequence)); packet.watchAppend(request.expires)
        guard let command = BLELabCommand(packet) else { finish(request, succeeded: false, error: 3); return }
        VoiceConversationProbe.shared.executeLabCommand(command) { [weak self] ok, detail in
            guard let self = self else { return }
            self.log(detail)
            if !ok {
                _ = self.pauseDraft()
                if self.journal.draft?.segments.isEmpty == true {
                    if let file = self.journal.draft?.current { self.journal.unverifiedFiles.append(file) }
                    self.journal.draft = nil
                    do { try self.save(); self.detachRecorder() }
                    catch { self.storageReady = false; self.lastError = error.localizedDescription }
                }
            }
            self.finish(request, succeeded: ok, error: ok ? 0 : 6)
        }
    }
    @discardableResult private func pauseDraft() -> Bool {
        guard journal.draft != nil else { return false }
        let wasRecording = WearableService.shared.isRecording
        if let (url, _) = WearableService.shared.sealWatchSegment() {
            if journal.draft?.segments.contains(url.lastPathComponent) == false { journal.draft?.segments.append(url.lastPathComponent) }
            journal.draft?.current = nil
        } else if wasRecording {
            lastError = "采音已停止，当前段校验失败，原文件保留"
            return false
        }
        do { try save(); log("已暂停；有效段数=\(journal.draft?.segments.count ?? 0)"); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    private func finalize(ending: Bool, completion: @escaping (Bool) -> Void) {
        guard !finalizing else { completion(false); return }
        guard let draft = journal.draft else {
            let before = journal
            if ending { journal.session = nil }
            do { try save(); detachRecorder(); completion(true) }
            catch { journal = before; lastError = error.localizedDescription; completion(false) }
            return
        }
        guard pauseDraft(), let saved = journal.draft, !saved.segments.isEmpty else { completion(false); return }
        finalizing = true
        VoiceConversationProbe.shared.pauseAndSend()
        let messageID = UUID().uuidString
        let output = recordings.appendingPathComponent("watch_message_\(messageID).m4a")
        let files = saved.segments.map { recordings.appendingPathComponent($0) }
        let endpoint = WearableService.shared.gatewayBaseURL
        let destination = UserDefaults.standard.dictionary(forKey: "shortcut_recording_destination") as? [String: String] ?? [:]
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Finalize watch voice") {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try WatchAudioMerge.merge(files: files, output: output) }
            DispatchQueue.main.async {
                defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid } }
                self.finalizing = false
                guard self.journal.draft?.id == draft.id else { completion(false); return }
                do {
                    let duration = try result.get()
                    let before = self.journal
                    self.journal.deliveries.append(Delivery(id: messageID, session: saved.session, file: output.lastPathComponent,
                        duration: duration, endpoint: endpoint, destination: destination))
                    self.journal.draft = nil
                    if ending { self.journal.session = nil }
                    do { try self.save() } catch { self.journal = before; throw error }
                    self.detachRecorder()
                    self.log("单条录音已持久保存 duration=\(duration)；等待服务器确认")
                    completion(true)
                    self.flushDeliveries()
                } catch { self.lastError = error.localizedDescription; self.log("合并失败，原始段已保留：\(error)"); completion(false) }
            }
        }
    }

    private func confirmEnded(_ request: WatchRequest) {
        if VoiceConversationProbe.shared.callUUID == nil { finish(request, succeeded: true); return }
        if request.expired() { finish(request, succeeded: false, error: 6); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.confirmEnded(request) }
    }

    // Do not automatically retry an ambiguous POST against the existing gateway.
    // A persistent, server-deduplicated endpoint is required before enabling that retry.
    func flushDeliveries() {
        guard storageReady, !uploading, let delivery = journal.deliveries.first, delivery.state == "pending",
              let cookie = WearableService.shared.authCookie, !cookie.isEmpty,
              let probeURL = URL(string: delivery.endpoint + "/api/bootstrap") else { return }
        uploading = true
        var probe = URLRequest(url: probeURL); probe.timeoutInterval = 8
        probe.setValue(cookie, forHTTPHeaderField: "Cookie"); probe.setValue(delivery.endpoint, forHTTPHeaderField: "Origin")
        URLSession.shared.dataTask(with: probe) { _, response, error in
            DispatchQueue.main.async {
                guard error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    self.uploading = false; self.lastError = "录音已保存；网关暂不可达或需要登录"; return
                }
                self.upload(delivery, cookie: cookie)
            }
        }.resume()
    }
    private func upload(_ delivery: Delivery, cookie: String) {
        guard let index = journal.deliveries.firstIndex(where: { $0.id == delivery.id }),
              let url = URL(string: delivery.endpoint + "/api/shortcuts/voice") else { uploading = false; return }
        do {
            let audio = try Data(contentsOf: recordings.appendingPathComponent(delivery.file))
            var payload: [String: Any] = ["audioBase64": audio.base64EncodedString(), "filename": delivery.file,
                "mimeType": "audio/m4a", "prompt": "【手表语音指令】", "hostId": "ubuntu", "project": "ubuntu-antigravity", "cwd": "/home/complicated/project/voice-hub"]
            for (key, value) in delivery.destination { payload[key] = value }
            if let id = journal.conversations[delivery.session] { payload["conversationId"] = id }
            let body = try JSONSerialization.data(withJSONObject: payload)
            journal.deliveries[index].state = "sending"
            try save() // A process death after this point requires reconciliation, not blind replay.
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(cookie, forHTTPHeaderField: "Cookie"); request.setValue(delivery.endpoint, forHTTPHeaderField: "Origin")
            URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    self.uploading = false
                    guard let index = self.journal.deliveries.firstIndex(where: { $0.id == delivery.id }) else { return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    if error == nil, (200...299).contains(status), json?["ok"] as? Bool == true,
                       let conversation = json?["conversationId"] as? String, let message = json?["messageId"] as? String, !message.isEmpty {
                        self.journal.conversations[delivery.session] = conversation
                        self.journal.deliveries.remove(at: index)
                        self.log("服务器已接收 messageId=\(message) conversationId=\(conversation)")
                    } else if status == 409, let conversation = json?["conversationId"] as? String {
                        self.journal.conversations[delivery.session] = conversation
                        self.journal.deliveries[index].state = "pending"
                        self.lastError = "录音已保存；Agent 暂时离线"
                    } else {
                        self.journal.deliveries[index].state = "uncertain"
                        self.lastError = "上传结果未确认，文件已保留；暂停自动重发以避免重复消息"
                        self.log(self.lastError!)
                    }
                    do { try self.save() } catch { self.storageReady = false; self.log("保存发送结果失败：\(error)") }
                    if self.journal.deliveries.first?.id != delivery.id { self.flushDeliveries() }
                }
            }.resume()
        } catch { uploading = false; storageReady = false; lastError = error.localizedDescription; log("发送准备失败，文件保留：\(error)") }
    }
    private enum WatchFailure: Error { case storage, audio }
}
