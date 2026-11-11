import Foundation
import UIKit
import AVFoundation
import MediaPlayer
import AudioToolbox
import Speech

public protocol WearableServiceDelegate: AnyObject {
    func wearableServiceDidChangeDeviceStatus(connected: Bool, deviceName: String, isListening: Bool, isRecording: Bool)
    func wearableServiceDidCaptureButton(name: String, appState: String)
    func wearableServiceDidFinishRecording(base64: String, mimeType: String, transcript: String, duration: TimeInterval)
    func wearableServiceDidFinishPlayback()
}

/// 智能穿戴耳机后台中枢服务
/// 负责后台音频保活、蓝牙耳机实体键捕获、后台麦克风录音、本地语音识别以及声学/触觉反馈
public final class WearableService: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {

    public static let shared = WearableService()

    public weak var delegate: WearableServiceDelegate?

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

    // 触觉反馈
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)

    // 本地语音识别
    private var speechRecognizer: SFSpeechRecognizer?

    private override init() {
        super.init()
        feedbackGenerator.prepare()
        setupBeepPlayers()
        setupSpeechRecognizer()
        updateAudioRouteInfo()

        // 监听系统音频路由变更通知（蓝牙连接/断开）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    // MARK: - 语音识别初始化
    private func setupSpeechRecognizer() {
        // 首选简体中文识别器
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }

        SFSpeechRecognizer.requestAuthorization { authStatus in
            switch authStatus {
            case .authorized:
                print("[WearableService] SFSpeechRecognizer 授权成功")
            case .denied, .restricted, .notDetermined:
                print("[WearableService] SFSpeechRecognizer 授权未通过: \(authStatus.rawValue)")
            @unknown default:
                break
            }
        }
    }

    // MARK: - 音频会话设置
    private func setupAudioSession(forRecording: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if forRecording {
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
                )
            } else {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
                )
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[WearableService] 音频会话配置失败: \(error)")
        }
    }

    @objc private func handleAudioRouteChange(notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateAudioRouteInfo()
            self.notifyStatusChanged()
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

    // MARK: - 监听启动与停止 (后台保活核心)
    public func startListening() {
        guard !isListening else { return }
        setupAudioSession(forRecording: false)

        do {
            let silentData = generateSilentWAV()
            silentPlayer = try AVAudioPlayer(data: silentData)
            silentPlayer?.numberOfLoops = -1
            silentPlayer?.volume = 0.01
            silentPlayer?.prepareToPlay()
            silentPlayer?.play()
        } catch {
            print("[WearableService] 静音保活播放器启动失败: \(error)")
            return
        }

        registerRemoteCommands()
        updateNowPlayingInfo(statusText: "🟢 耳机按键待命 (单击按键录音)")

        isListening = true
        notifyStatusChanged()
        print("[WearableService] 穿戴按键后台监听已启动")
    }

    public func stopListening() {
        guard isListening else { return }

        if isRecording {
            stopRecording(shouldProcess: false)
        }
        stopAudioPlayback()

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

        // 1. 耳机单击（播放/暂停切换）
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleHardwareButtonPress(name: "togglePlayPause")
            return .success
        }

        // 2. 播放按键
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.handleHardwareButtonPress(name: "play")
            return .success
        }

        // 3. 暂停按键
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.handleHardwareButtonPress(name: "pause")
            return .success
        }

        // 4. 耳机双击（下一首）
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleHardwareButtonPress(name: "nextTrack")
            return .success
        }

        // 5. 耳机三击（上一首）
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.handleHardwareButtonPress(name: "previousTrack")
            return .success
        }

        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func unregisterRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
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
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = .playing
    }

    // MARK: - 实体按键交互流转 (录音、结束、打断)
    public func handleHardwareButtonPress(name: String) {
        let stateStr = (UIApplication.shared.applicationState == .background) ? "background" : "foreground"

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.delegate?.wearableServiceDidCaptureButton(name: name, appState: stateStr)

            // 1. 如果正在播报 AI 语音 -> 瞬间打断 (Barge-in)
            if self.isPlayingAudio {
                self.triggerFeedbackHaptic()
                self.stopAudioPlayback()
                self.updateNowPlayingInfo(statusText: "⏸ 播报已打断")
                return
            }

            // 2. 如果正在录音 -> 停止录音并提交
            if self.isRecording {
                self.stopRecording(shouldProcess: true)
                return
            }

            // 3. 如果在待命监听中 -> 开启录音
            if self.isListening {
                self.startRecording()
                return
            }

            // 兜底触发触觉反馈
            self.triggerFeedbackHaptic()
        }
    }

    // MARK: - 原生麦克风录音控制
    public func startRecording() {
        guard !isRecording else { return }

        // 停止之前的播放
        stopAudioPlayback()

        // 触感反馈 + 清脆高音提示音
        triggerFeedbackHaptic()
        playBeepStart()

        setupAudioSession(forRecording: true)

        let tempDir = NSTemporaryDirectory()
        let fileName = "wearable_\(Int(Date().timeIntervalSince1970)).m4a"
        let fileURL = URL(fileURLWithPath: tempDir).appendingPathComponent(fileName)
        self.tempAudioFileURL = fileURL

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.delegate = self
            recorder.prepareToRecord()
            recorder.record()
            self.audioRecorder = recorder
            self.isRecording = true
            self.recordingStartTime = Date()

            updateNowPlayingInfo(statusText: "🔴 正在录音... (单击按键结束)")
            notifyStatusChanged()
            print("[WearableService] 录音已开始: \(fileURL.path)")
        } catch {
            print("[WearableService] 创建 AVAudioRecorder 失败: \(error)")
        }
    }

    public func stopRecording(shouldProcess: Bool = true) {
        guard isRecording else { return }

        playBeepEnd()
        triggerFeedbackHaptic()

        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        notifyStatusChanged()

        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        updateNowPlayingInfo(statusText: "🟡 正在识别与思考...")

        // 恢复保活模式
        setupAudioSession(forRecording: false)
        silentPlayer?.play()

        guard shouldProcess, let fileURL = tempAudioFileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        // 读取音频文件为 Base64
        guard let audioData = try? Data(contentsOf: fileURL) else {
            print("[WearableService] 无法读取录音文件数据")
            return
        }
        let base64String = audioData.base64EncodedString()

        // 先触发本地快速语音识别
        recognizeSpeech(fileURL: fileURL) { [weak self] transcript in
            guard let self = self else { return }
            print("[WearableService] 本地语音识别完成, 结果: '\(transcript)', 时长: \(String(format: "%.1f", duration))s")

            DispatchQueue.main.async {
                self.delegate?.wearableServiceDidFinishRecording(
                    base64: base64String,
                    mimeType: "audio/m4a",
                    transcript: transcript,
                    duration: duration
                )
            }

            // 清理临时文件
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - 本地语音转文字 (SFSpeechRecognizer)
    private func recognizeSpeech(fileURL: URL, completion: @escaping (String) -> Void) {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("[WearableService] SFSpeechRecognizer 不可用，跳过本地识别")
            completion("")
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        if #available(iOS 13.0, *) {
            request.requiresOnDeviceRecognition = false
        }

        recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                print("[WearableService] 语音转写错误: \(error.localizedDescription)")
                completion("")
                return
            }

            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(text)
            }
        }
    }

    // MARK: - AI 语音播报推送到耳机
    public func playAudioStream(urlString: String?, base64Data: String?) {
        stopAudioPlayback()

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

        guard let data = audioData, !data.isEmpty else {
            print("[WearableService] 播放数据为空")
            return
        }

        do {
            setupAudioSession(forRecording: false)
            speechPlayer = try AVAudioPlayer(data: data)
            speechPlayer?.delegate = self
            speechPlayer?.prepareToPlay()
            speechPlayer?.play()
            isPlayingAudio = true
            updateNowPlayingInfo(statusText: "🔊 正在播报 AI 回复 (按键可打断)")
            print("[WearableService] 已开始播报语音流")
        } catch {
            print("[WearableService] 播放语音失败: \(error)")
            isPlayingAudio = false
        }
    }

    public func stopAudioPlayback() {
        if isPlayingAudio || speechPlayer != nil {
            speechPlayer?.stop()
            speechPlayer = nil
            isPlayingAudio = false
            updateNowPlayingInfo(statusText: "🟢 耳机按键待命 (单击按键录音)")
            delegate?.wearableServiceDidFinishPlayback()
            print("[WearableService] 语音播报已停止")
        }
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player == speechPlayer {
            isPlayingAudio = false
            speechPlayer = nil
            updateNowPlayingInfo(statusText: "🟢 耳机按键待命 (单击按键录音)")
            delegate?.wearableServiceDidFinishPlayback()
            print("[WearableService] 语音播报播放完毕")
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
        AudioServicesPlaySystemSound(1057) // 经典轻促提示音
    }

    public func playBeepEnd() {
        beepEndPlayer?.currentTime = 0
        beepEndPlayer?.play()
        AudioServicesPlaySystemSound(1054) // 确认完成音
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
