import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import AudioToolbox

public protocol WearableServiceDelegate: AnyObject {
    func wearableServiceDidChangeDeviceStatus(connected: Bool, deviceName: String, isListening: Bool, isRecording: Bool)
    func wearableServiceDidCaptureButton(name: String, appState: String)
    func wearableServiceDidFinishRecording(base64: String, mimeType: String, transcript: String, duration: TimeInterval)
    func wearableServiceDidFinishPlayback()
}

/// 统一事件派发器 (EventDispatcher)：解耦蓝牙按键源与录音执行逻辑
public final class WearableEventDispatcher {
    public static let shared = WearableEventDispatcher()

    private var lastEventTime: TimeInterval = 0

    public func dispatchButton(name: String) {
        let now = Date().timeIntervalSince1970
        // 防抖：350ms 内忽略硬件机械连击抖动
        if (now - lastEventTime) < 0.35 {
            print("[EventDispatcher] 忽略硬件防抖连击: \(name)")
            return
        }
        lastEventTime = now

        DispatchQueue.main.async {
            WearableService.shared.handleHardwareButtonPress(name: name)
        }
    }
}

/// 智能穿戴耳机后台中枢服务
/// 负责后台音频保活、蓝牙耳机实体键捕获、后台麦克风录音、原生直接发往网关以及自动回播打断
public final class WearableService: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {

    public static let shared = WearableService()

    public weak var delegate: WearableServiceDelegate?

    // 网关连接与鉴权（原生直连，零依赖 WebKit JS）
    public var gatewayBaseURL = "https://complicated.taildbe095.ts.net:8443"
    public var authCookie: String?
    public var currentConversationId: String?

    // 状态标志
    public private(set) var isListening = false
    public private(set) var isRecording = false
    public private(set) var isPlayingAudio = false
    public private(set) var currentDeviceName = "扬声器 / 听筒"
    public private(set) var isBluetoothConnected = false

    // 核心播放器与录音机
    private var silentPlayer: AVAudioPlayer?
    private var beepStartPlayer: AVAudioPlayer?
    private var beepEndPlayer: AVAudioPlayer?
    private var speechPlayer: AVAudioPlayer?
    private var audioRecorder: AVAudioRecorder?
    private var recordingStartTime: Date?
    private var tempAudioFileURL: URL?

    // 后台轮询任务与看门狗
    private var replyPollingTask: URLSessionDataTask?
    private var pollTimer: Timer?
    private var keepaliveWatchdogTimer: Timer?

    // 音量与视频录制物理按键监听 (支持相机快门/视频录制键)
    private var volumeObserver: NSKeyValueObservation?

    // 防抖与安全锁
    private var lastButtonTime: TimeInterval = 0

