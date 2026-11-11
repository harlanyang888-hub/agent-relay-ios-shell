import UIKit
import AVFoundation
import MediaPlayer
import AudioToolbox

/// 智能穿戴按键 PoC 验证控制器
/// 用于验证普通实体按键蓝牙耳机连接 iPhone 时，在后台/锁屏状态下能否捕获到按键硬件事件
class WearablePoCViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    // MARK: - 数据模型
    struct KeyPressLog {
        let timestamp: Date
        let eventName: String
        let appState: String
        let isSuccess: Bool
    }

    // MARK: - UI 控件
    private let scrollView = UIScrollView()
    private let contentView = UIView()

    // 状态卡片
    private let statusCard = UIView()
    private let statusDot = UIView()
    private let statusLabel = UILabel()
    private let routeIconLabel = UILabel()
    private let routeLabel = UILabel()
    private let countTitleLabel = UILabel()
    private let countValueLabel = UILabel()

    // 控制卡片
    private let controlCard = UIView()
    private let toggleListenButton = UIButton(type: .system)
    private let testFeedbackButton = UIButton(type: .system)
    private let clearLogsButton = UIButton(type: .system)

    // 指引卡片
    private let guideCard = UIView()
    private let guideLabel = UILabel()

    // 日志卡片
    private let logCard = UIView()
    private let logHeaderLabel = UILabel()
    private let tableView = UITableView()

    // MARK: - 核心逻辑属性
    private var isListening = false
    private var captureCount = 0
    private var logs: [KeyPressLog] = []

    private var silentPlayer: AVAudioPlayer?
    private var beepPlayer: AVAudioPlayer?
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)

    // MARK: - 生命周期
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupAudioSession()
        setupBeepAudioPlayer()
        updateAudioRouteUI()
        
        // 监听音频路由变化（蓝牙耳机连接/断开）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        feedbackGenerator.prepare()
        appendLog(event: "PoC 系统就绪", isSuccess: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateAudioRouteUI()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    // MARK: - UI 构建
    private func setupUI() {
        view.backgroundColor = UIColor(red: 15/255.0, green: 17/255.0, blue: 23/255.0, alpha: 1.0) // #0f1117

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])

        // 1. 顶部标题
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "🎧 智能穿戴按键 PoC"
        titleLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        contentView.addSubview(titleLabel)

        let subtitleLabel = UILabel()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "验证蓝牙耳机实体按键在后台/锁屏下的捕获与反馈"
        subtitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 0.65, alpha: 1.0)
        contentView.addSubview(subtitleLabel)

        // 2. 状态卡片
        setupStatusCard()

        // 3. 控制卡片
        setupControlCard()

        // 4. 操作指引卡片
        setupGuideCard()

        // 5. 日志卡片
        setupLogCard()

        // 整体纵向布局
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            statusCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            statusCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            controlCard.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 14),
            controlCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            controlCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            guideCard.topAnchor.constraint(equalTo: controlCard.bottomAnchor, constant: 14),
            guideCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            guideCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            logCard.topAnchor.constraint(equalTo: guideCard.bottomAnchor, constant: 14),
            logCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            logCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            logCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            logCard.heightAnchor.constraint(equalToConstant: 320)
        ])
    }

    private func setupStatusCard() {
        statusCard.translatesAutoresizingMaskIntoConstraints = false
        statusCard.backgroundColor = UIColor(red: 26/255.0, green: 29/255.0, blue: 38/255.0, alpha: 1.0)
        statusCard.layer.cornerRadius = 14
        statusCard.layer.borderWidth = 1
        statusCard.layer.borderColor = UIColor(white: 0.2, alpha: 1.0).cgColor
        contentView.addSubview(statusCard)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.layer.cornerRadius = 5
        statusDot.backgroundColor = .systemGray
        statusCard.addSubview(statusDot)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "监听已停止 (未保活)"
        statusLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textColor = .white
        statusCard.addSubview(statusLabel)

        routeIconLabel.translatesAutoresizingMaskIntoConstraints = false
        routeIconLabel.text = "🔊"
        routeIconLabel.font = UIFont.systemFont(ofSize: 14)
        statusCard.addSubview(routeIconLabel)

        routeLabel.translatesAutoresizingMaskIntoConstraints = false
        routeLabel.text = "当前路由: 检测中..."
        routeLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        routeLabel.textColor = UIColor(white: 0.75, alpha: 1.0)
        statusCard.addSubview(routeLabel)

        countTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        countTitleLabel.text = "累计捕获"
        countTitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        countTitleLabel.textColor = UIColor(white: 0.6, alpha: 1.0)
        statusCard.addSubview(countTitleLabel)

        countValueLabel.translatesAutoresizingMaskIntoConstraints = false
        countValueLabel.text = "0 次"
        countValueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 24, weight: .bold)
        countValueLabel.textColor = UIColor(red: 16/255.0, green: 185/255.0, blue: 129/255.0, alpha: 1.0) // #10b981
        statusCard.addSubview(countValueLabel)

        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            statusDot.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),

            statusLabel.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),

            routeIconLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            routeIconLabel.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),

            routeLabel.centerYAnchor.constraint(equalTo: routeIconLabel.centerYAnchor),
            routeLabel.leadingAnchor.constraint(equalTo: routeIconLabel.trailingAnchor, constant: 6),
            routeLabel.trailingAnchor.constraint(equalTo: countValueLabel.leadingAnchor, constant: -10),
            routeLabel.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -14),

            countValueLabel.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            countValueLabel.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -12),

            countTitleLabel.trailingAnchor.constraint(equalTo: countValueLabel.trailingAnchor),
            countTitleLabel.bottomAnchor.constraint(equalTo: countValueLabel.topAnchor, constant: -2)
        ])
    }

    private func setupControlCard() {
        controlCard.translatesAutoresizingMaskIntoConstraints = false
        controlCard.backgroundColor = UIColor(red: 26/255.0, green: 29/255.0, blue: 38/255.0, alpha: 1.0)
        controlCard.layer.cornerRadius = 14
        controlCard.layer.borderWidth = 1
        controlCard.layer.borderColor = UIColor(white: 0.2, alpha: 1.0).cgColor
        contentView.addSubview(controlCard)

        // 主切换按钮
        toggleListenButton.translatesAutoresizingMaskIntoConstraints = false
        toggleListenButton.setTitle("▶ 启动穿戴按键监听 (后台保活)", for: .normal)
        toggleListenButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        toggleListenButton.setTitleColor(.white, for: .normal)
        toggleListenButton.backgroundColor = UIColor(red: 16/255.0, green: 185/255.0, blue: 129/255.0, alpha: 1.0)
        toggleListenButton.layer.cornerRadius = 10
        toggleListenButton.addTarget(self, action: #selector(onToggleListenPressed), for: .touchUpInside)
        controlCard.addSubview(toggleListenButton)

        // 测试与清空行
        testFeedbackButton.translatesAutoresizingMaskIntoConstraints = false
        testFeedbackButton.setTitle("🔔 测试声振反馈", for: .normal)
        testFeedbackButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        testFeedbackButton.setTitleColor(.white, for: .normal)
        testFeedbackButton.backgroundColor = UIColor(red: 45/255.0, green: 55/255.0, blue: 72/255.0, alpha: 1.0)
        testFeedbackButton.layer.cornerRadius = 8
        testFeedbackButton.addTarget(self, action: #selector(onTestFeedbackPressed), for: .touchUpInside)
        controlCard.addSubview(testFeedbackButton)

        clearLogsButton.translatesAutoresizingMaskIntoConstraints = false
        clearLogsButton.setTitle("🗑 清空日志", for: .normal)
        clearLogsButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        clearLogsButton.setTitleColor(UIColor(white: 0.8, alpha: 1.0), for: .normal)
        clearLogsButton.backgroundColor = UIColor(red: 35/255.0, green: 40/255.0, blue: 50/255.0, alpha: 1.0)
        clearLogsButton.layer.cornerRadius = 8
        clearLogsButton.addTarget(self, action: #selector(onClearLogsPressed), for: .touchUpInside)
        controlCard.addSubview(clearLogsButton)

        NSLayoutConstraint.activate([
            toggleListenButton.topAnchor.constraint(equalTo: controlCard.topAnchor, constant: 14),
            toggleListenButton.leadingAnchor.constraint(equalTo: controlCard.leadingAnchor, constant: 14),
            toggleListenButton.trailingAnchor.constraint(equalTo: controlCard.trailingAnchor, constant: -14),
            toggleListenButton.heightAnchor.constraint(equalToConstant: 46),

            testFeedbackButton.topAnchor.constraint(equalTo: toggleListenButton.bottomAnchor, constant: 10),
            testFeedbackButton.leadingAnchor.constraint(equalTo: controlCard.leadingAnchor, constant: 14),
            testFeedbackButton.trailingAnchor.constraint(equalTo: controlCard.centerXAnchor, constant: -5),
            testFeedbackButton.heightAnchor.constraint(equalToConstant: 38),
            testFeedbackButton.bottomAnchor.constraint(equalTo: controlCard.bottomAnchor, constant: -14),

            clearLogsButton.topAnchor.constraint(equalTo: testFeedbackButton.topAnchor),
            clearLogsButton.leadingAnchor.constraint(equalTo: controlCard.centerXAnchor, constant: 5),
            clearLogsButton.trailingAnchor.constraint(equalTo: controlCard.trailingAnchor, constant: -14),
            clearLogsButton.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    private func setupGuideCard() {
        guideCard.translatesAutoresizingMaskIntoConstraints = false
        guideCard.backgroundColor = UIColor(red: 20/255.0, green: 26/255.0, blue: 38/255.0, alpha: 1.0)
        guideCard.layer.cornerRadius = 12
        guideCard.layer.borderWidth = 1
        guideCard.layer.borderColor = UIColor(red: 30/255.0, green: 58/255.0, blue: 138/255.0, alpha: 0.6).cgColor
        contentView.addSubview(guideCard)

        guideLabel.translatesAutoresizingMaskIntoConstraints = false
        guideLabel.numberOfLines = 0
        guideLabel.textColor = UIColor(red: 191/255.0, green: 219/255.0, blue: 254/255.0, alpha: 1.0)
        guideLabel.font = UIFont.systemFont(ofSize: 12.5, weight: .regular)
        guideLabel.text = """
        💡 极简验证步骤：
        1. 佩戴蓝牙耳机并与本手机连接，上方确认出现蓝牙设备名；
        2. 点击【启动穿戴按键监听】（此时 App 开始静默无声保活）；
        3. 按手机电源键锁屏，或者直接返回手机主屏幕退至后台；
        4. 按一下耳机上的实体按键（单击或双击）；
        5. 验证成功标准：手机产生振动，且耳机/扬声器中发出哔哔提示音！
        """
        guideCard.addSubview(guideLabel)

        NSLayoutConstraint.activate([
            guideLabel.topAnchor.constraint(equalTo: guideCard.topAnchor, constant: 12),
            guideLabel.leadingAnchor.constraint(equalTo: guideCard.leadingAnchor, constant: 12),
            guideLabel.trailingAnchor.constraint(equalTo: guideCard.trailingAnchor, constant: -12),
            guideLabel.bottomAnchor.constraint(equalTo: guideCard.bottomAnchor, constant: -12)
        ])
    }

    private func setupLogCard() {
        logCard.translatesAutoresizingMaskIntoConstraints = false
        logCard.backgroundColor = UIColor(red: 26/255.0, green: 29/255.0, blue: 38/255.0, alpha: 1.0)
        logCard.layer.cornerRadius = 14
        logCard.layer.borderWidth = 1
        logCard.layer.borderColor = UIColor(white: 0.2, alpha: 1.0).cgColor
        contentView.addSubview(logCard)

        logHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        logHeaderLabel.text = "📋 硬件按键捕获日志 (实时)"
        logHeaderLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        logHeaderLabel.textColor = .white
        logCard.addSubview(logHeaderLabel)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 0.18, alpha: 1.0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "LogCell")
        logCard.addSubview(tableView)

        NSLayoutConstraint.activate([
            logHeaderLabel.topAnchor.constraint(equalTo: logCard.topAnchor, constant: 12),
            logHeaderLabel.leadingAnchor.constraint(equalTo: logCard.leadingAnchor, constant: 14),
            logHeaderLabel.trailingAnchor.constraint(equalTo: logCard.trailingAnchor, constant: -14),

            tableView.topAnchor.constraint(equalTo: logHeaderLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: logCard.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: logCard.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: logCard.bottomAnchor, constant: -8)
        ])
    }

    // MARK: - 音频会话与保活机制
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setActive(true)
        } catch {
            appendLog(event: "音频会话激活失败: \(error.localizedDescription)", isSuccess: false)
        }
    }

    @objc private func handleAudioRouteChange(notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateAudioRouteUI()
        }
    }

    private func updateAudioRouteUI() {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        var isBluetoothConnected = false
        var deviceName = "扬声器 / 听筒"

        for output in currentRoute.outputs {
            if output.portType == .bluetoothA2DP || output.portType == .bluetoothHFP || output.portType == .bluetoothLE {
                isBluetoothConnected = true
                deviceName = output.portName
                break
            } else if output.portType == .headphones {
                deviceName = "有线耳机 (\(output.portName))"
                break
            }
        }

        if isBluetoothConnected {
            routeIconLabel.text = "🎧"
            routeLabel.text = "蓝牙已连接: \(deviceName)"
            routeLabel.textColor = UIColor(red: 52/255.0, green: 211/255.0, blue: 153/255.0, alpha: 1.0) // 浅绿
        } else {
            routeIconLabel.text = "📱"
            routeLabel.text = "未检测到蓝牙耳机 (当前: \(deviceName))"
            routeLabel.textColor = UIColor(white: 0.65, alpha: 1.0)
        }
    }

    // MARK: - 无声音频与提示音引擎
    /// 动态生成 1 秒 PCM 静音 WAV（0 振幅），用于无声保活
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
        data.append(Data(count: Int(dataSize))) // 纯 0 静音数据
        return data
    }

    /// 动态合成 0.15 秒 880Hz（高音 A）清脆提示音，零外部音频资源依赖
    private func setupBeepAudioPlayer() {
        let sampleRate: Double = 44100
        let duration: Double = 0.15
        let frequency: Double = 880.0
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
            // 淡入淡出避免爆音
            let envelope = sin(Double.pi * (Double(i) / Double(totalSamples)))
            let sampleVal = Int16(sin(angle) * envelope * 28000)
            audioData.append(contentsOf: withUnsafeBytes(of: sampleVal.littleEndian) { Array($0) })
        }

        do {
            beepPlayer = try AVAudioPlayer(data: audioData)
            beepPlayer?.prepareToPlay()
        } catch {
            print("Beep player 初始化失败: \(error)")
        }
    }

    // MARK: - 远程控制按键注册 (MPRemoteCommandCenter)
    private func registerRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // 1. 播放/暂停键（单按耳机实体按键最常见的指令）
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleHardwareButtonEvent(name: "TogglePlayPause (耳机单击)")
            return .success
        }

        // 2. 播放键
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.handleHardwareButtonEvent(name: "PlayCommand (播放指令)")
            return .success
        }

        // 3. 暂停键
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.handleHardwareButtonEvent(name: "PauseCommand (暂停指令)")
            return .success
        }

        // 4. 下一首（部分耳机双击物理键）
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleHardwareButtonEvent(name: "NextTrack (耳机双击)")
            return .success
        }

        // 5. 上一首（部分耳机三击物理键）
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.handleHardwareButtonEvent(name: "PreviousTrack (耳机三击)")
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
        info[MPMediaItemPropertyTitle] = "Agent Relay 穿戴监听 PoC"
        info[MPMediaItemPropertyArtist] = statusText
        info[MPMediaItemPropertyAlbumTitle] = "累计捕获: \(captureCount) 次"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = .playing
    }

    // MARK: - 硬件按键核心捕获处理
    private func handleHardwareButtonEvent(name: String) {
        let stateStr = (UIApplication.shared.applicationState == .background) ? "后台/锁屏" : "前台"

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.captureCount += 1
            self.countValueLabel.text = "\(self.captureCount) 次"

            // 1. 触发振动反馈（在锁屏后台最可靠的是 kSystemSoundID_Vibrate）
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            self.feedbackGenerator.impactOccurred()

            // 2. 触发声音反馈（短提示音输出到蓝牙耳机）
            self.beepPlayer?.currentTime = 0
            self.beepPlayer?.play()
            // 双重保障：同时触发系统通知短音 (1057 为经典提示音)
            AudioServicesPlaySystemSound(1057)

            // 3. 记录日志
            self.appendLog(event: "\(name) [\(stateStr)]", isSuccess: true)

            // 4. 更新锁屏卡片显示
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let timeStr = formatter.string(from: Date())
            self.updateNowPlayingInfo(statusText: "按键捕获: \(name) (\(timeStr))")
        }
    }

    // MARK: - 交互事件
    @objc private func onToggleListenPressed() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        setupAudioSession()

        // 启动无声循环播放进行后台保活
        do {
            let silentData = generateSilentWAV()
            silentPlayer = try AVAudioPlayer(data: silentData)
            silentPlayer?.numberOfLoops = -1
            silentPlayer?.volume = 0.01 // 极低微振幅
            silentPlayer?.prepareToPlay()
            silentPlayer?.play()
        } catch {
            appendLog(event: "静音保活播放器启动失败: \(error.localizedDescription)", isSuccess: false)
            return
        }

        registerRemoteCommands()
        updateNowPlayingInfo(statusText: "监听中... 请按耳机实体键")

        isListening = true
        statusDot.backgroundColor = UIColor(red: 16/255.0, green: 185/255.0, blue: 129/255.0, alpha: 1.0)
        statusLabel.text = "🟢 正在后台监听中 (保活已启动)"
        statusLabel.textColor = UIColor(red: 52/255.0, green: 211/255.0, blue: 153/255.0, alpha: 1.0)

        toggleListenButton.setTitle("⏹ 停止穿戴按键监听", for: .normal)
        toggleListenButton.backgroundColor = UIColor(red: 239/255.0, green: 68/255.0, blue: 68/255.0, alpha: 1.0) // 红色

        appendLog(event: "已启动监听：音频后台保活激活，可按电源键锁屏测试", isSuccess: true)
    }

    private func stopListening() {
        silentPlayer?.stop()
        silentPlayer = nil
        unregisterRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        isListening = false
        statusDot.backgroundColor = .systemGray
        statusLabel.text = "监听已停止 (未保活)"
        statusLabel.textColor = .white

        toggleListenButton.setTitle("▶ 启动穿戴按键监听 (后台保活)", for: .normal)
        toggleListenButton.backgroundColor = UIColor(red: 16/255.0, green: 185/255.0, blue: 129/255.0, alpha: 1.0)

        appendLog(event: "已停止监听并释放后台保活", isSuccess: false)
    }

    @objc private func onTestFeedbackPressed() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        feedbackGenerator.impactOccurred()
        beepPlayer?.currentTime = 0
        beepPlayer?.play()
        AudioServicesPlaySystemSound(1057)
        appendLog(event: "手动测试: 震动 + 提示音已触发", isSuccess: true)
    }

    @objc private func onClearLogsPressed() {
        logs.removeAll()
        captureCount = 0
        countValueLabel.text = "0 次"
        tableView.reloadData()
    }

    private func appendLog(event: String, isSuccess: Bool) {
        let stateStr = (UIApplication.shared.applicationState == .background) ? "后台" : "前台"
        let log = KeyPressLog(timestamp: Date(), eventName: event, appState: stateStr, isSuccess: isSuccess)
        logs.insert(log, at: 0) // 最新的在顶部
        tableView.reloadData()
    }

    // MARK: - TableView 数据源
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return logs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LogCell", for: indexPath)
        cell.backgroundColor = .clear
        cell.selectionStyle = .none

        let item = logs[indexPath.row]
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timeStr = formatter.string(from: item.timestamp)

        let prefix = item.isSuccess ? "✅" : "ℹ️"
        let attrText = NSMutableAttributedString(
            string: "[\(timeStr)] ",
            attributes: [.foregroundColor: UIColor(white: 0.5, alpha: 1.0), .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        )
        attrText.append(NSAttributedString(
            string: "\(prefix) \(item.eventName)",
            attributes: [.foregroundColor: item.isSuccess ? UIColor.white : UIColor.systemGray, .font: UIFont.systemFont(ofSize: 13, weight: .medium)]
        ))

        cell.textLabel?.attributedText = attrText
        cell.textLabel?.numberOfLines = 2
        return cell
    }
}
