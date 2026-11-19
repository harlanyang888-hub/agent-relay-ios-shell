import UIKit
import AVFoundation

// UI adapter: renders existing state and invokes the already tested phone APIs.
// No capture, call, upload, command-retry or microphone-routing logic lives here.
@available(iOS 17.4, *)
final class RelayWatchController: UIViewController {
    private let dashboard = WatchDashboardView()
    private var refreshTimer: Timer?
    override func loadView() { view = dashboard }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "relay watch"
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(red: 10/255, green: 11/255, blue: 13/255, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "电量记录", style: .plain, target: self, action: #selector(openBatteryHistory))
        dashboard.onAction = { [weak self] action in self?.handle(action) }
        refresh()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refreshTimer?.invalidate(); refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        refreshTimer?.invalidate(); refreshTimer = nil
        // Leaving a presentation must never stop recording or disconnect BLE.
    }
    private func refresh() {
        let watch = WatchVoiceSession.shared
        let audio = WearableService.shared
        let battery = WatchBatteryStore.shared
        let ready = BLEProbe.shared.isVoiceDeviceReady
        let phase = watch.captureStatus
        let recording = phase == .recording
        let paused = phase == .paused
        let busy = watch.actionInFlight
        let title: String
        switch phase {
        case .idle: title = "随时开始说话"
        case .starting: title = "正在启动录音"
        case .recording: title = "正在录音"
        case .paused: title = "录音已暂停"
        case .finalizing: title = "正在保存录音"
        }
        let age = battery.sample.map { Date().timeIntervalSince($0.receivedAt) } ?? .infinity
        let batteryStyle: WatchDashboardViewState.BatteryStatus
        if !battery.connected { batteryStyle = .disconnected }
        else if age > 180, battery.sample != nil { batteryStyle = .stale }
        else if battery.sample?.percent == nil { batteryStyle = .unknown }
        else if battery.sample?.charging == true { batteryStyle = .charging }
        else if (battery.sample?.percent ?? 100) < 20 { batteryStyle = .low }
        else { batteryStyle = .normal }
        let seconds = max(0, Int(audio.capturedRecordingDuration))
        let time = recording ? String(format: "%02d:%02d", seconds / 60, seconds % 60) : "--:--"
        let detail: String
        if let error = watch.lastError { detail = error }
        else if recording { detail = "本段时长 · 手机采音：" + (audio.recordingInputName.isEmpty ? "等待输入信息" : audio.recordingInputName) }
        else if paused { detail = "草稿已保留。继续追加，或发送为一条语音。" }
        else { detail = watch.hasConversation ? "下一条语音继续当前对话" : "开始录音，发送后创建新对话" }
        dashboard.configure(state: WatchDashboardViewState(
            deviceName: "relay watch", deviceSubtitle: "按键控制 · 手机录音",
            statusTitle: ready ? "设备已就绪" : "设备尚未就绪",
            statusDetail: ready ? "可通过手表按键控制手机录音" : "配对后靠近手机，等待设备就绪",
            connectionState: ready ? .connected : .disconnected,
            batteryText: battery.title, batteryDetail: battery.detail,
            isCharging: battery.sample?.charging == true, batteryStatus: batteryStyle,
            recordingState: recording ? .recording : paused ? .pausedDraft : busy ? .transmitting : .idle,
            recordingTitle: title, recordingDetail: detail, recordingTime: time,
            isRecording: recording, isPaused: paused, pendingCount: watch.pendingDeliveryCount,
            pendingText: watch.pendingDeliveryCount == 0 ? "暂无待发录音" : "\(watch.pendingDeliveryCount) 条录音等待确认",
            pendingDetail: "网络或登录恢复后自动重试；结果不确定的文件可在待发箱核对。",
            primaryButton: .init(title: watch.hasDraft ? "发送本条 · 保留对话" : "开始录音", isEnabled: !busy),
            pauseResumeButton: .init(title: paused ? "继续录音" : "暂停录音", isEnabled: !busy && (recording || paused)),
            endConversationButton: .init(title: watch.hasDraft ? "发送并结束对话" : "结束当前对话", isEnabled: watch.hasConversation || watch.hasDraft || busy),
            reconnectButton: .init(title: "添加 / 切换设备", isEnabled: !busy && !recording),
            outboxButton: .init(title: "录音待发箱"), diagnosticsButton: .init(title: "设置与诊断")))
    }
    private func handle(_ action: WatchDashboardAction) {
        let watch = WatchVoiceSession.shared
        switch action {
        case .primaryAction:
            if watch.hasDraft { watch.phoneSend() } else { watch.phoneStart() }
        case .pauseResumeRecording:
            if watch.isPausedDraft { watch.phoneStart() } else { watch.phonePause() }
        case .endConversation: watch.phoneEnd()
        case .reconnectOrAddDevice: chooseDevice()
        case .openOutbox: openDiagnostics(outbox: true)
        case .openDiagnostics: openDiagnostics(outbox: false)
        }
        refresh()
    }
    private func chooseDevice() {
        let probe = BLEProbe.shared
        let ids = probe.authorizedButtonIDs
        guard !ids.isEmpty else { probe.addNewAccessory(); return }
        let alert = UIAlertController(title: "连接语音设备", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "配对新设备", style: .default) { _ in probe.addNewAccessory() })
        for (index, id) in ids.enumerated() {
            alert.addAction(UIAlertAction(title: "\(probe.authorizedButtonName(id)) · \(index + 1)", style: .default) { _ in probe.reconnectAuthorizedButton(id) })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(alert, animated: true)
    }
    private func openDiagnostics(outbox: Bool) {
        let detail = DeviceDiagnosticsViewController()
        let nav = UINavigationController(rootViewController: detail)
        nav.overrideUserInterfaceStyle = .dark
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true) { if outbox { detail.showVoiceRecovery() } }
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func openBatteryHistory() {
        navigationController?.pushViewController(BatteryHistoryController(), animated: true)
    }
    deinit { refreshTimer?.invalidate() }
}
