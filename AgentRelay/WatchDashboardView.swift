//
//  WatchDashboardView.swift
//  AgentRelay
//
//  Created for relay watch 控制页面 (Native iOS UI)
//  纯 UIKit 视图，无业务推导与副作用，通过 configure(state:) 单向渲染，动作通过 onAction 外发。
//

import UIKit

// MARK: - 展示状态模型 (View State)

/// 仪表盘展示状态（单向驱动 UI 渲染，所有数据与文案由调用方明确传入）
public struct WatchDashboardViewState: Equatable {

    // MARK: 1. 设备基本信息
    /// 设备友好名称，固定为 "relay watch"
    public var deviceName: String
    /// 硬件/链路副标题（技术说明如“按键控制/手机采音”已被规范剔除）
    public var deviceSubtitle: String?

    // MARK: 2. 连接状态
    /// 状态主标题，例如 "已连接"、"未连接"、"正在连接"
    public var statusTitle: String
    /// 状态详细说明 (仅真实错误/异常时展示)
    public var statusDetail: String
    /// 连接状态视觉等级
    public var connectionState: ConnectionState

    public enum ConnectionState: String, Equatable {
        case connected       // 已连接 (绿)
        case connecting      // 正在连接 (橙)
        case disconnected    // 未连接 (灰)
        case error           // 连接异常 (红)
    }

    // MARK: 3. 电量与充电状态 (诚实呈现，禁止伪造)
    /// 电量主文本，例如 "85%"、"电量未知"
    public var batteryText: String
    /// 电量详细说明，例如 "正在充电"、"数据已过期"
    public var batteryDetail: String
    /// 是否正在充电
    public var isCharging: Bool
    /// 电量呈现样式等级
    public var batteryStatus: BatteryStatus

    public enum BatteryStatus: String, Equatable {
        case normal          // 正常读取到有效电量 (>=20%)
        case low             // 低电量 (<20%)
        case charging        // 充电中
        case unknown         // 未知（从未上报或不可用）
        case stale           // 数据已过期
        case disconnected    // 设备断连
    }

    // MARK: 4. 录音状态与时长
    /// 录音状态分类
    public var recordingState: RecordingState
    /// 录音状态标题，例如 "空闲待命"、"正在录音"、"录音已暂停"
    public var recordingTitle: String
    /// 录音详细信息 (仅真实错误或关键信息时展示)
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
        case pausedDraft     // 录音已暂停
        case transmitting    // 正在发送
    }

    // MARK: 5. 待发箱状态
    /// 待发送文件数量
    public var pendingCount: Int
    /// 待发状态主文本
    public var pendingText: String
    /// 待发详细信息
    public var pendingDetail: String?

    // MARK: 6. 按钮与操作配置
    /// 主操作按钮配置 (开始录音 / 发送)
    public var primaryButton: ButtonConfig
    /// 暂停/继续操作按钮配置
    public var pauseResumeButton: ButtonConfig
    /// 结束当前对话按钮配置
    public var endConversationButton: ButtonConfig
    /// 设备切换/重连配置
    public var reconnectButton: ButtonConfig
    /// 待发箱入口配置
    public var outboxButton: ButtonConfig
    /// 诊断/设置入口配置
    public var diagnosticsButton: ButtonConfig

    /// 提示文案（保留兼容，UI中不展示教程说明）
    public var tipsText: String?

    /// 电量刷新中状态 (由 Codex 接入，驱动刷新图标动画与禁用)
    public var isRefreshingBattery: Bool

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

    // MARK: - 全量初始化 (首次默认：未连接、电量未知、操作禁用)
    public init(
        deviceName: String = "relay watch",
        deviceSubtitle: String? = nil,
        statusTitle: String = "未连接",
        statusDetail: String = "",
        connectionState: ConnectionState = .disconnected,
        batteryText: String = "电量未知",
        batteryDetail: String = "",
        isCharging: Bool = false,
        batteryStatus: BatteryStatus = .unknown,
        recordingState: RecordingState = .idle,
        recordingTitle: String = "空闲待命",
        recordingDetail: String = "",
        recordingTime: String = "--:--",
        isRecording: Bool = false,
        isPaused: Bool = false,
        pendingCount: Int = 0,
        pendingText: String = "",
        pendingDetail: String? = nil,
        primaryButton: ButtonConfig = ButtonConfig(title: "开始录音", isEnabled: false),
        pauseResumeButton: ButtonConfig = ButtonConfig(title: "暂停", isEnabled: false),
        endConversationButton: ButtonConfig = ButtonConfig(title: "结束对话", isEnabled: false),
        reconnectButton: ButtonConfig = ButtonConfig(title: "设备", isEnabled: false),
        outboxButton: ButtonConfig = ButtonConfig(title: "待发", isEnabled: false),
        diagnosticsButton: ButtonConfig = ButtonConfig(title: "设置", isEnabled: false),
        tipsText: String? = nil,
        isRefreshingBattery: Bool = false
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
        self.isRefreshingBattery = isRefreshingBattery
    }
}

