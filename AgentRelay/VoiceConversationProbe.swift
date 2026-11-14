import UIKit
import AVFoundation
import LiveCommunicationKit

// 独立实机验证入口，只从现有“设备测试”页面进入。
// 服务端仍为用户自己的 Agent Relay；不注册虚构电话或自动来电。
@available(iOS 17.4, *)
final class VoiceConversationProbe: NSObject, ConversationManagerDelegate, AVAudioPlayerDelegate {
    static let shared = VoiceConversationProbe()
    private var manager: ConversationManager!
    private(set) var callUUID: UUID?
    private(set) var audioActive = false
    private(set) var paused = false
    private(set) var status = "尚未连接"
    private var opening = false
    private var wantsRecording = false
    private var playbackData: Data?
    private var player: AVAudioPlayer?
    private var delayedResume: DispatchWorkItem?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var recordingWasConfirmed = false
    private var confirmedTimer: Timer?
    private var generation = UUID()

    private override init() {
        super.init()
        configureManager()
    }

    private func configureManager() {
        let config = ConversationManager.Configuration(
            ringtoneName: nil, iconTemplateImageData: nil,
            maximumConversationGroups: 1, maximumConversationsPerConversationGroup: 1,
            includesConversationInRecents: false, supportsVideo: false,
            supportedHandleTypes: [.generic])
        manager = ConversationManager(configuration: config)
        manager.delegate = self
    }

    private func log(_ text: String) {
        status = text
        DeviceDiagnostics.shared.log("LCK \(text) state=\(UIApplication.shared.applicationState.rawValue)")
    }

