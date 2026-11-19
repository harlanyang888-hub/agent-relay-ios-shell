//
//  WatchDashboardView.swift
//  AgentRelay
//
//  Created for Relay 语音手表控制页面 (Native iOS UI)
//  纯 UIKit 视图，无业务推导与副作用，通过 configure(state:) 单向渲染，动作通过闭包外发。
//

import UIKit

// MARK: - 展示状态模型 (View State)

/// 仪表盘展示状态（单向驱动 UI 渲染，所有数据与文案由调用方明确传入）
public struct WatchDashboardViewState: Equatable {

    // MARK: 1. 设备基本信息
    /// 设备友好名称，例如 "Relay 语音手表"、"ESP32-S3 Watch"
    public var deviceName: String
    /// 硬件/链路副标题，例如 "ESP32-S3 BLE · 原生音频链路"
    public var deviceSubtitle: String?

    // MARK: 2. 连接状态 (主区域)
    /// 状态主标题，例如 "已连接"、"未连接"、"正在重连..."
    public var statusTitle: String
    /// 状态详细描述，例如 "蓝牙低功耗链路正常 · 延迟 16ms"、"未发现已绑定的穿戴设备"
    public var statusDetail: String
    /// 连接状态视觉样式
    public var connectionState: ConnectionState

    public enum ConnectionState: String, Equatable {
        case connected       // 已连接 (绿灯)
        case connecting      // 正在连接/重连 (橙黄灯)
        case disconnected    // 未连接/已断链 (灰色)
        case error           // 异常或鉴权失败 (红灯)
    }

    // MARK: 3. 电量与充电状态 (主区域，诚实呈现，禁止伪造)
    /// 电量主文本，例如 "85%"、"电量未知"、"已断连"、"数据已过期"
    public var batteryText: String
    /// 电量详细说明，例如 "正在充电"、"断开连接，电量信息暂不可用"、"更新于 10:15 (已过期)"
    public var batteryDetail: String
    /// 是否正在充电
    public var isCharging: Bool
    /// 电量呈现样式等级（用于图标与色彩映射）
    public var batteryStatus: BatteryStatus

    public enum BatteryStatus: String, Equatable {
        case normal          // 正常读取到有效电量 (>=20%)
        case low             // 低电量 (<20%)
        case charging        // 充电中
        case unknown         // 未知（从未上报或硬件不支持）
        case stale           // 数据已过期（长时间未更新）
        case disconnected    // 设备断连（不可用）
    }

    // MARK: 4. 真实录音状态与时长 (主区域)
    /// 录音状态分类
    public var recordingState: RecordingState
    /// 录音状态主标题，例如 "空闲待命"、"正在录音..."、"录音已暂停 (草稿保留)"、"正在上传..."
    public var recordingTitle: String
    /// 录音详细信息，例如 "麦克风：ESP32 手表采音"、"按“发送本条”提交，或“结束当前对话”"
    public var recordingDetail: String
    /// 录音时长文本，例如 "00:00"、"00:42" (等宽字体展示)
    public var recordingTime: String
    /// 是否正处于开麦录音中
    public var isRecording: Bool
    /// 是否处于暂停草稿状态
    public var isPaused: Bool

    public enum RecordingState: String, Equatable {
        case idle            // 空闲待命
        case recording       // 正在录音
        case pausedDraft     // 录音已暂停，草稿已封口保留
        case transmitting    // 正在发送/上报
    }

    // MARK: 5. 待发箱状态 (主区域)
    /// 待发送文件数量
    public var pendingCount: Int
    /// 待发状态主文本，例如 "全部已同步"、"2 条录音等待发送"
    public var pendingText: String
    /// 待发详细信息，例如 "网络离线，录音已保存在本地，将在恢复连接后补发"
    public var pendingDetail: String?

    // MARK: 6. 按钮与操作配置 (次区域)
    /// 主操作按钮配置 (开始说话 / 发送本条(保留会话) / 继续说话)
    public var primaryButton: ButtonConfig
    /// 暂停/继续操作按钮配置
    public var pauseResumeButton: ButtonConfig
    /// 结束当前对话按钮配置 (明确区分于“发送本条”)
    public var endConversationButton: ButtonConfig
    /// 配对/重连设备按钮配置
    public var reconnectButton: ButtonConfig
    /// 待发箱入口配置
    public var outboxButton: ButtonConfig
    /// 诊断入口配置
    public var diagnosticsButton: ButtonConfig

    /// 底部操作提示或硬件按键说明文案
    public var tipsText: String?

    // MARK: - 按钮配置数据结构
    public struct ButtonConfig: Equatable {
        public var title: String
        public var isEnabled: Bool
        public var isHidden: Bool

        public init(title: String, isEnabled: Bool = true, isHidden: Bool = false) {
            self.title = title
            self.isEnabled = isEnabled
            self.isHidden = isHidden
        }
    }

    // MARK: - 便捷字典映射 (供调用方批量校验或动态读取)
    public var buttonTitles: [String: String] {
        return [
            "primary": primaryButton.title,
            "pauseResume": pauseResumeButton.title,
            "endConversation": endConversationButton.title,
            "reconnect": reconnectButton.title,
            "outbox": outboxButton.title,
            "diagnostics": diagnosticsButton.title
        ]
    }

    public var buttonEnabled: [String: Bool] {
        return [
            "primary": primaryButton.isEnabled,
            "pauseResume": pauseResumeButton.isEnabled,
            "endConversation": endConversationButton.isEnabled,
            "reconnect": reconnectButton.isEnabled,
            "outbox": outboxButton.isEnabled,
            "diagnostics": diagnosticsButton.isEnabled
        ]
    }