// MARK: - 语义动作枚举 (Semantic Actions)

/// 仪表盘向外部发出的语义动作（供外部接线）
public enum WatchDashboardAction: Equatable {
    /// 触发配对或切换设备
    case reconnectOrAddDevice
    /// 主录音操作 (开始录音 / 发送)
    case primaryAction
    /// 暂停或继续当前录音
    case pauseResumeRecording
    /// 结束当前对话
    case endConversation
    /// 打开待发箱
    case openOutbox
    /// 打开设备设置与诊断
    case openDiagnostics
    /// 刷新手表电量
    case refreshBattery
}

// MARK: - 仪表盘视图主类 (WatchDashboardView)

/// 纯 UIKit 编写的 relay watch 控制面板
/// 固定暗黑主题 (#0a0b0d)，成熟商业产品风格，紧凑克制。
/// 支持 320pt 窄屏、动态字体、VoiceOver 无障碍，无任何业务推导或副作用。
public final class WatchDashboardView: UIView {

    // MARK: - 外部动作闭包

    /// 综合语义事件回调（所有用户操作统一由此闭包外发）
    public var onAction: ((WatchDashboardAction) -> Void)?

    /// 兼容旧闭包声明（保留声明供兼容，但不调用以防重复触发双重操作）
    public var onReconnectOrAddDevice: (() -> Void)?
    public var onPrimaryAction: (() -> Void)?
    public var onPauseResumeRecording: (() -> Void)?
    public var onEndConversation: (() -> Void)?
    public var onOpenOutbox: (() -> Void)?
    public var onOpenDiagnostics: (() -> Void)?

    // MARK: - 私有常量色彩 (固定暗黑主题)

    private static let darkBg = UIColor(red: 10/255, green: 11/255, blue: 13/255, alpha: 1.0)        // #0a0b0d
    private static let surfaceBg = UIColor(red: 18/255, green: 20/255, blue: 24/255, alpha: 1.0)     // #121418
    private static let cardBorder = UIColor(red: 32/255, green: 36/255, blue: 44/255, alpha: 1.0)    // #20242c
    private static let textMuted = UIColor(red: 138/255, green: 145/255, blue: 158/255, alpha: 1.0) // #8a919e
    private static let textTertiary = UIColor(red: 86/255, green: 92/255, blue: 105/255, alpha: 1.0)// #565c69

    // MARK: - 布局容器

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let contentStack = UIStackView()

    // MARK: 1. 顶部设备与连接状态
    private let headerContainer = UIView()
    private let deviceNameLabel = UILabel()
    private let deviceSubtitleLabel = UILabel()
    private let connectionPill = UIView()
    private let connectionDot = UIView()
    private let connectionStatusLabel = UILabel()

    // MARK: 2. 紧凑电量栏
    private let batteryCard = UIView()
    private let batteryIconImageView = UIImageView()
    private let batteryLevelLabel = UILabel()
    private let batteryBadgePill = UIView()
    private let batteryBadgeLabel = UILabel()
    private let batteryDetailLabel = UILabel()
    private let refreshBatteryButton = UIButton(type: .system)

    // MARK: 3. 主要录音区域
    private let recordingCard = UIView()
    private let recordingStatusPill = UIView()
    private let recordingStatusDot = UIView()
    private let recordingStatusLabel = UILabel()
    private let recordingTimeLabel = UILabel()
    private let recordingDetailLabel = UILabel()
    private let primaryActionButton = UIButton(type: .system)
    private let secondaryActionsStack = UIStackView()
    private let pauseResumeButton = UIButton(type: .system)
    private let endConversationButton = UIButton(type: .system)

    // MARK: 4. 底部入口行
    private let footerRow = UIStackView()
    private let deviceEntryButton = CompactEntryButton()
    private let outboxEntryButton = CompactEntryButton()
    private let settingsEntryButton = CompactEntryButton()

    // 当前状态备份
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