    func connect() {
        guard !opening, callUUID == nil else { return }
        let service = WearableService.shared
        guard !service.isRecording else { log("请先结束当前录音"); return }
        let audio = AVAudioSession.sharedInstance()
        guard audio.recordPermission == .granted else {
            audio.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted { self.connect() }
                    else { self.log("需要麦克风权限") }
                }
            }
            return
        }
        guard let cookie = service.authCookie, !cookie.isEmpty else {
            log("请先在 Agent Relay 中登录，再进入测试")
            return
        }
        service.stopListening()
        opening = true
        generation = UUID()
        let attempt = generation
        log("正在连接自己的 Agent Relay 语音会话")
        Task { @MainActor in
            do {
                guard let url = URL(string: "\(service.gatewayBaseURL)/api/conversations") else {
                    throw ProbeError.invalidEndpoint
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 20
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(service.gatewayBaseURL, forHTTPHeaderField: "Origin")
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "hostId": "ubuntu", "project": "ubuntu-antigravity",
                    "cwd": "/home/complicated/project/voice-hub", "title": "Agent Relay 语音会话测试"
                ])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard attempt == self.generation else { return }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let conversationId = json["id"] as? String else {
                    throw ProbeError.gateway((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                // 先配置类别，不自行激活。等待系统 didActivate 后才采音。
                try audio.setCategory(.playAndRecord, mode: .voiceChat,
                    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
                service.enterCommunicationMode(conversationId: conversationId)
                service.communicationButtonHandler = { [weak self] name in
                    self?.handleMediaButton(name)
                }
                service.communicationPlaybackHandler = { [weak self] data in
                    DispatchQueue.main.async { self?.receiveReply(data) }
                }
                let uuid = UUID()
                self.callUUID = uuid
                self.wantsRecording = true
                self.log("服务端会话已建立，等待系统允许采音")
                let action = StartConversationAction(conversationUUID: uuid,
                    handles: [Handle(type: .generic, value: "agent-relay", displayName: "Agent Relay")],
                    isVideo: false)
                try await self.manager.perform([action])
                self.opening = false
            } catch {
                guard attempt == self.generation else { return }
                self.log("建立失败：\(error.localizedDescription)")
                self.opening = false
                self.manager.invalidate()
                self.cleanup()
                self.configureManager()
            }
        }
    }

    func pauseAndSend() {
        guard callUUID != nil else { return }
        wantsRecording = false
        if WearableService.shared.isRecording { WearableService.shared.stopRecording() }
        player?.stop()
        player = nil
        playbackData = nil
        WearableService.shared.refreshCommunicationMediaState(active: false)
        setPaused(true)
    }

    private var lastMediaButton = Date.distantPast
    func handleDedicatedButton() {
        guard callUUID != nil else {
            log("收到 BLE 按钮，但语音会话未建立；请先在前台建立会话")
            return
        }
        handleMediaButton("BLE-GATT")
    }
    private func handleMediaButton(_ name: String) {
        guard callUUID != nil else { return }
        guard Date().timeIntervalSince(lastMediaButton) >= 0.7 else { return }
        lastMediaButton = Date()
        log("收到媒体键 \(name) recording=\(WearableService.shared.isRecording)")
        if WearableService.shared.isRecording {
            guard WearableService.shared.capturedRecordingDuration >= 0.7 else { return }
            pauseAndSend()
        } else if name != "stop" {
            resumeRecording()
        }
    }

    func resumeRecording() {
        guard callUUID != nil else { log("请先建立语音会话"); return }
        guard !WearableService.shared.isRecording else { return }
        wantsRecording = true
        player?.stop()
        player = nil
        playbackData = nil
        if audioActive { beginRecordingIfNeeded() }
        else { setPaused(false) }
    }

    func scheduleResume() {
        guard callUUID != nil, paused, !audioActive else {
            log("先暂停并确认麦克风释放，再测试后台恢复")
            return
        }
        cancelScheduledResume()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Voice resume test") { [weak self] in
            self?.cancelScheduledResume()
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.callUUID != nil else { return }
            self.delayedResume = nil
            self.log("执行用户安排的恢复请求；此测试不代表蓝牙唤醒")
            self.resumeRecording()
        }
        delayedResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        log("10 秒后恢复采音，请现在锁屏；仅验证后台音频恢复")
    }

    private func setPaused(_ value: Bool) {
        guard let uuid = callUUID else { return }
        let attempt = generation
        Task { @MainActor in
            do {
                try await manager.perform([PauseConversationAction(conversationUUID: uuid, isPaused: value)])
            } catch {
                guard attempt == self.generation else { return }
                self.log("暂停/恢复请求失败：\(error.localizedDescription)")
                self.finishBackgroundTask()
            }
        }
    }

    func end() {
        generation = UUID()
        cancelScheduledResume()
        guard let uuid = callUUID else { opening = false; return }
        Task { @MainActor in
            do { try await manager.perform([EndConversationAction(conversationUUID: uuid)]) }
            catch {
                self.log("结束请求失败：\(error.localizedDescription)")
                self.manager.invalidate()
                self.cleanup()
                self.configureManager()
            }
        }
    }

    private func beginRecordingIfNeeded() {
        guard wantsRecording, audioActive, callUUID != nil else { return }
        wantsRecording = false
        WearableService.shared.startRecording()
        guard WearableService.shared.isRecording else {
            log("系统已激活，但录音启动失败")
            setPaused(true)
            return
        }
        log("开始采音 input=\(WearableService.shared.recordingInputName)")
        WearableService.shared.refreshCommunicationMediaState(active: true)
        recordingWasConfirmed = false
        confirmedTimer?.invalidate()
        confirmedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let service = WearableService.shared
            if !service.isRecording {
                timer.invalidate()
                self.log("采音已停止；详情见录音诊断")
                if self.audioActive { self.setPaused(true) }
            } else if !self.recordingWasConfirmed && service.capturedRecordingDuration >= 1 {
                self.recordingWasConfirmed = true
                self.log("采音帧持续增长 input=\(service.recordingInputName)")
            }
        }
    }

    private func receiveReply(_ data: Data) {
        guard callUUID != nil else { return }
        // 用户正在讲话时不切换到播报，避免打断录音。
        guard !WearableService.shared.isRecording, !wantsRecording else {
            log("收到回复，本轮正在讲话，跳过自动播报")
            return
        }
        playbackData = data
        if audioActive { playPendingReply() }
        else { setPaused(false) }
    }

    private func playPendingReply() {
        guard let data = playbackData, audioActive else { return }
        playbackData = nil
        do {
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            guard player?.play() == true else { throw ProbeError.playback }
            WearableService.shared.refreshCommunicationMediaState(active: true)
            log("正在播放 Agent 回复")
        } catch {
            log("播报失败：\(error.localizedDescription)")
            setPaused(true)
        }
    }

    private func finishBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func cancelScheduledResume() {
        delayedResume?.cancel()
        delayedResume = nil
        finishBackgroundTask()
    }

    private func cleanup() {
        generation = UUID()
        opening = false
        callUUID = nil
        audioActive = false
        paused = false
        wantsRecording = false
        cancelScheduledResume()
        confirmedTimer?.invalidate()
        confirmedTimer = nil
        player?.stop()
        player = nil
        playbackData = nil
        WearableService.shared.leaveCommunicationMode()
    }

    func conversationManagerDidBegin(_ manager: ConversationManager) {
        DeviceDiagnostics.shared.log("LCK manager began")
    }

    func conversationManagerDidReset(_ manager: ConversationManager) {
        DispatchQueue.main.async {
            guard manager === self.manager else { return }
            self.cleanup()
            self.log("系统已重置语音会话")
        }
    }

    func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {}

    func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
        DispatchQueue.main.async {
            guard manager === self.manager else { action.fail(); return }
            switch action {
            case is StartConversationAction:
                action.fulfill()
                if let conversation = manager.conversations.first(where: { $0.uuid == self.callUUID }) {
                    manager.reportConversationEvent(.conversationConnected(Date()), for: conversation)
                }
            case let pause as PauseConversationAction:
                self.paused = pause.isPaused
                if pause.isPaused {
                    // 系统中断不作为“用户发送”处理。
                    if WearableService.shared.isRecording { WearableService.shared.stopRecording(shouldProcess: false) }
                    self.player?.stop()
                    self.player = nil
                }
                action.fulfill()
            case is EndConversationAction:
                self.cleanup()
                action.fulfill()
                self.log("语音会话已结束")
            default:
                action.fulfill()
            }
        }
    }

    func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
        DispatchQueue.main.async { self.log("系统动作超时"); self.finishBackgroundTask() }
        action.fail()
    }

    func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {
        DispatchQueue.main.async {
            guard manager === self.manager, self.callUUID != nil else { return }
            self.audioActive = true
            self.paused = false
            WearableService.shared.communicationAudioDidActivate()
            self.log("系统已启用音频会话")
            self.beginRecordingIfNeeded()
            self.playPendingReply()
            self.finishBackgroundTask()
        }
    }

    func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {
        DispatchQueue.main.async {
            guard manager === self.manager else { return }
            self.audioActive = false
            WearableService.shared.refreshCommunicationMediaState(active: false)
            if WearableService.shared.isRecording { WearableService.shared.stopRecording(shouldProcess: false) }
            self.log("系统已停用音频会话；待验证其他 App 能否正常用麦")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        setPaused(true)
    }

    private enum ProbeError: LocalizedError {
        case invalidEndpoint, gateway(Int), playback
        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "服务器地址无效"
            case .gateway(let code): return "Agent Relay HTTP \(code)，请检查登录和连接"
            case .playback: return "无法启动回复音频"
            }
        }
    }
}

