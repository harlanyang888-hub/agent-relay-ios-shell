#if !RELAY_HEADLESS_TEST
import UIKit
import AVFoundation
import Network
#else
import Foundation
import FoundationNetworking
#endif

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
        var state = "pending"
        var idempotent: Bool? = false
    }
    private struct Journal: Codable {
        var session: String?
        var draft: Draft?
        var conversations: [String: String] = [:]
        // Optional for compatibility with journals written by earlier builds.
        var sessionDestinations: [String: [String: String]]?
        var sessionEndpoints: [String: String]?
        var deliveries: [Delivery] = []
        var unverifiedFiles: [String] = []
    }
    private let directory: URL
    private let recordings: URL
    private var journal = Journal()
    private var storageReady = true
    private var starting = false
    private var finalizing = false
    private var endAfterFinalizing = false
    private var endAfterSaveRequest: WatchRequest?
    private var uploading = false
    private var uploadTask: UIBackgroundTaskIdentifier = .invalid
    private var retryWork: DispatchWorkItem?
    private var retryAttempt = 0
    private var epoch = UInt32.random(in: 1...UInt32.max)
    private var revision: UInt16 = 1
    private var fingerprint = ""
    private let receipts = WatchReceipts()
    private var pending: WatchRequest?
    private var phoneBoot = UInt32.random(in: 1...UInt32.max)
    private var phoneSequence: UInt16 = 0
    private var phoneEndPending = false
    private let monitor = NWPathMonitor()
    var send: ((Data) -> Void)?
    private(set) var lastError: String?
    var hasDraft: Bool { journal.draft != nil }
    var isPausedDraft: Bool { journal.draft != nil && !WearableService.shared.isRecording && !starting && !finalizing }
    var summary: String {
        let uncertain = journal.deliveries.filter { ["uncertain", "needsReview"].contains($0.state) }.count
        let name: String
        switch capture {
        case .idle: name = "待命"
        case .starting: name = "正在启动"
        case .recording: name = "录音中"
        case .paused: name = "草稿已暂停"
        case .finalizing: name = "正在保存"
        }
        let conversation = journal.session == nil ? "下次新建对话" : "继续当前对话"
        return "手表：\(name) · \(conversation)\n待发 \(journal.deliveries.count) · 需处理 \(uncertain)" + (lastError.map { "\n" + $0 } ?? "")
    }

    // The normal singleton uses app directories. An isolated root permits
    // restart/failure tests to run this same controller without phone storage.
    init(storageRoot: URL? = nil) {
        let fm = FileManager.default
        directory = (storageRoot ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]).appendingPathComponent("WatchVoice")
        recordings = (storageRoot ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]).appendingPathComponent("Recordings")
        recoverStorage()
        if journal.draft != nil { attachRecorder() }
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { DispatchQueue.main.async { self?.flushDeliveries() } }
        }
        monitor.start(queue: DispatchQueue(label: "relay.watch.network"))
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.flushDeliveries() }
        NotificationCenter.default.addObserver(forName: Notification.Name("RelayAuthenticationChanged"), object: nil, queue: .main) { [weak self] _ in self?.flushDeliveries() }
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.storageReady, !self.starting, !self.finalizing,
                  !WearableService.shared.isRecording else { return }
            self.recoverStorage()
            if self.storageReady, self.journal.draft != nil { self.attachRecorder() }
            self.flushDeliveries()
        }
    }

    private func recoverStorage() {
        let fm = FileManager.default
        storageReady = true
        do {
            for path in [directory, recordings] {
                #if RELAY_HEADLESS_TEST
                try fm.createDirectory(at: path, withIntermediateDirectories: true)
                #else
                try fm.createDirectory(at: path, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                #endif
            }
            let file = directory.appendingPathComponent("journal.json")
            if fm.fileExists(atPath: file.path) { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: file)) }
            for i in journal.deliveries.indices where journal.deliveries[i].state == "sending" {
                journal.deliveries[i].state = journal.deliveries[i].idempotent == true ? "pending" : "uncertain"
            }
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
    }

    private func save() throws {
        guard storageReady else { throw WatchFailure.storage }
        let path = directory.appendingPathComponent("journal.json")
        try JSONEncoder().encode(journal).write(to: path, options: .atomic)
        #if !RELAY_HEADLESS_TEST
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path.path)
        #endif
    }
    private func log(_ text: String) { DeviceDiagnostics.shared.log("WATCH " + text) }

    // All phone entry points use the same journal, command gate and outcomes as
    // the watch. A phone stop can no longer bypass the watch's draft/context.
    func phoneStart() {
        guard !WearableService.shared.isRecording, !starting, !finalizing else { return }
        phoneAction(journal.draft == nil ? .bootLong : .bootShort)
    }
    func phoneSend() {
        if starting { VoiceConversationProbe.shared.cancelPendingStart() }
        phoneAction(.bootLong, sendingOnly: true)
    }
    func phoneEnd() {
        phoneEndPending = true
        if starting { VoiceConversationProbe.shared.cancelPendingStart() }
        drainPhoneEnd()
    }
    private func drainPhoneEnd() {
        guard phoneEndPending, pending == nil, !starting, !finalizing else { return }
        phoneEndPending = false
        phoneAction(.end)
    }
    func phonePause() {
        guard WearableService.shared.isRecording else { return }
        phoneAction(.bootShort)
    }
    func phoneToggle() { phoneAction(.bootLong) }
    private func phoneAction(_ action: WatchRequest.Action, sendingOnly: Bool = false) {
        if sendingOnly, journal.draft == nil { return }
        guard pending == nil, !starting, !finalizing else { log("手机操作等待当前动作完成"); return }
        updateRevision()
        if phoneSequence == .max { phoneBoot = UInt32.random(in: 1...UInt32.max); phoneSequence = 0 }
        phoneSequence += 1
        var packet = Data([65, 82, 3, action.rawValue])
        packet.watchAppend(phoneBoot); packet.watchAppend(phoneSequence)
        packet.watchAppend(epoch); packet.watchAppend(revision)
        packet.watchAppend(UInt32(clamping: Int64(Date().timeIntervalSince1970)) + 8)
        receive(packet)
    }
    private var capture: WatchReply.Capture {
        if finalizing { return .finalizing }
        if starting { return .starting }
        if WearableService.shared.isRecording { return .recording }
        return journal.draft == nil ? .idle : .paused
    }
    private func updateRevision() {
        // Upload progress isn't a recording-state transition. It must not make
        // a fresh physical gesture stale between snapshot and command.
        let value = "\(capture.rawValue):\(journal.draft?.id ?? ""):\(journal.session ?? "")"
        if value != fingerprint {
            fingerprint = value
            if revision == .max { epoch = UInt32.random(in: 1...UInt32.max); revision = 1 }
            else { revision += 1 }
        }
    }
    private func reply(_ request: WatchRequest, _ result: WatchReply.Result, error: UInt8 = 0) {
        // Phone-generated sequences have no corresponding pending watch packet.
        guard request.packet.watchUInt32(4) != phoneBoot else { return }
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
        drainPhoneEnd()
    }

    func receive(_ data: Data) {
        guard let request = WatchRequest(data) else { log("拒绝无效 v3 数据包"); return }
        if request.action == .sync { reply(request, .snapshot); flushDeliveries(); return }
        log("收到动作 action=\(request.action.rawValue) id=\(request.key) capture=\(capture.rawValue)")
        if let result = receipts.result(for: request) {
            reply(request, result.0 ? .applied : .rejected, error: result.1); return
        }
        var endSupersedesPending = false
        if request.action == .end, let old = pending, old.action != .end {
            updateRevision()
            guard storageReady, request.isFresh(), request.epoch == epoch, request.revision == revision else {
                reply(request, .rejected, error: storageReady ? 3 : 8); return
            }
            if finalizing {
                endAfterFinalizing = true
                endAfterSaveRequest = request
                pending = request
                reply(request, .received)
                return
            }
            if starting { VoiceConversationProbe.shared.cancelPendingStart() }
            // The old pause/close acknowledgement may still finish later. Its
            // captured request cannot clear this new end request.
            pending = nil
            endSupersedesPending = true
        }
        if let old = pending {
            if old.packet != request.packet { receipts.record(request, succeeded: false, error: 4) }
            reply(request, old.packet == request.packet ? .received : .rejected, error: old.packet == request.packet ? 0 : 4)
            return
        }
        guard !WearableService.shared.inputComparisonActive else {
            finish(request, succeeded: false, error: 4)
            return
        }
        updateRevision()
        guard storageReady, request.isFresh(),
              request.epoch == epoch, (request.revision == revision || endSupersedesPending),
              !starting, !finalizing else {
            log("动作拒绝：storage=\(storageReady) fresh=\(request.isFresh()) epoch=\(request.epoch == epoch) revision=\(request.revision)/\(revision)")
            finish(request, succeeded: false, error: storageReady ? 3 : 8); return
        }
        pending = request
        reply(request, .received)
        switch request.action {
        case .sync: break
        case .bootShort:
            if WearableService.shared.isRecording, journal.draft != nil {
                let success = pauseDraft()
                VoiceConversationProbe.shared.endSystemConversationKeepingWatchDraft()
                confirmEnded(request, succeeded: success)
            } else if journal.draft != nil { start(request) }
            else { finish(request, succeeded: false, error: 5) }
        case .bootLong:
            if journal.draft != nil {
                finalize(ending: false) { [weak self] ok in
                    VoiceConversationProbe.shared.endSystemConversationKeepingWatchDraft()
                    self?.confirmEnded(request, succeeded: ok)
                }
            } else if WearableService.shared.isRecording { finish(request, succeeded: false, error: 4) }
            else { start(request) }
        case .end:
            finalize(ending: true) { [weak self] ok in
                guard let self = self else { return }
                if ok { VoiceConversationProbe.shared.end(); self.confirmEnded(request) }
                else {
                    // Keep recoverable segments, but release the system call even if saving failed.
                    VoiceConversationProbe.shared.endSystemConversationKeepingWatchDraft()
                    self.confirmEnded(request, succeeded: false)
                }
            }
        }
    }

    private func attachRecorder() {
        let service = WearableService.shared
        service.watchRecordingStarted = { [weak self] url in
            guard let self = self, self.journal.draft != nil else { return false }
            if let old = self.journal.draft?.current, old != url.lastPathComponent { self.journal.unverifiedFiles.append(old) }
            self.journal.draft?.current = url.lastPathComponent
            do { try self.save(); return true }
            catch { self.lastError = error.localizedDescription; return false }
        }
        service.watchStopRequested = { [weak self] send in
            guard let self = self else { return }
            if send {
                self.finalize(ending: false) { _ in
                    VoiceConversationProbe.shared.endSystemConversationKeepingWatchDraft()
                }
            } else {
                _ = self.pauseDraft()
                // Allow the interruption/stop callback to finish before ending its system call.
                DispatchQueue.main.async {
                    VoiceConversationProbe.shared.endSystemConversationKeepingWatchDraft()
                }
            }
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
            let session = journal.session!
            if journal.sessionDestinations?[session] == nil {
                var destination = UserDefaults.standard.dictionary(forKey: "shortcut_recording_destination") as? [String: String] ?? [:]
                destination.removeValue(forKey: "conversationId")
                if journal.sessionDestinations == nil { journal.sessionDestinations = [:] }
                if journal.sessionEndpoints == nil { journal.sessionEndpoints = [:] }
                journal.sessionDestinations?[session] = destination
                journal.sessionEndpoints?[session] = WearableService.shared.gatewayBaseURL
            }
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
                VoiceConversationProbe.shared.endSystemConversationKeepingWatchDraft()
                if self.journal.draft == nil || self.journal.draft?.segments.isEmpty == true {
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
        let current = journal.draft?.current
        if let (url, _) = WearableService.shared.sealWatchSegment() {
            if journal.draft?.segments.contains(url.lastPathComponent) == false { journal.draft?.segments.append(url.lastPathComponent) }
            journal.draft?.current = nil
        } else if let current = current {
            let url = recordings.appendingPathComponent(current)
            if let file = try? AVAudioFile(forReading: url), file.length > 0 {
                if journal.draft?.segments.contains(current) == false { journal.draft?.segments.append(current) }
            } else {
                if !journal.unverifiedFiles.contains(current) { journal.unverifiedFiles.append(current) }
                lastError = "当前段未通过校验，原文件保留；下一次可重新开始"
            }
            journal.draft?.current = nil
        }
        // An empty failed start isn't a paused message. Keeping it here would
        // make every later BOOT long press attempt to send an empty draft.
        if journal.draft?.segments.isEmpty == true { journal.draft = nil }
        do { try save(); log("已暂停；有效段数=\(journal.draft?.segments.count ?? 0)"); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    private func finalize(ending: Bool, completion: @escaping (Bool) -> Void) {
        guard !finalizing else {
            // A phone hang-up during AAC merge must still close the logical
            // context once that already-running save succeeds.
            if ending { endAfterFinalizing = true }
            completion(false); return
        }
        guard let draft = journal.draft else {
            let before = journal
            if ending { journal.session = nil }
            do { try save(); detachRecorder(); completion(true) }
            catch { journal = before; lastError = error.localizedDescription; completion(false) }
            return
        }
        guard pauseDraft() else { completion(false); return }
        guard let saved = journal.draft, !saved.segments.isEmpty else {
            if ending {
                journal.session = nil
                do { try save(); detachRecorder(); completion(true) }
                catch { lastError = error.localizedDescription; completion(false) }
            } else { completion(false) }
            return
        }
        finalizing = true
        VoiceConversationProbe.shared.pauseAndSend()
        let messageID = UUID().uuidString
        let output = recordings.appendingPathComponent("watch_message_\(messageID).m4a")
        let files = saved.segments.map { recordings.appendingPathComponent($0) }
        let endpoint = journal.sessionEndpoints?[saved.session] ?? WearableService.shared.gatewayBaseURL
        var destination = journal.sessionDestinations?[saved.session]
            ?? (UserDefaults.standard.dictionary(forKey: "shortcut_recording_destination") as? [String: String] ?? [:])
        destination.removeValue(forKey: "conversationId")
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
                    if ending || self.endAfterFinalizing { self.journal.session = nil }
                    do { try self.save() } catch { self.journal = before; throw error }
                    self.detachRecorder()
                    self.endAfterFinalizing = false
                    self.log("单条录音已持久保存 duration=\(duration)；等待服务器确认")
                    completion(true)
                    if let end = self.endAfterSaveRequest {
                        self.endAfterSaveRequest = nil
                        VoiceConversationProbe.shared.endSystemConversationKeepingWatchDraft()
                        self.confirmEnded(end)
                    }
                    self.flushDeliveries()
                } catch {
                    self.endAfterFinalizing = false
                    self.lastError = error.localizedDescription
                    self.log("合并失败，原始段已保留，结束操作尚未完成：\(error)")
                    completion(false)
                    if let end = self.endAfterSaveRequest {
                        self.endAfterSaveRequest = nil
                        self.finish(end, succeeded: false, error: 8)
                    }
                    self.drainPhoneEnd()
                }
            }
        }
    }

    private func confirmEnded(_ request: WatchRequest, succeeded: Bool = true) {
        if VoiceConversationProbe.shared.callUUID == nil, VoiceConversationProbe.shared.audioReleaseConfirmed {
            finish(request, succeeded: succeeded, error: succeeded ? 0 : 8); return
        }
        if request.expired() { finish(request, succeeded: false, error: 6); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.confirmEnded(request, succeeded: succeeded) }
    }

    private func finishUploadExecution() {
        uploading = false
        if uploadTask != .invalid { UIApplication.shared.endBackgroundTask(uploadTask); uploadTask = .invalid }
        retryWork?.cancel()
        if !journal.deliveries.isEmpty {
            let delays: [Double] = [2, 5, 10, 20, 40, 60]
            let delay = delays[min(retryAttempt, delays.count - 1)]
            retryAttempt += 1
            let work = DispatchWorkItem { [weak self] in self?.retryWork = nil; self?.flushDeliveries() }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
    private var nextDelivery: Delivery? {
        guard let index = WatchDeliveryOrder.nextIndex(journal.deliveries.map { (session: $0.session, state: $0.state) }) else { return nil }
        return journal.deliveries[index]
    }

    // Negotiate persistent server deduplication before enabling ambiguous POST retries.
    func flushDeliveries() {
        guard storageReady, !uploading, let delivery = nextDelivery else { return }
        guard delivery.endpoint == WearableService.shared.gatewayBaseURL else {
            lastError = "待发录音属于原网关，请切回原网关后发送"; return
        }
        guard
              let cookie = WearableService.shared.authCookie, !cookie.isEmpty,
              let probeURL = URL(string: delivery.endpoint + "/api/bootstrap") else {
            lastError = "录音已保存在待发箱，登录后自动继续发送"; return
        }
        retryWork?.cancel(); retryWork = nil
        uploading = true
        uploadTask = UIApplication.shared.beginBackgroundTask(withName: "Deliver saved watch voice") { [weak self] in
            guard let self = self else { return }
            if self.uploadTask != .invalid { UIApplication.shared.endBackgroundTask(self.uploadTask); self.uploadTask = .invalid }
        }
        var probe = URLRequest(url: probeURL); probe.timeoutInterval = 8
        probe.setValue(cookie, forHTTPHeaderField: "Cookie"); probe.setValue(delivery.endpoint, forHTTPHeaderField: "Origin")
        URLSession.shared.dataTask(with: probe) { _, response, error in
            DispatchQueue.main.async {
                guard error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    self.finishUploadExecution(); self.lastError = "录音已保存；网关暂不可达或需要登录"; return
                }
                self.checkUploadCapability(delivery, cookie: cookie)
            }
        }.resume()
    }
    private func checkUploadCapability(_ delivery: Delivery, cookie: String) {
        guard let url = URL(string: delivery.endpoint + "/api/wearable/voice-capabilities") else { finishUploadExecution(); return }
        var request = URLRequest(url: url); request.timeoutInterval = 8
        request.setValue(cookie, forHTTPHeaderField: "Cookie"); request.setValue(delivery.endpoint, forHTTPHeaderField: "Origin")
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let supported = error == nil && status == 200 && json?["idempotentUploads"] as? Bool == true && json?["version"] as? Int == 1
                if supported { self.upload(delivery, cookie: cookie, idempotent: true) }
                else if error == nil, [404, 501].contains(status), delivery.idempotent != true {
                    self.upload(delivery, cookie: cookie, idempotent: false)
                } else { self.finishUploadExecution(); self.lastError = "录音已保存；网关补传能力尚未确认" }
            }
        }.resume()
    }

    private func upload(_ delivery: Delivery, cookie: String, idempotent: Bool) {
        guard let index = journal.deliveries.firstIndex(where: { $0.id == delivery.id }),
              let url = URL(string: delivery.endpoint + "/api/shortcuts/voice") else { finishUploadExecution(); return }
        do {
            let audio = try Data(contentsOf: recordings.appendingPathComponent(delivery.file))
            var payload: [String: Any] = ["audioBase64": audio.base64EncodedString(), "filename": delivery.file,
                "mimeType": "audio/m4a", "prompt": "【手表语音指令】", "hostId": "ubuntu", "project": "ubuntu-antigravity", "cwd": "/home/complicated/project/voice-hub"]
            for (key, value) in delivery.destination { payload[key] = value }
            if let id = journal.conversations[delivery.session] { payload["conversationId"] = id }
            if idempotent { payload["logicalSessionId"] = delivery.session }
            let body = try JSONSerialization.data(withJSONObject: payload)
            journal.deliveries[index].state = "sending"
            journal.deliveries[index].idempotent = idempotent
            try save()
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(cookie, forHTTPHeaderField: "Cookie"); request.setValue(delivery.endpoint, forHTTPHeaderField: "Origin")
            if idempotent { request.setValue(delivery.id, forHTTPHeaderField: "Idempotency-Key") }
            URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    self.finishUploadExecution()
                    guard let index = self.journal.deliveries.firstIndex(where: { $0.id == delivery.id }) else { return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let receiptMatches = !idempotent || (json?["idempotentUpload"] as? Bool == true && json?["requestId"] as? String == delivery.id)
                    if error == nil, (200...299).contains(status), receiptMatches, json?["ok"] as? Bool == true,
                       let conversation = json?["conversationId"] as? String, !conversation.isEmpty,
                       let message = json?["messageId"] as? String, !message.isEmpty {
                        self.journal.conversations[delivery.session] = conversation
                        self.journal.deliveries.remove(at: index)
                        self.retryAttempt = 0
                        self.lastError = nil
                        self.log("服务器已接收 messageId=\(message) conversationId=\(conversation)")
                    } else if status == 409, json?["error"] as? String == "host_project_offline", let conversation = json?["conversationId"] as? String {
                        self.journal.conversations[delivery.session] = conversation
                        self.journal.deliveries[index].state = "pending"
                        self.lastError = "录音已保存；Agent 暂时离线"
                    } else if [400, 410, 413, 415, 422].contains(status) {
                        self.journal.deliveries[index].state = "needsReview"
                        self.lastError = "服务器拒绝上传 HTTP \(status)，录音文件已保留，需检查文件或原对话"
                    } else if idempotent, !["voice_result_uncertain", "voice_idempotency_conflict", "voice_session_deleted"].contains(json?["error"] as? String ?? ""),
                              !(status == 200 && !receiptMatches) {
                        self.journal.deliveries[index].state = "pending"
                        self.lastError = "录音已保存，等待网关恢复后以原消息编号补传"
                    } else {
                        self.journal.deliveries[index].state = "uncertain"
                        self.lastError = "上传结果未确认，文件已保留；暂停自动重发以避免重复消息"
                        self.log(self.lastError!)
                    }
                    do { try self.save() } catch { self.storageReady = false; self.log("保存发送结果失败：\(error)") }
                    if self.nextDelivery?.id != delivery.id { self.flushDeliveries() }
                }
            }.resume()
        } catch { finishUploadExecution(); storageReady = false; lastError = error.localizedDescription; log("发送准备失败，文件保留：\(error)") }
    }
    private enum WatchFailure: Error { case storage, audio }

    struct RecoveryItem {
        let id: String
        let state: String
        let url: URL
        let canVerify: Bool
    }
    var recoveryItems: [RecoveryItem] {
        var items = journal.deliveries.map {
            RecoveryItem(id: $0.id, state: $0.state, url: recordings.appendingPathComponent($0.file), canVerify: true)
        }
        items += journal.unverifiedFiles.map {
            RecoveryItem(id: $0, state: "unverified", url: recordings.appendingPathComponent($0), canVerify: false)
        }
        return items
    }
    func retryPendingDeliveries() { retryAttempt = 0; flushDeliveries() }
    func verifyDeliveryReceipt(_ id: String) {
        guard let delivery = journal.deliveries.first(where: { $0.id == id }),
              let cookie = WearableService.shared.authCookie, !cookie.isEmpty,
              let url = URL(string: delivery.endpoint + "/api/wearable/voice-receipts/" + id) else {
            lastError = "请先登录，再核对服务端回执"; return
        }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(delivery.endpoint, forHTTPHeaderField: "Origin")
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let receipt = json?["receipt"] as? [String: Any]
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      json?["state"] as? String == "complete", json?["requestId"] as? String == id,
                      receipt?["requestId"] as? String == id,
                      let conversation = receipt?["conversationId"] as? String,
                      let index = self.journal.deliveries.firstIndex(where: { $0.id == id && $0.state != "sending" }) else {
                    self.lastError = "尚无确定接收回执；原文件保留，可导出核对，不重复发送"
                    self.log(self.lastError!); return
                }
                self.journal.conversations[delivery.session] = conversation
                self.journal.deliveries.remove(at: index)
                do { try self.save(); self.lastError = nil; self.log("已核对服务器回执 requestId=\(id)"); self.flushDeliveries() }
                catch { self.storageReady = false; self.lastError = error.localizedDescription }
            }
        }.resume()
    }
}