    // 触觉反馈
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)

    private override init() {
        super.init()
        feedbackGenerator.prepare()
        setupBeepPlayers()
        setupVolumeObserver()
        updateAudioRouteInfo()

        // 监听系统音频路由变更通知（蓝牙连接/断开）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        // 监听音频打断通知（系统电话打入或恢复）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        // 监听其他 App 音频开始/停止通知（如微信语音、音乐播放器）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSecondaryAudioHint),
            name: AVAudioSession.silenceSecondaryAudioHintNotification,
            object: nil
        )
    }

    // MARK: - 音频会话设置（基于 .mixWithOthers 的无缝混音与零抢占架构）
    // 1. 统一采用 .playAndRecord + .mixWithOthers：
    //    允许与微信语音、网易云音乐、播客等其他 App 完美混音共存，绝不打断或抢占其他 App 的播放！
    // 2. 待机状态下仅运行微弱静音保活，完全不开启麦克风硬件采集（0 麦克风占用）；
    // 3. 收到按键指令时瞬间启动录音，无需重新握手协商 Category，零延迟、无电流杂音；
    // 4. 录音完毕立即释放麦克风资源，回到待机混音状态。
    private func setupAudioSession(forRecording: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("[WearableService] 音频会话成功激活 (.playAndRecord + .mixWithOthers, forRecording=\(forRecording))")
        } catch {
            print("[WearableService] 音频会话配置失败: \(error)")
        }
    }

    @objc private func handleAudioRouteChange(notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateAudioRouteInfo()
            self.notifyStatusChanged()
            // 路由变更后保证静音保活持续
            if self.isListening || self.isRecording {
                self.ensureSilentPlayerRunning()
            }
        }
    }

    @objc private func handleAudioInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .began {
            print("[WearableService] 收到系统音频打断 (如普通电话呼入)，底噪暂停让路")
            silentPlayer?.pause()
        } else if type == .ended {
            print("[WearableService] 系统音频打断结束，自动重新激活音频会话并夺回按键焦点")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, self.isListening else { return }
                self.setupAudioSession(forRecording: self.isRecording)
                self.registerRemoteCommands()
                self.updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")
                self.ensureSilentPlayerRunning()
            }
        }
    }

    @objc private func handleSecondaryAudioHint(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeValue) else {
            return
        }

        if type == .begin {
            print("[WearableService] 其他 App 开始播放音频 (基于 mixWithOthers 和平混音，静音底噪不中断)")
        } else if type == .end {
            print("[WearableService] 其他 App 播放结束，自动重置耳机按键焦点与状态")
            if isListening && !isRecording && !isPlayingAudio {
                self.setupAudioSession(forRecording: false)
                self.registerRemoteCommands()
                self.updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")
                self.ensureSilentPlayerRunning()
            }
        }
    }

    private func updateAudioRouteInfo() {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        var connected = false
        var deviceName = "扬声器 / 听筒"

        for output in currentRoute.outputs {
            if output.portType == .bluetoothA2DP || output.portType == .bluetoothHFP || output.portType == .bluetoothLE {
                connected = true
                deviceName = output.portName
                break
            } else if output.portType == .headphones {
                connected = true
                deviceName = "有线耳机 (\(output.portName))"
                break
            }
        }

        self.isBluetoothConnected = connected
        self.currentDeviceName = deviceName
    }

    public func notifyStatusChanged() {
        delegate?.wearableServiceDidChangeDeviceStatus(
            connected: isBluetoothConnected,
            deviceName: currentDeviceName,
            isListening: isListening,
            isRecording: isRecording
        )
    }

    // MARK: - 保持静音底噪播放 (后台保活与实体按键捕获的生命线)
    private func ensureSilentPlayerRunning() {
        if silentPlayer == nil || !(silentPlayer?.isPlaying ?? false) {
            do {
                let silentData = generateSilentWAV()
                silentPlayer = try AVAudioPlayer(data: silentData)
                silentPlayer?.delegate = self
                silentPlayer?.numberOfLoops = -1
                silentPlayer?.volume = 0.01
                silentPlayer?.prepareToPlay()
                let ok = silentPlayer?.play() ?? false
                print("[WearableService] 静音保活播放器启动: \(ok)")
            } catch {
                print("[WearableService] 静音保活播放器启动失败: \(error)")
            }
        }
    }

    private func startKeepaliveWatchdog() {
        keepaliveWatchdogTimer?.invalidate()
        keepaliveWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isListening else { return }
            // 只要处于监听状态且不在播放 AI 朗读，若底噪未在运行，自动激活会话并夺回按键焦点
            if !self.isPlayingAudio && (self.silentPlayer == nil || !(self.silentPlayer?.isPlaying ?? false)) {
                print("[WearableService] 看门狗：检测到底噪停顿，自动重新激活会话并拉起保活")
                self.setupAudioSession(forRecording: self.isRecording)
                self.registerRemoteCommands()
                self.updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")
                self.ensureSilentPlayerRunning()
            }
        }
    }

    private func stopKeepaliveWatchdog() {
        keepaliveWatchdogTimer?.invalidate()
        keepaliveWatchdogTimer = nil
    }

    // MARK: - 监听启动与停止
    public func startListening() {
        guard !isListening else { return }
        setupAudioSession(forRecording: false)
        ensureSilentPlayerRunning()
        startKeepaliveWatchdog()

        registerRemoteCommands()
        updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")

        isListening = true
        notifyStatusChanged()
        print("[WearableService] 穿戴按键后台监听已启动 (已置为 .playAndRecord + .mixWithOthers)")
    }

    public func stopListening() {
        guard isListening else { return }

        if isRecording {
            stopRecording(shouldProcess: false)
        }
        stopAudioPlayback()
        stopPolling()
        stopKeepaliveWatchdog()

        silentPlayer?.stop()
        silentPlayer = nil
        unregisterRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        isListening = false
        notifyStatusChanged()
        print("[WearableService] 穿戴按键后台监听已停止")
    }

    // MARK: - 远程按键注册 (MPRemoteCommandCenter)
    private func registerRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // 注册前先清空旧 Target，杜绝 Target 堆叠累加导致的失效
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)

        // 1. 耳机单击（播放/暂停切换）
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            WearableEventDispatcher.shared.dispatchButton(name: "togglePlayPause")
            return .success
        }

        // 2. 播放按键
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            WearableEventDispatcher.shared.dispatchButton(name: "play")
            return .success
        }

        // 3. 暂停按键
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            WearableEventDispatcher.shared.dispatchButton(name: "pause")
            return .success
        }

        // 4. 停止按键
        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { _ in
            WearableEventDispatcher.shared.dispatchButton(name: "stop")
            return .success
        }

        // 5. 耳机双击（下一首）
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { _ in
            WearableEventDispatcher.shared.dispatchButton(name: "nextTrack")
            return .success
        }

        // 6. 耳机三击（上一首）
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { _ in
            WearableEventDispatcher.shared.dispatchButton(name: "previousTrack")
            return .success
        }

        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func unregisterRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        UIApplication.shared.endReceivingRemoteControlEvents()
    }

    private func updateNowPlayingInfo(statusText: String) {
        let infoCenter = MPNowPlayingInfoCenter.default()
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = "Agent Relay"
        info[MPMediaItemPropertyArtist] = statusText
        info[MPMediaItemPropertyAlbumTitle] = currentDeviceName
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 1.0
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = .playing
    }

    // MARK: - 实体按键核心流转：按一下开始录音，再按一下立刻发出音频
    public func handleHardwareButtonPress(name: String) {
        let now = Date().timeIntervalSince1970
        // 防抖：400ms 内忽略硬件连击抖动
        if (now - lastButtonTime) < 0.40 {
            print("[WearableService] 忽略防抖连击: \(name)")
            return
        }
        lastButtonTime = now

        let stateStr = (UIApplication.shared.applicationState == .background) ? "background" : "foreground"

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            print("[WearableService] 捕获按键: \(name), isRecording=\(self.isRecording), isPlaying=\(self.isPlayingAudio)")
            self.delegate?.wearableServiceDidCaptureButton(name: name, appState: stateStr)

            // 1. 如果正在播报 AI 语音 -> 瞬间打断 (Barge-in)
            if self.isPlayingAudio {
                self.triggerFeedbackHaptic()
                self.stopAudioPlayback()
                self.updateNowPlayingInfo(statusText: "⏸ 播报已打断")
                return
            }

            // 2. 如果正在录音中 -> 再次按键：立即停止录音并发送给 Agent！
            if self.isRecording {
                let duration = Date().timeIntervalSince(self.recordingStartTime ?? Date())
                // 核心防抖安全锁：录音启动 0.8 秒内绝对禁止立刻停止，杜绝按键物理弹跳/蓝牙双包导致瞬间一闪而过！
                if duration < 0.8 {
                    print("[WearableService] 录音启动仅 \(String(format: "%.2f", duration))s，忽略连击抖动")
                    return
                }
                self.stopRecording(shouldProcess: true)
                return
            }

            // 3. 首次按键：开启录音
            if !self.isListening {
                self.startListening()
            }
            self.startRecording()
        }
    }

    // MARK: - 原生麦克风录音控制
    public func startRecording() {
        guard !isRecording else { return }

        // 停止之前的播放与旧的轮询
        stopAudioPlayback()
        stopPolling()

        // 触感反馈 + 清脆高音提示音
        triggerFeedbackHaptic()
        playBeepStart()

        // 开启麦克风录音会话模式
        setupAudioSession(forRecording: true)

        let tempDir = NSTemporaryDirectory()
        let fileName = "wearable_voice_\(Int(Date().timeIntervalSince1970)).m4a"
        let fileURL = URL(fileURLWithPath: tempDir).appendingPathComponent(fileName)
        self.tempAudioFileURL = fileURL

        // 标准 AAC 录音配置
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            let recordOk = recorder.record()
            self.audioRecorder = recorder
            self.isRecording = true
            self.recordingStartTime = Date()

            // 保持静音底噪保活
            ensureSilentPlayerRunning()

            updateNowPlayingInfo(statusText: "🔴 正在录音... (单击按键结束并发送)")
            notifyStatusChanged()
            print("[WearableService] 录音已开始: \(fileURL.path), recordOk=\(recordOk)")
        } catch {
            print("[WearableService] 创建 AVAudioRecorder 失败: \(error)")
            setupAudioSession(forRecording: false)
        }
    }

    public func stopRecording(shouldProcess: Bool = true) {
        guard isRecording else { return }

        // 立即触发确认结束音与震动
        playBeepEnd()
        triggerFeedbackHaptic()

        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        notifyStatusChanged()

        // 关键切回：录音结束后立刻切回 .playback，让蓝牙耳机回归 A2DP，保证下一次按键 100% 捕获！
        setupAudioSession(forRecording: false)
        ensureSilentPlayerRunning()

        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        updateNowPlayingInfo(statusText: "🟡 正在发送给 Agent...")

        guard shouldProcess, let fileURL = tempAudioFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        // 读取音频文件
        guard let audioData = try? Data(contentsOf: fileURL), !audioData.isEmpty else {
            print("[WearableService] 录音数据为空，跳过提交")
            return
        }
        let base64String = audioData.base64EncodedString()
        print("[WearableService] 录音完成: \(audioData.count) 字节, 时长: \(String(format: "%.1f", duration))s")

        // 核心突破点：原生 Swift 直接通过 URLSession 后台上传给网关，绝对不受 WebKit 挂起影响！
        self.sendAudioToGatewayNative(audioBase64: base64String, duration: duration)

        // 同时派发给 Web 前台（如果在前台可以同步显示，不传 base64 防前端重复提交）
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.wearableServiceDidFinishRecording(
                base64: "",
                mimeType: "audio/m4a",
                transcript: "【耳机语音指令】",
                duration: duration
            )
        }
    }

    // MARK: - 音量/视频录制快门物理按键监听 (支持大疆与蓝牙遥控快门键)
    private func setupVolumeObserver() {
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.old, .new]) { _, change in
            guard let oldVal = change.oldValue, let newVal = change.newValue, abs(oldVal - newVal) > 0.001 else { return }
            print("[WearableService] 捕获到音量/视频快门按键变更: \(oldVal) -> \(newVal)")
            WearableEventDispatcher.shared.dispatchButton(name: "videoOrVolumeShutter")
        }
    }

    // MARK: - 原生后台 HTTP 发送（100% 保证黑屏放口袋也能发出）
    private func sendAudioToGatewayNative(audioBase64: String, duration: TimeInterval) {
        guard let url = URL(string: "\(gatewayBaseURL)/api/shortcuts/voice") else {
            print("[WearableService] 无效的网关 URL: \(gatewayBaseURL)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(gatewayBaseURL, forHTTPHeaderField: "Origin")
        request.setValue("AgentRelay-Wearable/1.0 (iOS Native)", forHTTPHeaderField: "User-Agent")

        // 注入当前登录 Cookie
        if let cookie = authCookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        // 每次录音均为全新独立会话，默认工作目录定向至 voice-hub 语音中枢
        let payload: [String: Any] = [
            "audioBase64": audioBase64,
            "filename": "wearable_voice_\(Int(Date().timeIntervalSince1970)).m4a",
            "mimeType": "audio/m4a",
            "prompt": "【耳机语音指令】",
            "hostId": "ubuntu",
            "project": "ubuntu-antigravity",
            "cwd": "/home/complicated/project/voice-hub"
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("[WearableService] 无法序列化语音上传请求体")
            return
        }
        request.httpBody = bodyData

        print("[WearableService] 原生后台发送语音到: \(url.absoluteString)...")
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("[WearableService] 语音上传网络失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.updateNowPlayingInfo(statusText: "❌ 发送失败，请检查网络")
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode), let data = data else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[WearableService] 语音上传 HTTP 错误: \(code)")
                DispatchQueue.main.async {
                    self.updateNowPlayingInfo(statusText: "❌ 服务器返回 \(code)")
                }
                return
            }

            print("[WearableService] 语音已成功送达网关！")
            // 播放轻快上升音：提示已发送成功
            self.playBeepStart()

            // 解析返回的全新 conversationId 用于轮询该会话的 Agent 回复，轮询完毕朗读到耳机
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let convId = json["conversationId"] as? String {
                DispatchQueue.main.async {
                    self.updateNowPlayingInfo(statusText: "🟡 已发送，Agent 正在思考...")
                    self.startPollingAgentReply(conversationId: convId)
                }
            }
        }
        task.resume()
    }

    // MARK: - 后台轮询 Agent 回复并自动推送到耳机朗读
    private func startPollingAgentReply(conversationId: String) {
        stopPolling()
        var pollCount = 0
        let maxPolls = 40 // 最多等待约 60 秒

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            pollCount += 1
            if pollCount > maxPolls {
                timer.invalidate()
                print("[WearableService] 等待 Agent 回复超时")
                self.updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")
                return
            }

            guard let url = URL(string: "\(self.gatewayBaseURL)/api/conversations/\(conversationId)/messages") else {
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let cookie = self.authCookie {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }

            self.replyPollingTask = URLSession.shared.dataTask(with: request) { data, response, error in
                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let messages = json["messages"] as? [[String: Any]] else {
                    return
                }

                // 寻找最新的助手回复
                if let lastAssistant = messages.last(where: { ($0["role"] as? String) == "agent" || ($0["role"] as? String) == "assistant" }),
                   let content = lastAssistant["content"] as? String, !content.isEmpty {
                    let isStreaming = (lastAssistant["streaming"] as? Bool) ?? false
                    if !isStreaming {
                        // 发现已完成的回复！停止轮询并立即请求合成语音
                        DispatchQueue.main.async {
                            timer.invalidate()
                            self.fetchTTSAndPlay(text: content)
                        }
                    }
                }
            }
            self.replyPollingTask?.resume()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        replyPollingTask?.cancel()
        replyPollingTask = nil
    }

    // MARK: - 请求 Edge-TTS 并播报到蓝牙耳机
    private func fetchTTSAndPlay(text: String) {
        guard let url = URL(string: "\(gatewayBaseURL)/api/tts") else { return }

        // 清洗文本中的 markdown 格式
        let cleanText = cleanMarkdownForSpeech(text: text)
        guard !cleanText.isEmpty else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(gatewayBaseURL, forHTTPHeaderField: "Origin")
        if let cookie = authCookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let payload: [String: Any] = [
            "text": cleanText,
            "voice": "zh-CN-XiaoxiaoNeural"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        updateNowPlayingInfo(statusText: "🔊 正在合成语音并推送到耳机...")
        print("[WearableService] 正在请求 Edge-TTS: \(cleanText.prefix(20))...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil,
                  let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                print("[WearableService] TTS 合成失败")
                return
            }

            DispatchQueue.main.async {
                self.playAudioStreamData(data: data)
            }
        }.resume()
    }

    private func cleanMarkdownForSpeech(text: String) -> String {
        var clean = text
        clean = clean.replacingOccurrences(of: "```[\\w-]*\\n[\\s\\S]*?```", with: "，代码块已省略，", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "`[^`]+`", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]+\\)", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "[\\*\\_\\~]", with: "", options: .regularExpression)
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 语音流播放
    private func playAudioStreamData(data: Data) {
        stopAudioPlayback()

        do {
            speechPlayer = try AVAudioPlayer(data: data)
            speechPlayer?.delegate = self
            speechPlayer?.prepareToPlay()
            speechPlayer?.play()
            isPlayingAudio = true
            updateNowPlayingInfo(statusText: "🔊 正在播报 AI 回复 (按键可打断)")
            print("[WearableService] 正在向蓝牙耳机播报语音")
        } catch {
            print("[WearableService] 播放语音失败: \(error)")
            isPlayingAudio = false
        }
    }

    public func playAudioStream(urlString: String?, base64Data: String?) {
        var audioData: Data?
        if let base64 = base64Data, !base64.isEmpty {
            var clean = base64
            if let comma = clean.range(of: ";base64,") {
                clean = String(clean[comma.upperBound...])
            }
            audioData = Data(base64Encoded: clean)
        } else if let urlStr = urlString, let url = URL(string: urlStr) {
            audioData = try? Data(contentsOf: url)
        }
        if let data = audioData {
            playAudioStreamData(data: data)
        }
    }

    public func stopAudioPlayback() {
        if isPlayingAudio || speechPlayer != nil {
            speechPlayer?.stop()
            speechPlayer = nil
            isPlayingAudio = false
            updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")
            delegate?.wearableServiceDidFinishPlayback()
            print("[WearableService] 语音播报已停止")
        }
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player == silentPlayer {
            if isListening || isRecording {
                silentPlayer?.play()
            }
        } else if player == speechPlayer {
            isPlayingAudio = false
            speechPlayer = nil
            updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")
            delegate?.wearableServiceDidFinishPlayback()
            print("[WearableService] 语音播报完毕")
        }
    }

    // MARK: - 声学与触感反馈辅助
    public func triggerFeedbackHaptic() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        feedbackGenerator.impactOccurred()
    }

    public func playBeepStart() {
        beepStartPlayer?.currentTime = 0
        beepStartPlayer?.play()
        AudioServicesPlaySystemSound(1057)
    }

    public func playBeepEnd() {
        beepEndPlayer?.currentTime = 0
        beepEndPlayer?.play()
        AudioServicesPlaySystemSound(1054)
    }

    private func setupBeepPlayers() {
        beepStartPlayer = createTonePlayer(frequency: 880.0, duration: 0.12)
        beepEndPlayer = createTonePlayer(frequency: 660.0, duration: 0.15)
    }

    private func createTonePlayer(frequency: Double, duration: Double) -> AVAudioPlayer? {
        let sampleRate: Double = 44100
        let totalSamples = Int(sampleRate * duration)

        var audioData = Data()
        let byteRate = Int32(sampleRate * 2)
        let blockAlign: Int16 = 2
        let dataSize = Int32(totalSamples * 2)
        let chunkSize = 36 + dataSize

        audioData.append(contentsOf: [UInt8]("RIFF".utf8))
        audioData.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        audioData.append(contentsOf: [UInt8]("WAVE".utf8))
        audioData.append(contentsOf: [UInt8]("fmt ".utf8))
        let sub1: Int32 = 16
        audioData.append(contentsOf: withUnsafeBytes(of: sub1.littleEndian) { Array($0) })
        let fmt: Int16 = 1
        audioData.append(contentsOf: withUnsafeBytes(of: fmt.littleEndian) { Array($0) })
        let ch: Int16 = 1
        audioData.append(contentsOf: withUnsafeBytes(of: ch.littleEndian) { Array($0) })
        let sr = Int32(sampleRate)
        audioData.append(contentsOf: withUnsafeBytes(of: sr.littleEndian) { Array($0) })
        audioData.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        audioData.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        let bits: Int16 = 16
        audioData.append(contentsOf: withUnsafeBytes(of: bits.littleEndian) { Array($0) })
        audioData.append(contentsOf: [UInt8]("data".utf8))
        audioData.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        for i in 0..<totalSamples {
            let t = Double(i) / sampleRate
            let angle = 2.0 * Double.pi * frequency * t
            let envelope = sin(Double.pi * (Double(i) / Double(totalSamples)))
            let sampleVal = Int16(sin(angle) * envelope * 28000)
            audioData.append(contentsOf: withUnsafeBytes(of: sampleVal.littleEndian) { Array($0) })
        }

        let player = try? AVAudioPlayer(data: audioData)
        player?.prepareToPlay()
        return player
    }

    private func generateSilentWAV() -> Data {
        let sampleRate: Int32 = 8000
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate: Int32 = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign: Int16 = channels * (bitsPerSample / 8)
        let durationSeconds = 1
        let dataSize: Int32 = sampleRate * Int32(durationSeconds) * Int32(blockAlign)
        let chunkSize: Int32 = 36 + dataSize

        var data = Data()
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: [UInt8]("WAVE".utf8))
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        let subchunk1Size: Int32 = 16
        data.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian) { Array($0) })
        let pcmFormat: Int16 = 1
        data.append(contentsOf: withUnsafeBytes(of: pcmFormat.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: [UInt8]("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