@available(iOS 17.4, *)
final class VoiceConversationProbeController: UIViewController {
    private let label = UILabel()
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "语音会话验证"
        view.backgroundColor = .systemBackground
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
        let help = UILabel()
        help.numberOfLines = 0
        help.text = "电脑 GATT 测试：先在设备测试页连接「Agent Relay 电脑按钮」，再建立语音会话。电脑按钮在录音时停止并发送，暂停时恢复录音。分别测锁屏、其他播放器使用后、音乐播放中。蓝牙事件不经过媒体键，但采音仍可能打断音乐。此版本不恢复强退后的语音会话。"
        help.font = .systemFont(ofSize: 14)
        let stack = UIStackView(arrangedSubviews: [help, label])
        stack.axis = .vertical
        stack.spacing = 14
        let titles = ["建立语音会话并录音", "暂停并发送本轮", "继续录音", "10 秒后恢复录音（请锁屏）", "结束语音会话", "复制诊断日志"]
        let actions: [Selector] = [#selector(connect), #selector(pause), #selector(resume), #selector(delayed), #selector(end), #selector(copyLog)]
        for (title, action) in zip(titles, actions) {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.addTarget(self, action: action, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let probe = VoiceConversationProbe.shared
        let service = WearableService.shared
        label.text = "\(probe.status)\n系统音频：\(probe.audioActive ? "已启用" : "已停用")\n采集时长：\(String(format: "%.1f", service.capturedRecordingDuration)) 秒\n输入：\(service.recordingInputName)"
    }
    @objc private func connect() { VoiceConversationProbe.shared.connect() }
    @objc private func pause() { VoiceConversationProbe.shared.pauseAndSend() }
    @objc private func resume() { VoiceConversationProbe.shared.resumeRecording() }
    @objc private func delayed() { VoiceConversationProbe.shared.scheduleResume() }
    @objc private func end() { VoiceConversationProbe.shared.end() }
    @objc private func copyLog() { UIPasteboard.general.string = DeviceDiagnostics.shared.text }
    deinit { timer?.invalidate() }
}
