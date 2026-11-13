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
    public var authCookie: String? {
        get {
            return UserDefaults.standard.string(forKey: "wearable_auth_cookie")
        }
        set {
            if let val = newValue, !val.isEmpty {
                UserDefaults.standard.set(val, forKey: "wearable_auth_cookie")
            }
        }
    }
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
    private var maxDurationTimer: Timer?
    private var recordingHealthTimer: Timer?
    private var lastCapturedTime: TimeInterval = 0
    private var lastCaptureProgressAt: TimeInterval = 0
    private var wasOtherAudioPlaying = false
    private var isSystemInterrupted = false
    private var interruptedDate: Date?

    // 防抖与安全锁
    private var lastButtonTime: TimeInterval = 0

    // 触觉反馈
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)

    private override init() {
        super.init()
        feedbackGenerator.prepare()
        setupBeepPlayers()
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

    // MARK: - 音频会话设置 (纯 A2DP 协议，严禁 HFP 通话模式)
    // 待机状态使用 .playback 专属模式（A2DP 纯播放），这是 iOS 系统分发 MPRemoteCommandCenter 耳机实体按键的绝对必要前提！
    // 录音状态使用 .playAndRecord（严禁使用 .allowBluetooth，保证蓝牙耳机保持在 A2DP 纯音乐协议，杜绝切入 HFP 通话模式）
    @discardableResult
    private func setupAudioSession(forRecording: Bool) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            if forRecording {
                // 纯 A2DP 高清录音：绝对不加 .allowBluetooth，彻底杜绝耳机切入 HFP 通话/打电话模式！
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.allowBluetoothA2DP, .defaultToSpeaker]
                )
                try session.setActive(true)
            } else {
                // 纯 A2DP 待命模式：接收 MPRemoteCommandCenter 耳机实体按键
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.allowBluetoothA2DP]
                )
                try session.setActive(true)
            }
            print("[WearableService] 音频会话配置成功 (forRecording=\(forRecording), 纯 A2DP 协议，无 HFP 通话)")
            return true
        } catch {
            print("[WearableService] 音频会话配置失败 (forRecording=\(forRecording)): \(error)")
            return false
        }
    }

    @objc private func handleAudioRouteChange(notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateAudioRouteInfo()
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            DeviceDiagnostics.shared.log("Audio route reason=\(reason) input=\(AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.portName }) recording=\(self.isRecording)")
            self.notifyStatusChanged()
            // 核心修复：路由变更绝不可盲目重启播放器，杜绝微信点开麦克风时被静音播放器顶掉的问题！
        }
    }

    @objc private func handleAudioInterruption(notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handleAudioInterruption(notification: notification) }
            return
        }
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .began {
            DeviceDiagnostics.shared.log("Audio interruption began recording=\(isRecording) captured=\(audioRecorder?.currentTime ?? 0)")
            print("[WearableService] 收到系统音频打断 (如微信录音、系统来电)，彻底让路，绝不强占麦克风")
            isSystemInterrupted = true
            interruptedDate = Date()
            wasOtherAudioPlaying = true
            silentPlayer?.stop()
            silentPlayer = nil
            if isRecording {
                failActiveRecording(message: "录音被系统中断，未发送，请重新录音")
            }
        } else if type == .ended {
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            DeviceDiagnostics.shared.log("Audio interruption ended shouldResume=\(shouldResume)")
            print("[WearableService] 系统音频打断结束，解除打断并恢复耳机待命焦点")
            isSystemInterrupted = false
            interruptedDate = nil
            wasOtherAudioPlaying = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, shouldResume, self.isListening, !self.isRecording else { return }
                self.reactivateStandby()
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
            print("[WearableService] 其他 App 开始发声或占用麦克风 (标记让路)")
            wasOtherAudioPlaying = true
            silentPlayer?.stop()
            silentPlayer = nil
        } else if type == .end {
            print("[WearableService] 其他 App 停止发声或释放麦克风，自动重置耳机按键焦点")
            wasOtherAudioPlaying = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.isListening, !self.isRecording, !self.isPlayingAudio, !self.isSystemInterrupted else { return }
                self.reactivateStandby()
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
        // 关键守卫：录音、播报、或系统被微信/电话打断期间，绝不运行静音底噪播放器
        guard !isRecording && !isPlayingAudio && !isSystemInterrupted else { return }
        let session = AVAudioSession.sharedInstance()
        if session.secondaryAudioShouldBeSilencedHint || session.isOtherAudioPlaying {
            print("[WearableService] 检测到外部音频使用中 (如微信录音或音乐播放)，静音播放器礼貌让路")
            return
        }
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
            guard let self = self, self.isListening, !self.isRecording, !self.isPlayingAudio else { return }

            let session = AVAudioSession.sharedInstance()

            // 核心安全三道锁：系统打断中、外部音频独占中(如微信录音)、其他音频发声中，绝不强占会话！
            if self.isSystemInterrupted {
                // 无声不能证明微信或电话已经释放麦克风，等待系统中断结束。
                self.wasOtherAudioPlaying = true
                return
            }

            if session.secondaryAudioShouldBeSilencedHint || session.isOtherAudioPlaying {
                self.wasOtherAudioPlaying = true
                return
            }

            // 当其他音频停止发声/录音 (wasOtherAudioPlaying 从 true 变为 false)
            // 或者保活播放器由于任何原因未运行，自动重新激活会话并夺回耳机待命控制权
            if self.wasOtherAudioPlaying || self.silentPlayer == nil || !(self.silentPlayer?.isPlaying ?? false) {
                print("[WearableService] 看门狗：其他音频已停止或保活中断，无缝重新激活会话并夺回耳机实体键")
                self.wasOtherAudioPlaying = false
                self.reactivateStandby()
            }
        }
    }

    private func stopKeepaliveWatchdog() {
        keepaliveWatchdogTimer?.invalidate()
        keepaliveWatchdogTimer = nil
    }

    public func reactivateStandby() {
        guard isListening, !isRecording, !isPlayingAudio, !isSystemInterrupted else { return }
        let session = AVAudioSession.sharedInstance()
        if session.secondaryAudioShouldBeSilencedHint || session.isOtherAudioPlaying {
            print("[WearableService] 外部音频使用中 (如微信录音或音乐播放)，礼貌让路，跳过 reactivateStandby")
            wasOtherAudioPlaying = true
            return
        }
        setupAudioSession(forRecording: false)
        registerRemoteCommands()
        updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")
        // 重启静音保活播放器，注入新的活跃音频流，强力向系统确认活跃播放状态
        silentPlayer?.stop()
        silentPlayer = nil
        ensureSilentPlayerRunning()
    }

    // MARK: - 监听启动与停止
    public func startListening() {
        guard !isListening else { return }
        isListening = true
        reactivateStandby()
        startKeepaliveWatchdog()
        notifyStatusChanged()
        print("[WearableService] 穿戴按键后台监听已启动 (已置为 .playback A2DP)")
    }

    public func stopListening() {
        guard isListening else { return }
        isListening = false

        stopMaxDurationTimer()

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

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[WearableService] 注销音频会话失败: \(error)")
        }

        notifyStatusChanged()
        print("[WearableService] 穿戴按键后台监听已彻底停止")
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
        DeviceDiagnostics.shared.log("Button \(name) recording=\(isRecording) state=\(UIApplication.shared.applicationState.rawValue)")
        // 关键安全守卫：如果监听未开启，100% 忽略按键，绝不自动重启监听或发送消息
        guard isListening else {
            print("[WearableService] 监听未开启，忽略外部按键: \(name)")
            return
        }

        let now = Date().timeIntervalSince1970
        // 防抖：350ms 内忽略硬件连击抖动
        if (now - lastButtonTime) < 0.35 {
            print("[WearableService] 忽略防抖连击: \(name)")
            return
        }
        lastButtonTime = now

        let stateStr = (UIApplication.shared.applicationState == .background) ? "background" : "foreground"

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isListening else { return }

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
                // 核心防抖安全锁：录音启动 0.6 秒内忽略连击抖动
                if duration < 0.6 {
                    print("[WearableService] 录音启动仅 \(String(format: "%.2f", duration))s，忽略连击抖动")
                    return
                }
                self.stopRecording(shouldProcess: true)
                return
            }

            // 3. 首次按键：开启录音
            self.startRecording()
        }
    }

    // MARK: - 原生麦克风录音控制
    public func startRecording() {
        guard !isRecording else { return }
        guard !isSystemInterrupted else {
            updateNowPlayingInfo(statusText: "麦克风被系统占用，请结束通话或录音后重试")
            DeviceDiagnostics.shared.log("Record start rejected: audio interruption active")
            return
        }

        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .granted else {
            if session.recordPermission == .undetermined,
               UIApplication.shared.applicationState == .active {
                session.requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        self?.updateNowPlayingInfo(statusText: granted
                            ? "麦克风已授权，请再次按键录音"
                            : "录音失败：请在设置中允许麦克风权限")
                        self?.notifyStatusChanged()
                    }
                }
            } else {
                updateNowPlayingInfo(statusText: "录音失败：请打开 App 检查麦克风权限")
                notifyStatusChanged()
            }
            return
        }

        // 显式按键启动录音，不通过看门狗强占其他应用的音频会话。
        wasOtherAudioPlaying = false

        // 停止之前的播放与旧的轮询
        stopAudioPlayback()
        stopPolling()

        // 核心修复：录音启动时彻底停止并释放静音保活播放器！录音机本身就是最高优先级的后台保活源，绝对不可在录音时播放底噪！
        silentPlayer?.stop()
        silentPlayer = nil

        // 开启麦克风录音会话模式 (纯 A2DP 高清录音，绝不切换 HFP，保留耳机远程控制)
        guard setupAudioSession(forRecording: true) else {
            recoverFromRecordingStartFailure(message: "录音失败：当前无法启用麦克风")
            return
        }
        let inputDescription = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
        print("[WearableService] 录音输入=\(inputDescription), appState=\(UIApplication.shared.applicationState.rawValue)")
        DeviceDiagnostics.shared.log("Record input=\(inputDescription) state=\(UIApplication.shared.applicationState.rawValue)")

        let tempDir = NSTemporaryDirectory()
        let fileName = "wearable_voice_\(UUID().uuidString).m4a"
        let fileURL = URL(fileURLWithPath: tempDir).appendingPathComponent(fileName)
        self.tempAudioFileURL = fileURL

        // 标准 AAC 录音配置 (16kHz 单声道高清语音)
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
            guard recorder.prepareToRecord(), recorder.record(), recorder.isRecording else {
                recorder.stop()
                recoverFromRecordingStartFailure(message: "录音启动失败，请打开 App 重试")
                return
            }
            self.audioRecorder = recorder
            self.isRecording = true
            self.recordingStartTime = Date()

            startMaxDurationTimer()
            startRecordingHealthMonitor()

            updateNowPlayingInfo(statusText: "🔴 正在录音... (单击按键结束并发送)")
            notifyStatusChanged()
            print("[WearableService] 录音已开始: \(fileURL.path), recording=\(recorder.isRecording)")
            DeviceDiagnostics.shared.log("Record started file=\(fileURL.lastPathComponent)")
        } catch {
            print("[WearableService] 创建 AVAudioRecorder 失败: \(error)")
            DeviceDiagnostics.shared.log("Record creation error=\(error)")
            recoverFromRecordingStartFailure(message: "录音创建失败，请打开 App 重试")
        }
    }

    private func recoverFromRecordingStartFailure(message: String) {
        DeviceDiagnostics.shared.log(message)
        stopMaxDurationTimer()
        audioRecorder = nil
        isRecording = false
        recordingStartTime = nil
        if let fileURL = tempAudioFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        tempAudioFileURL = nil
        if isListening { reactivateStandby() }
        updateNowPlayingInfo(statusText: message)
        notifyStatusChanged()
    }

    public func stopRecording(shouldProcess: Bool = true) {
        guard isRecording else { return }

        stopMaxDurationTimer()
        recordingHealthTimer?.invalidate()
        recordingHealthTimer = nil

        let capturedDuration = audioRecorder?.currentTime ?? 0
        let wallDuration = Date().timeIntervalSince(recordingStartTime ?? Date())
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        notifyStatusChanged()

        // 关键切回：录音结束后立刻切回 .playback，让蓝牙耳机回归 A2DP，保证下一次按键 100% 捕获！
        setupAudioSession(forRecording: false)
        ensureSilentPlayerRunning()

        let duration = capturedDuration
        DeviceDiagnostics.shared.log("Record stopped captured=\(duration) wall=\(wallDuration) process=\(shouldProcess)")
        recordingStartTime = nil
        updateNowPlayingInfo(statusText: "🟡 正在发送给 Agent...")

        guard shouldProcess, let fileURL = tempAudioFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        guard wallDuration < 2 || capturedDuration >= wallDuration - 1.5 else {
            updateNowPlayingInfo(statusText: "录音发生截断，未发送，请重新录音")
            DeviceDiagnostics.shared.log("Record rejected: capture duration does not match elapsed time")
            return
        }

        // 文件头也可能超过大小阈值，提交前确认存在音频帧。
        guard let recordedFile = try? AVAudioFile(forReading: fileURL), recordedFile.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: recordedFile.processingFormat, frameCapacity: 4096) else {
            print("[WearableService] 录音文件无有效音频帧，跳过提交")
            updateNowPlayingInfo(statusText: "录音无效，未发送，请重新录音")
            return
        }
        var peak: Float = 0
        do {
            while recordedFile.framePosition < recordedFile.length {
                try recordedFile.read(into: buffer)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                    updateNowPlayingInfo(statusText: "录音无效，未发送，请重新录音")
                    return
                }
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) {
                        peak = max(peak, abs(channels[channel][frame]))
                    }
                }
            }
        } catch {
            print("[WearableService] 录音无法解码，跳过提交: \(error)")
            updateNowPlayingInfo(statusText: "录音损坏，未发送，请重新录音")
            return
        }
        let fileDuration = Double(recordedFile.length) / recordedFile.processingFormat.sampleRate
        DeviceDiagnostics.shared.log("Record decoded fileDuration=\(fileDuration) frames=\(recordedFile.length) peak=\(peak)")
        guard peak > 0.00003 else {
            updateNowPlayingInfo(statusText: "未采集到声音，未发送，请检查麦克风后重试")
            DeviceDiagnostics.shared.log("Record rejected: silent decoded audio")
            return
        }
        guard fileDuration >= 0.3, abs(fileDuration - capturedDuration) < 1.5 else {
            updateNowPlayingInfo(statusText: "录音文件时长异常，未发送，请重新录音")
            return
        }

        // 读取音频文件
        guard let audioData = try? Data(contentsOf: fileURL), !audioData.isEmpty else {
            print("[WearableService] 录音数据为空，跳过提交")
            updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")
            return
        }

        // 仅拦截瞬间物理抖动（< 0.3s 或 < 500 字节的空文件）
        if duration < 0.3 || audioData.count < 500 {
            print("[WearableService] 录音过短或数据不足 (\(String(format: "%.2f", duration))s, \(audioData.count) 字节)，自动丢弃")
            updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")
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
                DeviceDiagnostics.shared.log("Voice upload failed: \(error.localizedDescription)")
                print("[WearableService] 语音上传网络失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.updateNowPlayingInfo(statusText: "❌ 发送失败，请检查网络")
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode), let data = data else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                DeviceDiagnostics.shared.log("Voice upload HTTP=\(code)")
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
        guard !isRecording, !isSystemInterrupted else {
            DeviceDiagnostics.shared.log("Playback deferred/dropped while recording or interrupted")
            return
        }
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
            if isListening && !isRecording && !isPlayingAudio && !isSystemInterrupted {
                let session = AVAudioSession.sharedInstance()
                if !session.secondaryAudioShouldBeSilencedHint && !session.isOtherAudioPlaying {
                    silentPlayer?.play()
                }
            }
        } else if player == speechPlayer {
            isPlayingAudio = false
            speechPlayer = nil
            updateNowPlayingInfo(statusText: "🟢 耳机待命 (单击按键说话)")
            delegate?.wearableServiceDidFinishPlayback()
            print("[WearableService] 语音播报完毕")
            if isListening && !isRecording && !isSystemInterrupted {
                reactivateStandby()
            }
        }
    }

    // MARK: - 声学与触感反馈辅助
    public func triggerFeedbackHaptic() {
        // 系统震动服务可能与音频会话竞争；录音期间也不触发触感。
        guard !isRecording else { return }
        feedbackGenerator.impactOccurred()
    }

    public func playBeepStart() {
        guard !isSystemInterrupted else { return }
        beepStartPlayer?.currentTime = 0
        beepStartPlayer?.play()
    }

    public func playBeepEnd() {
        beepEndPlayer?.currentTime = 0
        beepEndPlayer?.play()
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

    // MARK: - 最大录音时长看门狗 (90秒兜底)
    private func startMaxDurationTimer() {
        stopMaxDurationTimer()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            print("[WearableService] 达到最大安全录音时长(90s)，自动结束并发送")
            self.stopRecording(shouldProcess: true)
        }
    }

    private func stopMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    // MARK: - AVAudioRecorderDelegate
    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        print("[WearableService] audioRecorderDidFinishRecording: successfully=\(flag)")
        guard recorder === audioRecorder, isRecording else { return }
        failActiveRecording(message: "录音意外停止，未发送，请重新录音")
    }

    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("[WearableService] audioRecorderEncodeErrorDidOccur: \(String(describing: error))")
        DeviceDiagnostics.shared.log("Record encoding error=\(String(describing: error))")
        guard recorder === audioRecorder, isRecording else { return }
        failActiveRecording(message: "录音编码失败，未发送，请重新录音")
    }

    private func startRecordingHealthMonitor() {
        recordingHealthTimer?.invalidate()
        lastCapturedTime = 0
        lastCaptureProgressAt = ProcessInfo.processInfo.systemUptime
        var confirmed = false
        recordingHealthTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording, let recorder = self.audioRecorder else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let captured = recorder.currentTime
            if captured > self.lastCapturedTime + 0.01 {
                self.lastCapturedTime = captured
                self.lastCaptureProgressAt = now
                if !confirmed, captured >= 0.25 {
                    confirmed = true
                    recorder.updateMeters()
                    DeviceDiagnostics.shared.log("Record capture confirmed time=\(captured) peakDB=\(recorder.peakPower(forChannel: 0))")
                    self.playBeepStart()
                }
            }
            if !recorder.isRecording || now - self.lastCaptureProgressAt > 1.25 {
                DeviceDiagnostics.shared.log("Record stalled isRecording=\(recorder.isRecording) captured=\(captured)")
                self.failActiveRecording(message: "麦克风采集中断，未发送，请重新录音")
            }
        }
    }

    private func failActiveRecording(message: String) {
        guard isRecording else { return }
        recordingHealthTimer?.invalidate()
        recordingHealthTimer = nil
        stopMaxDurationTimer()
        isRecording = false
        let recorder = audioRecorder
        audioRecorder = nil
        recorder?.stop()
        recordingStartTime = nil
        DeviceDiagnostics.shared.log(message)
        if isListening, !isSystemInterrupted { reactivateStandby() }
        updateNowPlayingInfo(statusText: message)
        notifyStatusChanged()
    }
}