    /// 将状态结构体单向绑定至界面组件，绝不读取单例或推导业务
    public func configure(state: WatchDashboardViewState) {
        self.currentState = state

        // 1. 顶部设备名称与副标题
        deviceNameLabel.text = state.deviceName
        if let subtitle = state.deviceSubtitle,
           !subtitle.isEmpty,
           !subtitle.contains("按键控制"),
           !subtitle.contains("手机采音") {
            deviceSubtitleLabel.text = subtitle
            deviceSubtitleLabel.isHidden = false
        } else {
            deviceSubtitleLabel.isHidden = true
        }

        // 2. 顶部连接状态 (小圆点与精简文字，不重复“就绪”)
        updateConnectionStateUI(state.connectionState, rawTitle: state.statusTitle)

        // 3. 紧凑电量与充电状态
        batteryLevelLabel.text = state.batteryText
        updateBatteryStateUI(
            status: state.batteryStatus,
            isCharging: state.isCharging,
            detail: state.batteryDetail,
            isRefreshing: state.isRefreshingBattery
        )

        // 4. 主要录音状态与时长
        recordingTimeLabel.text = state.recordingTime
        updateRecordingStateUI(
            state: state.recordingState,
            isRecording: state.isRecording,
            isPaused: state.isPaused,
            rawTitle: state.recordingTitle,
            rawDetail: state.recordingDetail
        )

        // 5. 主操作按钮（开始录音 / 发送）
        updatePrimaryActionButton(
            config: state.primaryButton,
            isRecording: state.isRecording,
            isPaused: state.isPaused
        )

        // 6. 次级操作按钮（暂停/继续、结束对话）
        updateSecondaryButtons(
            pauseResume: state.pauseResumeButton,
            endConversation: state.endConversationButton,
            isPaused: state.isPaused
        )

        // 7. 底部入口行（设备、待发、设置）
        updateFooterRow(state: state)
        refreshBatteryButton.isEnabled = state.connectionState == .connected && !state.isRefreshingBattery

        // 8. VoiceOver 无障碍属性刷新
        updateAccessibility(state: state)
    }

    // MARK: - 内部视觉辅助渲染