    // MARK: - 全量初始化
    public init(
        deviceName: String = "Relay 语音手表",
        deviceSubtitle: String? = "按键控制 · 手机录音",
        statusTitle: String = "未连接",
        statusDetail: String = "等待设备连接",
        connectionState: ConnectionState = .disconnected,
        batteryText: String = "电量未知",
        batteryDetail: String = "等待手表数据",
        isCharging: Bool = false,
        batteryStatus: BatteryStatus = .unknown,
        recordingState: RecordingState = .idle,
        recordingTitle: String = "空闲待命",
        recordingDetail: String = "麦克风就绪，长按手表 BOOT 或点击下方按钮开始",
        recordingTime: String = "--:--",
        isRecording: Bool = false,
        isPaused: Bool = false,
        pendingCount: Int = 0,
        pendingText: String = "待发箱已清空",
        pendingDetail: String? = "全部录音均已成功送出",
        primaryButton: ButtonConfig = ButtonConfig(title: "开始说话", isEnabled: false),
        pauseResumeButton: ButtonConfig = ButtonConfig(title: "暂停录音", isEnabled: false),
        endConversationButton: ButtonConfig = ButtonConfig(title: "结束当前对话", isEnabled: false),
        reconnectButton: ButtonConfig = ButtonConfig(title: "配对 / 重连设备", isEnabled: true),
        outboxButton: ButtonConfig = ButtonConfig(title: "录音待发箱", isEnabled: true),
        diagnosticsButton: ButtonConfig = ButtonConfig(title: "穿戴设备高级诊断", isEnabled: true),
        tipsText: String? = "BOOT 长按：开始 / 发送本条；短按：暂停 / 继续。\nPWR 长按：发送并结束当前对话。"
    ) {
        self.deviceName = deviceName
        self.deviceSubtitle = deviceSubtitle
        self.statusTitle = statusTitle
        self.statusDetail = statusDetail
        self.connectionState = connectionState
        self.batteryText = batteryText
        self.batteryDetail = batteryDetail
        self.isCharging = isCharging
        self.batteryStatus = batteryStatus
        self.recordingState = recordingState
        self.recordingTitle = recordingTitle
        self.recordingDetail = recordingDetail
        self.recordingTime = recordingTime
        self.isRecording = isRecording
        self.isPaused = isPaused
        self.pendingCount = pendingCount
        self.pendingText = pendingText
        self.pendingDetail = pendingDetail
        self.primaryButton = primaryButton
        self.pauseResumeButton = pauseResumeButton
        self.endConversationButton = endConversationButton
        self.reconnectButton = reconnectButton
        self.outboxButton = outboxButton
        self.diagnosticsButton = diagnosticsButton
        self.tipsText = tipsText
    }
}

// MARK: - 语义动作枚举 (Semantic Actions)

/// 仪表盘向外部调发出的语义动作（供 Codex 接线至 WearableService / WatchVoiceSession / BLEProbe）
public enum WatchDashboardAction: Equatable {
    /// 触发配对或重连设备
    case reconnectOrAddDevice
    /// 主录音操作 (根据当前状态对应：开始说话 / 发送本条保留会话)
    case primaryAction
    /// 暂停或继续当前录音草稿
    case pauseResumeRecording
    /// 明确结束当前会话 (归档并关闭逻辑对话)
    case endConversation
    /// 打开录音待发箱与离线文件恢复
    case openOutbox
    /// 打开穿戴设备高级诊断页面 (DeviceDiagnosticsViewController)
    case openDiagnostics
}

// MARK: - 仪表盘视图主类 (WatchDashboardView)

/// 纯 UIKit 编写的 Relay 手表控制面板
/// 支持暗色模式、动态字体、VoiceOver 无障碍及全面屏/小屏安全区
public final class WatchDashboardView: UIView {

    // MARK: - 外部动作闭包

    /// 综合语义事件回调（推荐调用方接入）
    public var onAction: ((WatchDashboardAction) -> Void)?

    /// 独立语义动作闭包（可选接入）
    public var onReconnectOrAddDevice: (() -> Void)?
    public var onPrimaryAction: (() -> Void)?
    public var onPauseResumeRecording: (() -> Void)?
    public var onEndConversation: (() -> Void)?
    public var onOpenOutbox: (() -> Void)?
    public var onOpenDiagnostics: (() -> Void)?

    // MARK: - 私有 UI 组件

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let contentStack = UIStackView()

    // 顶部设备信息卡片
    private let deviceHeaderCard = UIView()
    private let deviceIconImageView = UIImageView()
    private let deviceNameLabel = UILabel()
    private let deviceSubtitleLabel = UILabel()
    private let quickReconnectButton = UIButton(type: .system)

    // 主区域 1：连接与电量卡片
    private let statusCard = UIView()
    private let connectionIndicatorDot = UIView()
    private let statusTitleLabel = UILabel()
    private let statusDetailLabel = UILabel()
    private let statusCardDivider = UIView()
    private let batteryIconImageView = UIImageView()
    private let batteryTitleLabel = UILabel()
    private let batteryDetailLabel = UILabel()
    private let batteryBadgeLabel = UILabel()

    // 主区域 2：真实录音状态与计时器卡片
    private let recordingCard = UIView()
    private let recordingPillBadge = UIView()
    private let recordingPillDot = UIView()
    private let recordingPillLabel = UILabel()
    private let recordingTimeLabel = UILabel()
    private let recordingDetailLabel = UILabel()
    private let waveformContainer = UIStackView()
    private var waveformBars: [UIView] = []

    // 主区域 3：待发箱概览卡片
    private let outboxCard = UIView()
    private let outboxIconImageView = UIImageView()
    private let outboxTitleLabel = UILabel()
    private let outboxBadgeLabel = UILabel()
    private let outboxDetailLabel = UILabel()
    private let outboxChevronImageView = UIImageView()

    // 次区域：对话操作卡片
    private let conversationControlsCard = UIView()
    private let conversationSectionHeader = UILabel()
    private let primaryActionButton = UIButton(type: .system)
    private let secondaryActionsStack = UIStackView()
    private let pauseResumeButton = UIButton(type: .system)
    private let endConversationButton = UIButton(type: .system)
    private let conversationHintLabel = UILabel()

    // 次区域：设备管理与诊断入口卡片
    private let toolsCard = UIView()
    private let toolsSectionHeader = UILabel()
    private let reconnectRowButton = ActionRowButton()
    private let outboxRowButton = ActionRowButton()
    private let diagnosticsRowButton = ActionRowButton()

    // 底部硬件手势提示卡片
    private let tipsCard = UIView()
    private let tipsIconImageView = UIImageView()
    private let tipsTitleLabel = UILabel()
    private let tipsContentLabel = UILabel()

    // 当前渲染状态备份
    private var currentState: WatchDashboardViewState?

    // MARK: - 初始化

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        setupConstraints()
        setupActions()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
        setupConstraints()
        setupActions()
    }

    // MARK: - 单向状态渲染 (configure)

    /// 将状态结构体单向绑定至界面组件
    public func configure(state: WatchDashboardViewState) {
        self.currentState = state

        // 1. 设备基本信息
        deviceNameLabel.text = state.deviceName
        deviceSubtitleLabel.text = state.deviceSubtitle ?? " "
        deviceSubtitleLabel.isHidden = (state.deviceSubtitle == nil)

        // 2. 连接状态
        statusTitleLabel.text = state.statusTitle
        statusDetailLabel.text = state.statusDetail
        updateConnectionStateUI(state.connectionState)

        // 3. 诚实电量与充电呈现
        batteryTitleLabel.text = state.batteryText
        batteryDetailLabel.text = state.batteryDetail
        updateBatteryStateUI(status: state.batteryStatus, isCharging: state.isCharging, text: state.batteryText)

        // 4. 录音状态与计时
        recordingTimeLabel.text = state.recordingTime
        recordingDetailLabel.text = state.recordingDetail
        updateRecordingStateUI(state: state.recordingState, isRecording: state.isRecording, isPaused: state.isPaused, title: state.recordingTitle)

        // 5. 待发箱状态
        outboxTitleLabel.text = state.pendingText
        if let detail = state.pendingDetail, !detail.isEmpty {
            outboxDetailLabel.text = detail
            outboxDetailLabel.isHidden = false
        } else {
            outboxDetailLabel.isHidden = true
        }
        if state.pendingCount > 0 {
            outboxBadgeLabel.text = "\(state.pendingCount) 条待发"
            outboxBadgeLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.18)
            outboxBadgeLabel.textColor = .systemOrange
            outboxBadgeLabel.isHidden = false
        } else {
            outboxBadgeLabel.text = "暂无待发"
            outboxBadgeLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
            outboxBadgeLabel.textColor = .systemGreen
            outboxBadgeLabel.isHidden = false
        }

        // 6. 按钮配置更新
        // 主操作按钮
        primaryActionButton.setTitle(state.primaryButton.title, for: .normal)
        primaryActionButton.isEnabled = state.primaryButton.isEnabled
        primaryActionButton.isHidden = state.primaryButton.isHidden
        updatePrimaryActionButtonStyle(isRecording: state.isRecording, isPaused: state.isPaused)

        // 暂停 / 继续按钮
        pauseResumeButton.setTitle(state.pauseResumeButton.title, for: .normal)
        pauseResumeButton.isEnabled = state.pauseResumeButton.isEnabled
        pauseResumeButton.isHidden = state.pauseResumeButton.isHidden

        // 结束对话按钮
        endConversationButton.setTitle(state.endConversationButton.title, for: .normal)
        endConversationButton.isEnabled = state.endConversationButton.isEnabled
        endConversationButton.isHidden = state.endConversationButton.isHidden

        // 次区域行按钮配置
        reconnectRowButton.titleLabel.text = state.reconnectButton.title
        reconnectRowButton.isEnabled = state.reconnectButton.isEnabled
        reconnectRowButton.isHidden = state.reconnectButton.isHidden
        quickReconnectButton.isEnabled = state.reconnectButton.isEnabled

        outboxRowButton.titleLabel.text = state.outboxButton.title
        outboxRowButton.isEnabled = state.outboxButton.isEnabled
        outboxRowButton.isHidden = state.outboxButton.isHidden
        if state.pendingCount > 0 {
            outboxRowButton.badgeLabel.text = "\(state.pendingCount)"
            outboxRowButton.badgeLabel.isHidden = false
        } else {
            outboxRowButton.badgeLabel.isHidden = true
        }

        diagnosticsRowButton.titleLabel.text = state.diagnosticsButton.title
        diagnosticsRowButton.isEnabled = state.diagnosticsButton.isEnabled
        diagnosticsRowButton.isHidden = state.diagnosticsButton.isHidden

        // 7. 提示文案
        if let tips = state.tipsText, !tips.isEmpty {
            tipsContentLabel.text = tips
            tipsCard.isHidden = false
        } else {
            tipsCard.isHidden = true
        }

        // 8. 辅助功能无障碍属性刷新
        updateAccessibilityProperties(state: state)
    }

    // MARK: - 内部视觉辅助渲染

    private func updateConnectionStateUI(_ state: WatchDashboardViewState.ConnectionState) {
        switch state {
        case .connected:
            connectionIndicatorDot.backgroundColor = .systemGreen
            statusTitleLabel.textColor = .label
        case .connecting:
            connectionIndicatorDot.backgroundColor = .systemOrange
            statusTitleLabel.textColor = .systemOrange
        case .disconnected:
            connectionIndicatorDot.backgroundColor = .systemGray
            statusTitleLabel.textColor = .secondaryLabel
        case .error:
            connectionIndicatorDot.backgroundColor = .systemRed
            statusTitleLabel.textColor = .systemRed
        }
    }

    private func updateBatteryStateUI(status: WatchDashboardViewState.BatteryStatus, isCharging: Bool, text: String) {
        if isCharging {
            batteryIconImageView.image = UIImage(systemName: "battery.100.bolt")
            batteryIconImageView.tintColor = .systemGreen
            batteryBadgeLabel.text = "充电中"
            batteryBadgeLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
            batteryBadgeLabel.textColor = .systemGreen
            batteryBadgeLabel.isHidden = false
            return
        }

        switch status {
        case .charging:
            batteryIconImageView.image = UIImage(systemName: "battery.100.bolt")
            batteryIconImageView.tintColor = .systemGreen
            batteryBadgeLabel.text = "充电中"
            batteryBadgeLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
            batteryBadgeLabel.textColor = .systemGreen
            batteryBadgeLabel.isHidden = false

        case .normal:
            batteryIconImageView.image = UIImage(systemName: "battery.75")
            batteryIconImageView.tintColor = .systemGreen
            batteryBadgeLabel.text = "正常"
            batteryBadgeLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
            batteryBadgeLabel.textColor = .systemGreen
            batteryBadgeLabel.isHidden = false

        case .low:
            batteryIconImageView.image = UIImage(systemName: "battery.25")
            batteryIconImageView.tintColor = .systemRed
            batteryBadgeLabel.text = "低电量"
            batteryBadgeLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.15)
            batteryBadgeLabel.textColor = .systemRed
            batteryBadgeLabel.isHidden = false

        case .stale:
            batteryIconImageView.image = UIImage(systemName: "clock.badge.exclamationmark")
            batteryIconImageView.tintColor = .systemOrange
            batteryBadgeLabel.text = "数据已过期"
            batteryBadgeLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.15)
            batteryBadgeLabel.textColor = .systemOrange
            batteryBadgeLabel.isHidden = false

        case .unknown:
            batteryIconImageView.image = UIImage(systemName: "questionmark.circle")
            batteryIconImageView.tintColor = .systemGray
            batteryBadgeLabel.text = "电量未知"
            batteryBadgeLabel.backgroundColor = UIColor.systemGray.withAlphaComponent(0.15)
            batteryBadgeLabel.textColor = .secondaryLabel
            batteryBadgeLabel.isHidden = false

        case .disconnected:
            batteryIconImageView.image = UIImage(systemName: "battery.slash")
            batteryIconImageView.tintColor = .systemGray
            batteryBadgeLabel.text = "未连接"
            batteryBadgeLabel.backgroundColor = UIColor.systemGray.withAlphaComponent(0.15)
            batteryBadgeLabel.textColor = .secondaryLabel
            batteryBadgeLabel.isHidden = false
        }
    }

    private func updateRecordingStateUI(
        state: WatchDashboardViewState.RecordingState,
        isRecording: Bool,
        isPaused: Bool,
        title: String
    ) {
        recordingPillLabel.text = title

        switch state {
        case .recording:
            recordingPillBadge.backgroundColor = UIColor.systemRed.withAlphaComponent(0.15)
            recordingPillLabel.textColor = .systemRed
            recordingPillDot.backgroundColor = .systemRed
            recordingTimeLabel.textColor = .label
            setWaveformActive(true)

        case .pausedDraft:
            recordingPillBadge.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.15)
            recordingPillLabel.textColor = .systemOrange
            recordingPillDot.backgroundColor = .systemOrange
            recordingTimeLabel.textColor = .systemOrange
            setWaveformActive(false)

        case .transmitting:
            recordingPillBadge.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
            recordingPillLabel.textColor = .systemBlue
            recordingPillDot.backgroundColor = .systemBlue
            recordingTimeLabel.textColor = .secondaryLabel
            setWaveformActive(false)

        case .idle:
            recordingPillBadge.backgroundColor = UIColor.secondarySystemFill
            recordingPillLabel.textColor = .secondaryLabel
            recordingPillDot.backgroundColor = .systemGray
            recordingTimeLabel.textColor = .secondaryLabel
            setWaveformActive(false)
        }
    }

    private func updatePrimaryActionButtonStyle(isRecording: Bool, isPaused: Bool) {
        if isRecording {
            primaryActionButton.backgroundColor = .systemGreen
            primaryActionButton.setTitleColor(.white, for: .normal)
            primaryActionButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        } else if isPaused {
            primaryActionButton.backgroundColor = .systemBlue
            primaryActionButton.setTitleColor(.white, for: .normal)
            primaryActionButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        } else {
            primaryActionButton.backgroundColor = .systemBlue
            primaryActionButton.setTitleColor(.white, for: .normal)
            primaryActionButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        }
        primaryActionButton.tintColor = .white
    }

    private func setWaveformActive(_ active: Bool) {
        let heights: [CGFloat] = active ? [14, 26, 32, 20, 10] : [6, 6, 6, 6, 6]
        for (index, bar) in waveformBars.enumerated() {
            guard index < heights.count else { break }
            UIView.animate(withDuration: 0.25) {
                bar.constraints.first { $0.firstAttribute == .height }?.constant = heights[index]
                bar.backgroundColor = active ? .systemRed : .tertiaryLabel
            }
        }
    }

    // MARK: - 无障碍 VoiceOver

    private func updateAccessibilityProperties(state: WatchDashboardViewState) {
        // 设备卡片
        deviceHeaderCard.isAccessibilityElement = true
        deviceHeaderCard.accessibilityLabel = "\(state.deviceName)，\(state.deviceSubtitle ?? "")"
        deviceHeaderCard.accessibilityTraits = .header

        // 状态卡片
        statusCard.isAccessibilityElement = true
        statusCard.accessibilityLabel = "设备连接状态：\(state.statusTitle)，\(state.statusDetail)。当前电量：\(state.batteryText)，\(state.batteryDetail)"

        // 录音卡片
        recordingCard.isAccessibilityElement = true
        recordingCard.accessibilityLabel = "录音状态：\(state.recordingTitle)，录音时长：\(state.recordingTime)，\(state.recordingDetail)"

        // 待发箱卡片
        outboxCard.isAccessibilityElement = true
        outboxCard.accessibilityLabel = "待发箱：\(state.pendingText)，\(state.pendingCount) 条待发。\(state.pendingDetail ?? "")"
        outboxCard.accessibilityHint = "轻点两下打开待发箱与恢复"
        outboxCard.accessibilityTraits = .button

        // 按钮 hints
        primaryActionButton.accessibilityHint = state.isRecording ? "发送当前录音切片并保留对话会话" : "开启麦克风录制语音"
        pauseResumeButton.accessibilityHint = state.isRecording ? "暂停当前录音并封口草稿" : "继续未完成的录音草稿"
        endConversationButton.accessibilityHint = "结束并归档当前整轮逻辑对话"
    }

    // MARK: - UI 构建与排版

    private func setupViews() {
        backgroundColor = .systemGroupedBackground

        // 滚动容器支持小屏和动态字体
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .fill
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentStack)

        buildDeviceHeaderCard()
        buildStatusCard()
        buildRecordingCard()
        buildOutboxCard()
        buildConversationControlsCard()
        buildToolsCard()
        buildTipsCard()

        contentStack.addArrangedSubview(deviceHeaderCard)
        contentStack.addArrangedSubview(statusCard)
        contentStack.addArrangedSubview(recordingCard)
        contentStack.addArrangedSubview(outboxCard)
        contentStack.addArrangedSubview(conversationControlsCard)
        contentStack.addArrangedSubview(toolsCard)
        contentStack.addArrangedSubview(tipsCard)
    }

    private func buildDeviceHeaderCard() {
        styleCard(deviceHeaderCard)

        deviceIconImageView.image = UIImage(systemName: "applewatch.radiowaves.left.and.right")
        deviceIconImageView.tintColor = .systemBlue
        deviceIconImageView.contentMode = .scaleAspectFit
        deviceIconImageView.translatesAutoresizingMaskIntoConstraints = false

        deviceNameLabel.font = .preferredFont(forTextStyle: .title2)
        deviceNameLabel.adjustsFontForContentSizeCategory = true
        deviceNameLabel.textColor = .label
        deviceNameLabel.numberOfLines = 1
        deviceNameLabel.translatesAutoresizingMaskIntoConstraints = false

        deviceSubtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        deviceSubtitleLabel.adjustsFontForContentSizeCategory = true
        deviceSubtitleLabel.textColor = .secondaryLabel
        deviceSubtitleLabel.numberOfLines = 0
        deviceSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        quickReconnectButton.setTitle("重连设备", for: .normal)
        quickReconnectButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        quickReconnectButton.titleLabel?.adjustsFontForContentSizeCategory = true
        quickReconnectButton.backgroundColor = .secondarySystemFill
        quickReconnectButton.layer.cornerRadius = 14
        quickReconnectButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        quickReconnectButton.translatesAutoresizingMaskIntoConstraints = false

        let labelStack = UIStackView(arrangedSubviews: [deviceNameLabel, deviceSubtitleLabel])
        labelStack.axis = .vertical
        labelStack.spacing = 2
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        deviceHeaderCard.addSubview(deviceIconImageView)
        deviceHeaderCard.addSubview(labelStack)
        deviceHeaderCard.addSubview(quickReconnectButton)

        NSLayoutConstraint.activate([
            deviceIconImageView.leadingAnchor.constraint(equalTo: deviceHeaderCard.leadingAnchor, constant: 16),
            deviceIconImageView.centerYAnchor.constraint(equalTo: deviceHeaderCard.centerYAnchor),
            deviceIconImageView.widthAnchor.constraint(equalToConstant: 36),
            deviceIconImageView.heightAnchor.constraint(equalToConstant: 36),

            labelStack.leadingAnchor.constraint(equalTo: deviceIconImageView.trailingAnchor, constant: 12),
            labelStack.topAnchor.constraint(equalTo: deviceHeaderCard.topAnchor, constant: 14),
            labelStack.bottomAnchor.constraint(equalTo: deviceHeaderCard.bottomAnchor, constant: -14),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: quickReconnectButton.leadingAnchor, constant: -8),

            quickReconnectButton.trailingAnchor.constraint(equalTo: deviceHeaderCard.trailingAnchor, constant: -16),
            quickReconnectButton.centerYAnchor.constraint(equalTo: deviceHeaderCard.centerYAnchor),
            quickReconnectButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func buildStatusCard() {
        styleCard(statusCard)

        // 连接状态行
        connectionIndicatorDot.layer.cornerRadius = 5
        connectionIndicatorDot.clipsToBounds = true
        connectionIndicatorDot.backgroundColor = .systemGreen
        connectionIndicatorDot.translatesAutoresizingMaskIntoConstraints = false

        statusTitleLabel.font = .preferredFont(forTextStyle: .headline)
        statusTitleLabel.adjustsFontForContentSizeCategory = true
        statusTitleLabel.textColor = .label
        statusTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusDetailLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusDetailLabel.adjustsFontForContentSizeCategory = true
        statusDetailLabel.textColor = .secondaryLabel
        statusDetailLabel.numberOfLines = 0
        statusDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let connectionTitleStack = UIStackView(arrangedSubviews: [connectionIndicatorDot, statusTitleLabel])
        connectionTitleStack.axis = .horizontal
        connectionTitleStack.spacing = 8
        connectionTitleStack.alignment = .center
        connectionTitleStack.translatesAutoresizingMaskIntoConstraints = false

        let connectionStack = UIStackView(arrangedSubviews: [connectionTitleStack, statusDetailLabel])
        connectionStack.axis = .vertical
        connectionStack.spacing = 4
        connectionStack.translatesAutoresizingMaskIntoConstraints = false

        // 分隔线
        statusCardDivider.backgroundColor = .separator
        statusCardDivider.translatesAutoresizingMaskIntoConstraints = false

        // 电量行
        batteryIconImageView.image = UIImage(systemName: "battery.75")
        batteryIconImageView.tintColor = .systemGreen
        batteryIconImageView.contentMode = .scaleAspectFit
        batteryIconImageView.translatesAutoresizingMaskIntoConstraints = false

        batteryTitleLabel.font = .preferredFont(forTextStyle: .headline)
        batteryTitleLabel.adjustsFontForContentSizeCategory = true
        batteryTitleLabel.textColor = .label
        batteryTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        batteryBadgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        batteryBadgeLabel.layer.cornerRadius = 6
        batteryBadgeLabel.clipsToBounds = true
        batteryBadgeLabel.textAlignment = .center
        batteryBadgeLabel.translatesAutoresizingMaskIntoConstraints = false

        let batteryHeaderStack = UIStackView(arrangedSubviews: [batteryIconImageView, batteryTitleLabel, batteryBadgeLabel])
        batteryHeaderStack.axis = .horizontal
        batteryHeaderStack.spacing = 8
        batteryHeaderStack.alignment = .center
        batteryHeaderStack.translatesAutoresizingMaskIntoConstraints = false

        batteryDetailLabel.font = .preferredFont(forTextStyle: .subheadline)
        batteryDetailLabel.adjustsFontForContentSizeCategory = true
        batteryDetailLabel.textColor = .secondaryLabel
        batteryDetailLabel.numberOfLines = 0
        batteryDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let batteryStack = UIStackView(arrangedSubviews: [batteryHeaderStack, batteryDetailLabel])
        batteryStack.axis = .vertical
        batteryStack.spacing = 4
        batteryStack.translatesAutoresizingMaskIntoConstraints = false

        statusCard.addSubview(connectionStack)
        statusCard.addSubview(statusCardDivider)
        statusCard.addSubview(batteryStack)

        NSLayoutConstraint.activate([
            connectionIndicatorDot.widthAnchor.constraint(equalToConstant: 10),
            connectionIndicatorDot.heightAnchor.constraint(equalToConstant: 10),

            connectionStack.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 14),
            connectionStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            connectionStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),

            statusCardDivider.topAnchor.constraint(equalTo: connectionStack.bottomAnchor, constant: 12),
            statusCardDivider.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            statusCardDivider.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            statusCardDivider.heightAnchor.constraint(equalToConstant: 0.5),

            batteryIconImageView.widthAnchor.constraint(equalToConstant: 24),
            batteryIconImageView.heightAnchor.constraint(equalToConstant: 16),

            batteryBadgeLabel.heightAnchor.constraint(equalToConstant: 18),
            batteryBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            batteryStack.topAnchor.constraint(equalTo: statusCardDivider.bottomAnchor, constant: 12),
            batteryStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 16),
            batteryStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -16),
            batteryStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -14)
        ])
    }

    private func buildRecordingCard() {
        styleCard(recordingCard)

        // 录音状态胶囊指示牌
        recordingPillBadge.layer.cornerRadius = 11
        recordingPillBadge.clipsToBounds = true
        recordingPillBadge.backgroundColor = UIColor.secondarySystemFill
        recordingPillBadge.translatesAutoresizingMaskIntoConstraints = false

        recordingPillDot.layer.cornerRadius = 4
        recordingPillDot.clipsToBounds = true
        recordingPillDot.backgroundColor = .systemGray
        recordingPillDot.translatesAutoresizingMaskIntoConstraints = false

        recordingPillLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        recordingPillLabel.text = "空闲待命"
        recordingPillLabel.textColor = .secondaryLabel
        recordingPillLabel.translatesAutoresizingMaskIntoConstraints = false

        let pillContentStack = UIStackView(arrangedSubviews: [recordingPillDot, recordingPillLabel])
        pillContentStack.axis = .horizontal
        pillContentStack.spacing = 6
        pillContentStack.alignment = .center
        pillContentStack.translatesAutoresizingMaskIntoConstraints = false

        recordingPillBadge.addSubview(pillContentStack)

        // 录音时长等宽大字号展示
        recordingTimeLabel.font = .monospacedDigitSystemFont(ofSize: 38, weight: .bold)
        recordingTimeLabel.adjustsFontForContentSizeCategory = true
        recordingTimeLabel.textColor = .secondaryLabel
        recordingTimeLabel.text = "00:00"
        recordingTimeLabel.translatesAutoresizingMaskIntoConstraints = false

        // 声波模拟指示器 (静态结构，动态伸缩高度)
        waveformContainer.axis = .horizontal
        waveformContainer.spacing = 4
        waveformContainer.alignment = .center
        waveformContainer.distribution = .fillEqually
        waveformContainer.translatesAutoresizingMaskIntoConstraints = false

        waveformBars.removeAll()
        for _ in 0..<5 {
            let bar = UIView()
            bar.layer.cornerRadius = 2
            bar.clipsToBounds = true
            bar.backgroundColor = .tertiaryLabel
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            bar.widthAnchor.constraint(equalToConstant: 4).isActive = true
            waveformContainer.addArrangedSubview(bar)
            waveformBars.append(bar)
        }

        let timerAndWaveformStack = UIStackView(arrangedSubviews: [recordingTimeLabel, waveformContainer])
        timerAndWaveformStack.axis = .horizontal
        timerAndWaveformStack.spacing = 16
        timerAndWaveformStack.alignment = .center
        timerAndWaveformStack.translatesAutoresizingMaskIntoConstraints = false

        // 录音详细信息文案
        recordingDetailLabel.font = .preferredFont(forTextStyle: .subheadline)
        recordingDetailLabel.adjustsFontForContentSizeCategory = true
        recordingDetailLabel.textColor = .secondaryLabel
        recordingDetailLabel.numberOfLines = 0
        recordingDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        recordingCard.addSubview(recordingPillBadge)
        recordingCard.addSubview(timerAndWaveformStack)
        recordingCard.addSubview(recordingDetailLabel)

        NSLayoutConstraint.activate([
            pillContentStack.topAnchor.constraint(equalTo: recordingPillBadge.topAnchor, constant: 3),
            pillContentStack.bottomAnchor.constraint(equalTo: recordingPillBadge.bottomAnchor, constant: -3),
            pillContentStack.leadingAnchor.constraint(equalTo: recordingPillBadge.leadingAnchor, constant: 8),
            pillContentStack.trailingAnchor.constraint(equalTo: recordingPillBadge.trailingAnchor, constant: -8),
            recordingPillDot.widthAnchor.constraint(equalToConstant: 8),
            recordingPillDot.heightAnchor.constraint(equalToConstant: 8),

            recordingPillBadge.topAnchor.constraint(equalTo: recordingCard.topAnchor, constant: 14),
            recordingPillBadge.leadingAnchor.constraint(equalTo: recordingCard.leadingAnchor, constant: 16),

            timerAndWaveformStack.topAnchor.constraint(equalTo: recordingPillBadge.bottomAnchor, constant: 8),
            timerAndWaveformStack.leadingAnchor.constraint(equalTo: recordingCard.leadingAnchor, constant: 16),
            timerAndWaveformStack.trailingAnchor.constraint(lessThanOrEqualTo: recordingCard.trailingAnchor, constant: -16),

            recordingDetailLabel.topAnchor.constraint(equalTo: timerAndWaveformStack.bottomAnchor, constant: 6),
            recordingDetailLabel.leadingAnchor.constraint(equalTo: recordingCard.leadingAnchor, constant: 16),
            recordingDetailLabel.trailingAnchor.constraint(equalTo: recordingCard.trailingAnchor, constant: -16),
            recordingDetailLabel.bottomAnchor.constraint(equalTo: recordingCard.bottomAnchor, constant: -14)
        ])
    }

    private func buildOutboxCard() {
        styleCard(outboxCard)

        outboxIconImageView.image = UIImage(systemName: "tray.full.fill")
        outboxIconImageView.tintColor = .systemBlue
        outboxIconImageView.contentMode = .scaleAspectFit
        outboxIconImageView.translatesAutoresizingMaskIntoConstraints = false

        outboxTitleLabel.font = .preferredFont(forTextStyle: .headline)
        outboxTitleLabel.adjustsFontForContentSizeCategory = true
        outboxTitleLabel.textColor = .label
        outboxTitleLabel.numberOfLines = 1
        outboxTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        outboxBadgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        outboxBadgeLabel.layer.cornerRadius = 6
        outboxBadgeLabel.clipsToBounds = true
        outboxBadgeLabel.textAlignment = .center
        outboxBadgeLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleBadgeStack = UIStackView(arrangedSubviews: [outboxTitleLabel, outboxBadgeLabel])
        titleBadgeStack.axis = .horizontal
        titleBadgeStack.spacing = 8
        titleBadgeStack.alignment = .center
        titleBadgeStack.translatesAutoresizingMaskIntoConstraints = false

        outboxDetailLabel.font = .preferredFont(forTextStyle: .subheadline)
        outboxDetailLabel.adjustsFontForContentSizeCategory = true
        outboxDetailLabel.textColor = .secondaryLabel
        outboxDetailLabel.numberOfLines = 0
        outboxDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = UIStackView(arrangedSubviews: [titleBadgeStack, outboxDetailLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        outboxChevronImageView.image = UIImage(systemName: "chevron.right")
        outboxChevronImageView.tintColor = .tertiaryLabel
        outboxChevronImageView.contentMode = .scaleAspectFit
        outboxChevronImageView.translatesAutoresizingMaskIntoConstraints = false

        outboxCard.addSubview(outboxIconImageView)
        outboxCard.addSubview(textStack)
        outboxCard.addSubview(outboxChevronImageView)

        NSLayoutConstraint.activate([
            outboxIconImageView.leadingAnchor.constraint(equalTo: outboxCard.leadingAnchor, constant: 16),
            outboxIconImageView.centerYAnchor.constraint(equalTo: outboxCard.centerYAnchor),
            outboxIconImageView.widthAnchor.constraint(equalToConstant: 24),
            outboxIconImageView.heightAnchor.constraint(equalToConstant: 24),

            textStack.leadingAnchor.constraint(equalTo: outboxIconImageView.trailingAnchor, constant: 12),
            textStack.topAnchor.constraint(equalTo: outboxCard.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: outboxCard.bottomAnchor, constant: -12),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: outboxChevronImageView.leadingAnchor, constant: -8),

            outboxBadgeLabel.heightAnchor.constraint(equalToConstant: 18),
            outboxBadgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),

            outboxChevronImageView.trailingAnchor.constraint(equalTo: outboxCard.trailingAnchor, constant: -16),
            outboxChevronImageView.centerYAnchor.constraint(equalTo: outboxCard.centerYAnchor),
            outboxChevronImageView.widthAnchor.constraint(equalToConstant: 12),
            outboxChevronImageView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    private func buildConversationControlsCard() {
        styleCard(conversationControlsCard)

        conversationSectionHeader.text = "对话控制"
        conversationSectionHeader.font = .preferredFont(forTextStyle: .subheadline)
        conversationSectionHeader.adjustsFontForContentSizeCategory = true
        conversationSectionHeader.textColor = .secondaryLabel
        conversationSectionHeader.translatesAutoresizingMaskIntoConstraints = false

        // 主操作按钮（大按钮，全宽高度 52）
        primaryActionButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        primaryActionButton.titleLabel?.adjustsFontForContentSizeCategory = true
        primaryActionButton.backgroundColor = .systemBlue
        primaryActionButton.setTitleColor(.white, for: .normal)
        primaryActionButton.layer.cornerRadius = 16
        primaryActionButton.clipsToBounds = true
        primaryActionButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -8, bottom: 0, right: 8)
        primaryActionButton.translatesAutoresizingMaskIntoConstraints = false

        // 次级操作区（横向并列两按钮：暂停/继续，结束对话）
        secondaryActionsStack.axis = .vertical
        secondaryActionsStack.spacing = 10
        secondaryActionsStack.distribution = .fillEqually
        secondaryActionsStack.translatesAutoresizingMaskIntoConstraints = false

        pauseResumeButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        pauseResumeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        pauseResumeButton.backgroundColor = .secondarySystemFill
        pauseResumeButton.setTitleColor(.label, for: .normal)
        pauseResumeButton.layer.cornerRadius = 14
        pauseResumeButton.clipsToBounds = true
        pauseResumeButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        pauseResumeButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)
        pauseResumeButton.translatesAutoresizingMaskIntoConstraints = false

        endConversationButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        endConversationButton.titleLabel?.adjustsFontForContentSizeCategory = true
        endConversationButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        endConversationButton.setTitleColor(.systemRed, for: .normal)
        endConversationButton.layer.cornerRadius = 14
        endConversationButton.clipsToBounds = true
        endConversationButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        endConversationButton.tintColor = .systemRed
        endConversationButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)
        endConversationButton.translatesAutoresizingMaskIntoConstraints = false

        secondaryActionsStack.addArrangedSubview(pauseResumeButton)
        secondaryActionsStack.addArrangedSubview(endConversationButton)

        conversationHintLabel.text = "说明：『发送本条』保留上下文继续多轮对话；『结束当前对话』让下一条语音进入新对话。"
        conversationHintLabel.font = .preferredFont(forTextStyle: .footnote)
        conversationHintLabel.adjustsFontForContentSizeCategory = true
        conversationHintLabel.textColor = .secondaryLabel
        conversationHintLabel.textAlignment = .center
        conversationHintLabel.numberOfLines = 0
        conversationHintLabel.translatesAutoresizingMaskIntoConstraints = false

        let controlsStack = UIStackView(arrangedSubviews: [
            conversationSectionHeader,
            primaryActionButton,
            secondaryActionsStack,
            conversationHintLabel
        ])
        for button in [primaryActionButton, pauseResumeButton, endConversationButton] {
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.contentEdgeInsets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        }
        controlsStack.axis = .vertical
        controlsStack.spacing = 12
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        conversationControlsCard.addSubview(controlsStack)

        NSLayoutConstraint.activate([
            primaryActionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            pauseResumeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            endConversationButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            controlsStack.topAnchor.constraint(equalTo: conversationControlsCard.topAnchor, constant: 14),
            controlsStack.leadingAnchor.constraint(equalTo: conversationControlsCard.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: conversationControlsCard.trailingAnchor, constant: -16),
            controlsStack.bottomAnchor.constraint(equalTo: conversationControlsCard.bottomAnchor, constant: -14)
        ])
    }

    private func buildToolsCard() {
        styleCard(toolsCard)

        toolsSectionHeader.text = "设备与诊断"
        toolsSectionHeader.font = .preferredFont(forTextStyle: .subheadline)
        toolsSectionHeader.adjustsFontForContentSizeCategory = true
        toolsSectionHeader.textColor = .secondaryLabel
        toolsSectionHeader.translatesAutoresizingMaskIntoConstraints = false

        reconnectRowButton.configure(
            icon: UIImage(systemName: "antenna.radiowaves.left.and.right"),
            iconColor: .systemBlue,
            title: "配对 / 重连设备",
            subtitle: "搜索或切换已绑定的 ESP32 手表"
        )

        outboxRowButton.configure(
            icon: UIImage(systemName: "arrow.up.bin.fill"),
            iconColor: .systemOrange,
            title: "录音待发箱与恢复",
            subtitle: "网络恢复后续传或导出已保存的录音文件"
        )

        diagnosticsRowButton.configure(
            icon: UIImage(systemName: "wrench.and.screwdriver.fill"),
            iconColor: .systemGray,
            title: "穿戴设备高级诊断",
            subtitle: "打开原始诊断日志与底层蓝牙测试页"
        )

        let divider1 = UIView()
        divider1.backgroundColor = .separator
        divider1.translatesAutoresizingMaskIntoConstraints = false
        divider1.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        let divider2 = UIView()
        divider2.backgroundColor = .separator
        divider2.translatesAutoresizingMaskIntoConstraints = false
        divider2.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        let rowsStack = UIStackView(arrangedSubviews: [
            toolsSectionHeader,
            reconnectRowButton,
            divider1,
            outboxRowButton,
            divider2,
            diagnosticsRowButton
        ])
        rowsStack.axis = .vertical
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        toolsCard.addSubview(rowsStack)

        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: toolsCard.topAnchor, constant: 14),
            rowsStack.leadingAnchor.constraint(equalTo: toolsCard.leadingAnchor, constant: 16),
            rowsStack.trailingAnchor.constraint(equalTo: toolsCard.trailingAnchor, constant: -16),
            rowsStack.bottomAnchor.constraint(equalTo: toolsCard.bottomAnchor, constant: -14)
        ])
    }

    private func buildTipsCard() {
        tipsCard.backgroundColor = .secondarySystemGroupedBackground
        tipsCard.layer.cornerRadius = 14
        tipsCard.clipsToBounds = true
        tipsCard.translatesAutoresizingMaskIntoConstraints = false

        tipsIconImageView.image = UIImage(systemName: "hand.tap.fill")
        tipsIconImageView.tintColor = .systemBlue
        tipsIconImageView.contentMode = .scaleAspectFit
        tipsIconImageView.translatesAutoresizingMaskIntoConstraints = false

        tipsTitleLabel.text = "手表按键捷径"
        tipsTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        tipsTitleLabel.adjustsFontForContentSizeCategory = true
        tipsTitleLabel.textColor = .label
        tipsTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = UIStackView(arrangedSubviews: [tipsIconImageView, tipsTitleLabel])
        headerStack.axis = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .center
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        tipsContentLabel.font = .preferredFont(forTextStyle: .footnote)
        tipsContentLabel.adjustsFontForContentSizeCategory = true
        tipsContentLabel.textColor = .secondaryLabel
        tipsContentLabel.numberOfLines = 0
        tipsContentLabel.translatesAutoresizingMaskIntoConstraints = false

        let cardStack = UIStackView(arrangedSubviews: [headerStack, tipsContentLabel])
        cardStack.axis = .vertical
        cardStack.spacing = 6
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        tipsCard.addSubview(cardStack)

        NSLayoutConstraint.activate([
            tipsIconImageView.widthAnchor.constraint(equalToConstant: 16),
            tipsIconImageView.heightAnchor.constraint(equalToConstant: 16),

            cardStack.topAnchor.constraint(equalTo: tipsCard.topAnchor, constant: 12),
            cardStack.leadingAnchor.constraint(equalTo: tipsCard.leadingAnchor, constant: 14),
            cardStack.trailingAnchor.constraint(equalTo: tipsCard.trailingAnchor, constant: -14),
            cardStack.bottomAnchor.constraint(equalTo: tipsCard.bottomAnchor, constant: -12)
        ])
    }

    private func styleCard(_ card: UIView) {
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])
    }

    // MARK: - 事件绑定 (调用闭包，绝不实现业务逻辑)

    private func setupActions() {
        quickReconnectButton.addTarget(self, action: #selector(handleReconnectTapped), for: .touchUpInside)
        reconnectRowButton.addTarget(self, action: #selector(handleReconnectTapped), for: .touchUpInside)
        primaryActionButton.addTarget(self, action: #selector(handlePrimaryActionTapped), for: .touchUpInside)
        pauseResumeButton.addTarget(self, action: #selector(handlePauseResumeTapped), for: .touchUpInside)
        endConversationButton.addTarget(self, action: #selector(handleEndConversationTapped), for: .touchUpInside)
        outboxRowButton.addTarget(self, action: #selector(handleOutboxTapped), for: .touchUpInside)
        diagnosticsRowButton.addTarget(self, action: #selector(handleDiagnosticsTapped), for: .touchUpInside)

        let outboxTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleOutboxTapped))
        outboxCard.addGestureRecognizer(outboxTapGesture)
    }

    @objc private func handleReconnectTapped() {
        onAction?(.reconnectOrAddDevice)
        onReconnectOrAddDevice?()
    }

    @objc private func handlePrimaryActionTapped() {
        onAction?(.primaryAction)
        onPrimaryAction?()
    }

    @objc private func handlePauseResumeTapped() {
        onAction?(.pauseResumeRecording)
        onPauseResumeRecording?()
    }

    @objc private func handleEndConversationTapped() {
        onAction?(.endConversation)
        onEndConversation?()
    }

    @objc private func handleOutboxTapped() {
        onAction?(.openOutbox)
        onOpenOutbox?()
    }

    @objc private func handleDiagnosticsTapped() {
        onAction?(.openDiagnostics)
        onOpenDiagnostics?()
    }
}

// MARK: - 辅助子视图：次区域行式按钮 (ActionRowButton)

/// 具有原生 iOS 设置风格的行式操作入口
private final class ActionRowButton: UIControl {

    let iconImageView = UIImageView()
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    let badgeLabel = UILabel()
    let chevronImageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    func configure(icon: UIImage?, iconColor: UIColor, title: String, subtitle: String) {
        iconImageView.image = icon
        iconImageView.tintColor = iconColor
        titleLabel.text = title
        subtitleLabel.text = subtitle
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.6 : 1.0
        }
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true

        iconImageView.contentMode = .scaleAspectFit
        iconImageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = .systemOrange
        badgeLabel.layer.cornerRadius = 9
        badgeLabel.clipsToBounds = true
        badgeLabel.textAlignment = .center
        badgeLabel.isHidden = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        chevronImageView.image = UIImage(systemName: "chevron.right")
        chevronImageView.tintColor = .tertiaryLabel
        chevronImageView.contentMode = .scaleAspectFit
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false

        let labelStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labelStack.axis = .vertical
        labelStack.spacing = 2
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconImageView)
        addSubview(labelStack)
        addSubview(badgeLabel)
        addSubview(chevronImageView)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 24),
            iconImageView.heightAnchor.constraint(equalToConstant: 24),

            labelStack.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            labelStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            labelStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -8),

            badgeLabel.trailingAnchor.constraint(equalTo: chevronImageView.leadingAnchor, constant: -6),
            badgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.heightAnchor.constraint(equalToConstant: 18),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),

            chevronImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronImageView.widthAnchor.constraint(equalToConstant: 12),
            chevronImageView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }
}

// MARK: - 便捷宿主控制器 (WatchDashboardViewController)

/// 供 Codex 方便 present / push 的开箱即用宿主控制器
public final class WatchDashboardViewController: UIViewController {

    public let dashboardView = WatchDashboardView()

    public override func loadView() {
        self.view = dashboardView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "语音设备"
        navigationItem.largeTitleDisplayMode = .never

        // 默认提供关闭按钮（若处于模态弹出中）
        if presentingViewController != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(handleCloseTapped)
            )
        }
    }

    @objc private func handleCloseTapped() {
        dismiss(animated: true)
    }
}