    private func updateConnectionStateUI(_ state: WatchDashboardViewState.ConnectionState, rawTitle: String) {
        let cleanTitle: String
        if rawTitle.contains("就绪") {
            switch state {
            case .connected: cleanTitle = "已连接"
            case .connecting: cleanTitle = "连接中"
            case .disconnected: cleanTitle = "未连接"
            case .error: cleanTitle = "连接异常"
            }
        } else if !rawTitle.isEmpty {
            cleanTitle = rawTitle
        } else {
            switch state {
            case .connected: cleanTitle = "已连接"
            case .connecting: cleanTitle = "连接中"
            case .disconnected: cleanTitle = "未连接"
            case .error: cleanTitle = "连接异常"
            }
        }
        connectionStatusLabel.text = cleanTitle

        switch state {
        case .connected:
            connectionDot.backgroundColor = .systemGreen
            connectionStatusLabel.textColor = .systemGreen
            connectionPill.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.12)
        case .connecting:
            connectionDot.backgroundColor = .systemOrange
            connectionStatusLabel.textColor = .systemOrange
            connectionPill.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        case .disconnected:
            connectionDot.backgroundColor = Self.textMuted
            connectionStatusLabel.textColor = Self.textMuted
            connectionPill.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        case .error:
            connectionDot.backgroundColor = .systemRed
            connectionStatusLabel.textColor = .systemRed
            connectionPill.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        }
    }

    private func updateBatteryStateUI(
        status: WatchDashboardViewState.BatteryStatus,
        isCharging: Bool,
        detail: String,
        isRefreshing: Bool
    ) {
        // 图标与标签逻辑
        if isCharging || status == .charging {
            batteryIconImageView.image = UIImage(systemName: "battery.100.bolt")
            batteryIconImageView.tintColor = .systemGreen
            batteryBadgePill.isHidden = false
            batteryBadgePill.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
            batteryBadgeLabel.text = "充电中"
            batteryBadgeLabel.textColor = .systemGreen
        } else {
            switch status {
            case .charging:
                batteryIconImageView.image = UIImage(systemName: "battery.100.bolt")
                batteryIconImageView.tintColor = .systemGreen
                batteryBadgePill.isHidden = false
                batteryBadgePill.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.15)
                batteryBadgeLabel.text = "充电中"
                batteryBadgeLabel.textColor = .systemGreen

            case .normal:
                batteryIconImageView.image = UIImage(systemName: "battery.75")
                batteryIconImageView.tintColor = .systemGreen
                batteryBadgePill.isHidden = true

            case .low:
                batteryIconImageView.image = UIImage(systemName: "battery.25")
                batteryIconImageView.tintColor = .systemRed
                batteryBadgePill.isHidden = false
                batteryBadgePill.backgroundColor = UIColor.systemRed.withAlphaComponent(0.15)
                batteryBadgeLabel.text = "低电量"
                batteryBadgeLabel.textColor = .systemRed

            case .stale:
                batteryIconImageView.image = UIImage(systemName: "clock.badge.exclamationmark")
                batteryIconImageView.tintColor = .systemOrange
                batteryBadgePill.isHidden = false
                batteryBadgePill.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.15)
                batteryBadgeLabel.text = "已过期"
                batteryBadgeLabel.textColor = .systemOrange

            case .unknown:
                batteryIconImageView.image = UIImage(systemName: "questionmark.circle")
                batteryIconImageView.tintColor = Self.textMuted
                batteryBadgePill.isHidden = true

            case .disconnected:
                batteryIconImageView.image = UIImage(systemName: "battery.slash")
                batteryIconImageView.tintColor = Self.textMuted
                batteryBadgePill.isHidden = true
            }
        }

        batteryDetailLabel.text = detail
        batteryDetailLabel.isHidden = detail.isEmpty

        // 刷新按钮状态与旋转动画
        setBatteryRefreshing(isRefreshing)
    }

    private func setBatteryRefreshing(_ refreshing: Bool) {
        if refreshing {
            refreshBatteryButton.isEnabled = false
            if refreshBatteryButton.layer.animation(forKey: "batterySpinAnimation") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.toValue = NSNumber(value: Double.pi * 2.0)
                spin.duration = 0.9
                spin.isCumulative = true
                spin.repeatCount = .infinity
                refreshBatteryButton.layer.add(spin, forKey: "batterySpinAnimation")
            }
        } else {
            refreshBatteryButton.isEnabled = true
            refreshBatteryButton.layer.removeAnimation(forKey: "batterySpinAnimation")
        }
    }

    private func updateRecordingStateUI(
        state: WatchDashboardViewState.RecordingState,
        isRecording: Bool,
        isPaused: Bool,
        rawTitle: String,
        rawDetail: String
    ) {
        // 录音状态简明指示
        switch state {
        case .recording:
            recordingStatusDot.backgroundColor = .systemRed
            recordingStatusLabel.text = "正在录音"
            recordingStatusLabel.textColor = .systemRed
            recordingStatusPill.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
            recordingTimeLabel.textColor = .white

        case .pausedDraft:
            recordingStatusDot.backgroundColor = .systemOrange
            recordingStatusLabel.text = "录音已暂停"
            recordingStatusLabel.textColor = .systemOrange
            recordingStatusPill.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
            recordingTimeLabel.textColor = .systemOrange

        case .transmitting:
            recordingStatusDot.backgroundColor = .systemBlue
            recordingStatusLabel.text = "正在发送"
            recordingStatusLabel.textColor = .systemBlue
            recordingStatusPill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            recordingTimeLabel.textColor = Self.textMuted

        case .idle:
            recordingStatusDot.backgroundColor = Self.textTertiary
            recordingStatusLabel.text = "空闲待命"
            recordingStatusLabel.textColor = Self.textMuted
            recordingStatusPill.backgroundColor = UIColor.white.withAlphaComponent(0.06)
            recordingTimeLabel.textColor = Self.textTertiary
        }

        if !rawTitle.isEmpty { recordingStatusLabel.text = rawTitle }
        recordingDetailLabel.text = rawDetail
        recordingDetailLabel.isHidden = rawDetail.isEmpty
        recordingDetailLabel.textColor = .systemRed
    }

    private func updatePrimaryActionButton(
        config: WatchDashboardViewState.ButtonConfig,
        isRecording: Bool,
        isPaused: Bool
    ) {
        primaryActionButton.setTitle(config.title, for: .normal)
        primaryActionButton.isEnabled = config.isEnabled
        primaryActionButton.isHidden = config.isHidden

        if isRecording {
            primaryActionButton.backgroundColor = .systemGreen
            primaryActionButton.setTitleColor(.white, for: .normal)
            primaryActionButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
            primaryActionButton.tintColor = .white
        } else if isPaused {
            primaryActionButton.backgroundColor = .systemBlue
            primaryActionButton.setTitleColor(.white, for: .normal)
            primaryActionButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
            primaryActionButton.tintColor = .white
        } else {
            primaryActionButton.backgroundColor = config.isEnabled ? .systemBlue : UIColor(red: 28/255, green: 30/255, blue: 36/255, alpha: 1.0)
            primaryActionButton.setTitleColor(config.isEnabled ? .white : Self.textTertiary, for: .normal)
            primaryActionButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
            primaryActionButton.tintColor = config.isEnabled ? .white : Self.textTertiary
        }
    }

    private func updateSecondaryButtons(
        pauseResume: WatchDashboardViewState.ButtonConfig,
        endConversation: WatchDashboardViewState.ButtonConfig,
        isPaused: Bool
    ) {
        // 暂停 / 继续按钮：简短明确
        let pauseTitle: String
        if isPaused || pauseResume.title.contains("继续") {
            pauseTitle = "继续"
            pauseResumeButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        } else {
            pauseTitle = "暂停"
            pauseResumeButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        }
        pauseResumeButton.setTitle(pauseTitle, for: .normal)
        pauseResumeButton.isEnabled = pauseResume.isEnabled
        pauseResumeButton.isHidden = pauseResume.isHidden

        // 结束对话按钮：简短明确，无小作文
        let endTitle = endConversation.title.contains("结束") ? "结束对话" : endConversation.title
        endConversationButton.setTitle(endTitle, for: .normal)
        endConversationButton.isEnabled = endConversation.isEnabled
        endConversationButton.isHidden = endConversation.isHidden
    }

    private func updateFooterRow(state: WatchDashboardViewState) {
        // 设备入口
        deviceEntryButton.isEnabled = state.reconnectButton.isEnabled
        deviceEntryButton.isHidden = state.reconnectButton.isHidden

        // 待发入口 (仅在有待发时展示数量徽标，无待发不显示徽标也不加宣传卡)
        outboxEntryButton.isEnabled = state.outboxButton.isEnabled
        outboxEntryButton.isHidden = state.outboxButton.isHidden
        if state.pendingCount > 0 {
            outboxEntryButton.setBadge("\(state.pendingCount)")
        } else {
            outboxEntryButton.setBadge(nil)
        }

        // 设置入口
        settingsEntryButton.isEnabled = state.diagnosticsButton.isEnabled
        settingsEntryButton.isHidden = state.diagnosticsButton.isHidden
    }

    // MARK: - VoiceOver 无障碍

    private func updateAccessibility(state: WatchDashboardViewState) {
        headerContainer.isAccessibilityElement = true
        headerContainer.accessibilityLabel = "\(state.deviceName)，连接状态：\(connectionStatusLabel.text ?? state.statusTitle)"
        headerContainer.accessibilityTraits = .header

        batteryCard.isAccessibilityElement = false
        batteryCard.accessibilityLabel = "电量：\(state.batteryText)，\(state.batteryDetail)"

        refreshBatteryButton.accessibilityLabel = "刷新设备电量"
        refreshBatteryButton.accessibilityTraits = .button

        recordingCard.isAccessibilityElement = false
        recordingCard.accessibilityLabel = "录音状态：\(recordingStatusLabel.text ?? "")，时长：\(state.recordingTime)"

        primaryActionButton.accessibilityLabel = state.primaryButton.title
        pauseResumeButton.accessibilityLabel = state.isPaused ? "继续录音" : "暂停录音"
        endConversationButton.accessibilityLabel = "结束当前对话"

        deviceEntryButton.accessibilityLabel = "切换或管理设备"
        outboxEntryButton.accessibilityLabel = state.pendingCount > 0 ? "待发箱，共 \(state.pendingCount) 条待发" : "待发箱"
        settingsEntryButton.accessibilityLabel = "设备设置与诊断"
    }

    // MARK: - UI 构建与排版 (AutoLayout)

    private func setupViews() {
        backgroundColor = Self.darkBg
        overrideUserInterfaceStyle = .dark

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.backgroundColor = Self.darkBg
        addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = Self.darkBg
        scrollView.addSubview(contentView)

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.alignment = .fill
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentStack)

        buildHeader()
        buildBatteryCard()
        buildRecordingCard()
        buildFooterRow()

        contentStack.addArrangedSubview(headerContainer)
        contentStack.addArrangedSubview(batteryCard)
        contentStack.addArrangedSubview(recordingCard)
        contentStack.addArrangedSubview(footerRow)
    }

    private func buildHeader() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false

        deviceNameLabel.font = .systemFont(ofSize: 20, weight: .bold)
        deviceNameLabel.adjustsFontForContentSizeCategory = true
        deviceNameLabel.textColor = .white
        deviceNameLabel.text = "relay watch"
        deviceNameLabel.translatesAutoresizingMaskIntoConstraints = false

        deviceSubtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        deviceSubtitleLabel.adjustsFontForContentSizeCategory = true
        deviceSubtitleLabel.textColor = Self.textMuted
        deviceSubtitleLabel.numberOfLines = 1
        deviceSubtitleLabel.isHidden = true
        deviceSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = UIStackView(arrangedSubviews: [deviceNameLabel, deviceSubtitleLabel])
        titleStack.axis = .vertical
        titleStack.spacing = 2
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        connectionPill.layer.cornerRadius = 10
        connectionPill.clipsToBounds = true
        connectionPill.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        connectionPill.translatesAutoresizingMaskIntoConstraints = false

        connectionDot.layer.cornerRadius = 3.5
        connectionDot.clipsToBounds = true
        connectionDot.backgroundColor = Self.textMuted
        connectionDot.translatesAutoresizingMaskIntoConstraints = false

        connectionStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        connectionStatusLabel.adjustsFontForContentSizeCategory = true
        connectionStatusLabel.textColor = Self.textMuted
        connectionStatusLabel.text = "未连接"
        connectionStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let pillStack = UIStackView(arrangedSubviews: [connectionDot, connectionStatusLabel])
        pillStack.axis = .horizontal
        pillStack.spacing = 6
        pillStack.alignment = .center
        pillStack.translatesAutoresizingMaskIntoConstraints = false

        connectionPill.addSubview(pillStack)
        headerContainer.addSubview(titleStack)
        headerContainer.addSubview(connectionPill)

        NSLayoutConstraint.activate([
            pillStack.topAnchor.constraint(equalTo: connectionPill.topAnchor, constant: 4),
            pillStack.bottomAnchor.constraint(equalTo: connectionPill.bottomAnchor, constant: -4),
            pillStack.leadingAnchor.constraint(equalTo: connectionPill.leadingAnchor, constant: 8),
            pillStack.trailingAnchor.constraint(equalTo: connectionPill.trailingAnchor, constant: -8),

            connectionDot.widthAnchor.constraint(equalToConstant: 7),
            connectionDot.heightAnchor.constraint(equalToConstant: 7),

            titleStack.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            titleStack.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 4),
            titleStack.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -4),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: connectionPill.leadingAnchor, constant: -8),

            connectionPill.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            connectionPill.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor)
        ])
    }

    private func buildBatteryCard() {
        stylePanel(batteryCard)

        batteryIconImageView.image = UIImage(systemName: "questionmark.circle")
        batteryIconImageView.tintColor = Self.textMuted
        batteryIconImageView.contentMode = .scaleAspectFit
        batteryIconImageView.translatesAutoresizingMaskIntoConstraints = false

        batteryLevelLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        batteryLevelLabel.adjustsFontForContentSizeCategory = true
        batteryLevelLabel.textColor = .white
        batteryLevelLabel.text = "电量未知"
        batteryLevelLabel.translatesAutoresizingMaskIntoConstraints = false

        batteryBadgePill.layer.cornerRadius = 6
        batteryBadgePill.clipsToBounds = true
        batteryBadgePill.isHidden = true
        batteryBadgePill.translatesAutoresizingMaskIntoConstraints = false

        batteryBadgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        batteryBadgeLabel.translatesAutoresizingMaskIntoConstraints = false

        batteryBadgePill.addSubview(batteryBadgeLabel)

        batteryDetailLabel.font = .preferredFont(forTextStyle: .caption2)
        batteryDetailLabel.adjustsFontForContentSizeCategory = true
        batteryDetailLabel.textColor = Self.textMuted
        batteryDetailLabel.numberOfLines = 1
        batteryDetailLabel.isHidden = true
        batteryDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        let badgeStack = UIStackView(arrangedSubviews: [batteryIconImageView, batteryLevelLabel, batteryBadgePill])
        badgeStack.axis = .horizontal
        badgeStack.spacing = 8
        badgeStack.alignment = .center
        badgeStack.translatesAutoresizingMaskIntoConstraints = false

        let batteryInfoStack = UIStackView(arrangedSubviews: [badgeStack, batteryDetailLabel])
        batteryInfoStack.axis = .vertical
        batteryInfoStack.spacing = 2
        batteryInfoStack.alignment = .leading
        batteryInfoStack.translatesAutoresizingMaskIntoConstraints = false

        // 刷新按钮：无文字，仅清晰图标
        let refreshConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        refreshBatteryButton.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: refreshConfig), for: .normal)
        refreshBatteryButton.tintColor = Self.textMuted
        refreshBatteryButton.translatesAutoresizingMaskIntoConstraints = false

        batteryCard.addSubview(batteryInfoStack)
        batteryCard.addSubview(refreshBatteryButton)

        NSLayoutConstraint.activate([
            batteryBadgeLabel.topAnchor.constraint(equalTo: batteryBadgePill.topAnchor, constant: 2),
            batteryBadgeLabel.bottomAnchor.constraint(equalTo: batteryBadgePill.bottomAnchor, constant: -2),
            batteryBadgeLabel.leadingAnchor.constraint(equalTo: batteryBadgePill.leadingAnchor, constant: 6),
            batteryBadgeLabel.trailingAnchor.constraint(equalTo: batteryBadgePill.trailingAnchor, constant: -6),

            batteryIconImageView.widthAnchor.constraint(equalToConstant: 22),
            batteryIconImageView.heightAnchor.constraint(equalToConstant: 16),

            batteryInfoStack.leadingAnchor.constraint(equalTo: batteryCard.leadingAnchor, constant: 14),
            batteryInfoStack.centerYAnchor.constraint(equalTo: batteryCard.centerYAnchor),
            batteryInfoStack.trailingAnchor.constraint(lessThanOrEqualTo: refreshBatteryButton.leadingAnchor, constant: -8),
            batteryInfoStack.topAnchor.constraint(greaterThanOrEqualTo: batteryCard.topAnchor, constant: 10),
            batteryInfoStack.bottomAnchor.constraint(lessThanOrEqualTo: batteryCard.bottomAnchor, constant: -10),

            refreshBatteryButton.trailingAnchor.constraint(equalTo: batteryCard.trailingAnchor, constant: -10),
            refreshBatteryButton.centerYAnchor.constraint(equalTo: batteryCard.centerYAnchor),
            refreshBatteryButton.widthAnchor.constraint(equalToConstant: 36),
            refreshBatteryButton.heightAnchor.constraint(equalToConstant: 36),

            batteryCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
    }

    private func buildRecordingCard() {
        stylePanel(recordingCard)

        // 状态指示小胶囊
        recordingStatusPill.layer.cornerRadius = 10
        recordingStatusPill.clipsToBounds = true
        recordingStatusPill.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        recordingStatusPill.translatesAutoresizingMaskIntoConstraints = false

        recordingStatusDot.layer.cornerRadius = 3.5
        recordingStatusDot.clipsToBounds = true
        recordingStatusDot.backgroundColor = Self.textTertiary
        recordingStatusDot.translatesAutoresizingMaskIntoConstraints = false

        recordingStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        recordingStatusLabel.adjustsFontForContentSizeCategory = true
        recordingStatusLabel.textColor = Self.textMuted
        recordingStatusLabel.text = "空闲待命"
        recordingStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let pillStack = UIStackView(arrangedSubviews: [recordingStatusDot, recordingStatusLabel])
        pillStack.axis = .horizontal
        pillStack.spacing = 6
        pillStack.alignment = .center
        pillStack.translatesAutoresizingMaskIntoConstraints = false

        recordingStatusPill.addSubview(pillStack)

        // 时长展示（等宽大字号，居中突出）
        recordingTimeLabel.font = .monospacedDigitSystemFont(ofSize: 42, weight: .bold)
        recordingTimeLabel.adjustsFontForContentSizeCategory = true
        recordingTimeLabel.textColor = Self.textTertiary
        recordingTimeLabel.text = "--:--"
        recordingTimeLabel.textAlignment = .center
        recordingTimeLabel.translatesAutoresizingMaskIntoConstraints = false

        // 真实错误提示 (无错误时自动隐藏)
        recordingDetailLabel.font = .preferredFont(forTextStyle: .caption1)
        recordingDetailLabel.adjustsFontForContentSizeCategory = true
        recordingDetailLabel.textColor = .systemRed
        recordingDetailLabel.textAlignment = .center
        recordingDetailLabel.numberOfLines = 0
        recordingDetailLabel.isHidden = true
        recordingDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        // 主按钮：开始录音 / 发送 (50pt 高度，圆角 14)
        primaryActionButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        primaryActionButton.titleLabel?.adjustsFontForContentSizeCategory = true
        primaryActionButton.layer.cornerRadius = 14
        primaryActionButton.clipsToBounds = true
        primaryActionButton.translatesAutoresizingMaskIntoConstraints = false
        primaryActionButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)

        // 次级按钮行：暂停/继续、结束对话 (横向并列，各自 44pt 高度)
        secondaryActionsStack.axis = .horizontal
        secondaryActionsStack.spacing = 10
        secondaryActionsStack.distribution = .fillEqually
        secondaryActionsStack.translatesAutoresizingMaskIntoConstraints = false

        pauseResumeButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        pauseResumeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        pauseResumeButton.backgroundColor = UIColor(red: 26/255, green: 28/255, blue: 34/255, alpha: 1.0)
        pauseResumeButton.layer.borderColor = Self.cardBorder.cgColor
        pauseResumeButton.layer.borderWidth = 0.5
        pauseResumeButton.layer.cornerRadius = 12
        pauseResumeButton.clipsToBounds = true
        pauseResumeButton.setTitleColor(.white, for: .normal)
        pauseResumeButton.tintColor = .white
        pauseResumeButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)
        pauseResumeButton.translatesAutoresizingMaskIntoConstraints = false

        endConversationButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        endConversationButton.titleLabel?.adjustsFontForContentSizeCategory = true
        endConversationButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        endConversationButton.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.24).cgColor
        endConversationButton.layer.borderWidth = 0.5
        endConversationButton.layer.cornerRadius = 12
        endConversationButton.clipsToBounds = true
        endConversationButton.setTitleColor(.systemRed, for: .normal)
        endConversationButton.tintColor = .systemRed
        endConversationButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -6, bottom: 0, right: 6)
        endConversationButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        endConversationButton.translatesAutoresizingMaskIntoConstraints = false

        secondaryActionsStack.addArrangedSubview(pauseResumeButton)
        secondaryActionsStack.addArrangedSubview(endConversationButton)

        let cardStack = UIStackView(arrangedSubviews: [
            recordingStatusPill,
            recordingTimeLabel,
            recordingDetailLabel,
            primaryActionButton,
            secondaryActionsStack
        ])
        cardStack.axis = .vertical
        cardStack.spacing = 14
        cardStack.alignment = .fill
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        recordingCard.addSubview(cardStack)

        NSLayoutConstraint.activate([
            pillStack.topAnchor.constraint(equalTo: recordingStatusPill.topAnchor, constant: 4),
            pillStack.bottomAnchor.constraint(equalTo: recordingStatusPill.bottomAnchor, constant: -4),
            pillStack.leadingAnchor.constraint(equalTo: recordingStatusPill.leadingAnchor, constant: 8),
            pillStack.trailingAnchor.constraint(equalTo: recordingStatusPill.trailingAnchor, constant: -8),

            recordingStatusDot.widthAnchor.constraint(equalToConstant: 7),
            recordingStatusDot.heightAnchor.constraint(equalToConstant: 7),

            recordingStatusPill.centerXAnchor.constraint(equalTo: recordingCard.centerXAnchor),

            primaryActionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            pauseResumeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            endConversationButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            cardStack.topAnchor.constraint(equalTo: recordingCard.topAnchor, constant: 16),
            cardStack.bottomAnchor.constraint(equalTo: recordingCard.bottomAnchor, constant: -16),
            cardStack.leadingAnchor.constraint(equalTo: recordingCard.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: recordingCard.trailingAnchor, constant: -16)
        ])
    }

    private func buildFooterRow() {
        footerRow.axis = .horizontal
        footerRow.spacing = 10
        footerRow.distribution = .fillEqually
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        deviceEntryButton.configure(
            icon: UIImage(systemName: "applewatch"),
            title: "设备"
        )
        outboxEntryButton.configure(
            icon: UIImage(systemName: "tray"),
            title: "待发"
        )
        settingsEntryButton.configure(
            icon: UIImage(systemName: "gearshape"),
            title: "设置"
        )

        footerRow.addArrangedSubview(deviceEntryButton)
        footerRow.addArrangedSubview(outboxEntryButton)
        footerRow.addArrangedSubview(settingsEntryButton)

        NSLayoutConstraint.activate([
            deviceEntryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
            outboxEntryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
            settingsEntryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 46)
        ])
    }

    private func stylePanel(_ panel: UIView) {
        panel.backgroundColor = Self.surfaceBg
        panel.layer.borderColor = Self.cardBorder.cgColor
        panel.layer.borderWidth = 0.5
        panel.layer.cornerRadius = 14
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
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

            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    // MARK: - 事件绑定 (仅通过 onAction 外发，绝不触发重复闭包)

    private func setupActions() {
        refreshBatteryButton.addTarget(self, action: #selector(handleRefreshBatteryTapped), for: .touchUpInside)
        primaryActionButton.addTarget(self, action: #selector(handlePrimaryActionTapped), for: .touchUpInside)
        pauseResumeButton.addTarget(self, action: #selector(handlePauseResumeTapped), for: .touchUpInside)
        endConversationButton.addTarget(self, action: #selector(handleEndConversationTapped), for: .touchUpInside)
        deviceEntryButton.addTarget(self, action: #selector(handleReconnectTapped), for: .touchUpInside)
        outboxEntryButton.addTarget(self, action: #selector(handleOutboxTapped), for: .touchUpInside)
        settingsEntryButton.addTarget(self, action: #selector(handleDiagnosticsTapped), for: .touchUpInside)
    }

    @objc private func handleRefreshBatteryTapped() {
        onAction?(.refreshBattery)
    }

    @objc private func handlePrimaryActionTapped() {
        onAction?(.primaryAction)
    }

    @objc private func handlePauseResumeTapped() {
        onAction?(.pauseResumeRecording)
    }

    @objc private func handleEndConversationTapped() {
        onAction?(.endConversation)
    }

    @objc private func handleReconnectTapped() {
        onAction?(.reconnectOrAddDevice)
    }

    @objc private func handleOutboxTapped() {
        onAction?(.openOutbox)
    }

    @objc private func handleDiagnosticsTapped() {
        onAction?(.openDiagnostics)
    }
}

// MARK: - 辅助子视图：紧凑入口按钮 (CompactEntryButton)

/// 紧凑扁平入口按钮，支持徽标展示、高亮按压与禁用状态
private final class CompactEntryButton: UIControl {

    private let iconImageView = UIImageView()
    private let titleLabel = UILabel()
    private let badgeView = UIView()
    private let badgeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    func configure(icon: UIImage?, title: String) {
        iconImageView.image = icon
        titleLabel.text = title
    }

    func setBadge(_ text: String?) {
        if let badgeText = text, !badgeText.isEmpty {
            badgeLabel.text = badgeText
            badgeView.isHidden = false
        } else {
            badgeView.isHidden = true
        }
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.6 : (isEnabled ? 1.0 : 0.4)
        }
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1.0 : 0.4
        }
    }

    private func setupViews() {
        backgroundColor = UIColor(red: 18/255, green: 20/255, blue: 24/255, alpha: 1.0)
        layer.borderColor = UIColor(red: 32/255, green: 36/255, blue: 44/255, alpha: 1.0).cgColor
        layer.borderWidth = 0.5
        layer.cornerRadius = 12
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        iconImageView.contentMode = .scaleAspectFit
        iconImageView.tintColor = UIColor(red: 138/255, green: 145/255, blue: 158/255, alpha: 1.0)
        iconImageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeView.backgroundColor = .systemOrange
        badgeView.layer.cornerRadius = 8
        badgeView.clipsToBounds = true
        badgeView.isHidden = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeView.addSubview(badgeLabel)

        let stack = UIStackView(arrangedSubviews: [iconImageView, titleLabel, badgeView])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),

            badgeLabel.topAnchor.constraint(equalTo: badgeView.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: -1),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -5),
            badgeView.heightAnchor.constraint(equalToConstant: 16),

            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
    }
}

// MARK: - 便捷宿主控制器 (WatchDashboardViewController)

/// 供模态弹出与嵌入的轻量宿主控制器
public final class WatchDashboardViewController: UIViewController {

    public let dashboardView = WatchDashboardView()

    public override func loadView() {
        self.view = dashboardView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "relay watch"
        overrideUserInterfaceStyle = .dark
        navigationItem.largeTitleDisplayMode = .never

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
