# Relay 语音手表控制页面设计规范与接线约定

## 1. 概述与设计理念

本设计专为 **Agent Relay 语音穿戴设备（ESP32 手表 / 大疆麦克风）** 打造，旨在替代此前堆叠数十个调试按钮与原始文本日志的测试控制台，提供**正式、原生、精致且符合 Apple 人机交互指南 (Human Interface Guidelines)** 的 iPhone 原生设备控制体验。

### 核心设计原则
1. **克制且精致的排版层次**：采用 Apple 原生 Inset Grouped 分组卡片风格，遵循 iOS 系统间距（16pt / 12pt）、圆角（18pt continuous corner）、动态颜色与层级。
2. **状态诚实性（Honest Status）**：
   - 电量未知、缓存过期、蓝牙断开时如实呈现（如“电量未知”、“已断连”、“数据已过期”），严禁在硬件未上报或断链时伪造百分比。
3. **清晰的操作边界**：
   - **严格区分“发送本条（保留逻辑会话）”与“结束当前对话（关闭会话）”**，防止用户误触结束整轮上下文。
4. **纯粹的单向渲染架构**：
   - `WatchDashboardView` 是纯 UIKit `UIView`，无任何业务推导或全局单例引用；
   - 外部调用方（Codex 接线层）单向传入 `WatchDashboardViewState`，点击动作以 `WatchDashboardAction` 闭包回调派发。
5. **完整的多环境适配**：
   - 原生支持 **暗色模式 (Dark Mode)** 与浅色模式；
   - 支持 **动态字体 (Dynamic Type)** 与 VoiceOver 辅助功能；
   - 适配 iPhone SE 等窄屏、大屏 Pro Max 及安全区（Safe Area）。

---

## 2. 视图架构与责任边界

```
┌─────────────────────────────────────────────────────────────┐
│                 Codex 业务接线层 (调用方)                     │
│  (WearableService / WatchVoiceSession / BLEProbe / 日志)    │
└──────────────────────────┬──────────────────────────────────┘
                           │ 1. 业务状态转换
                           ▼
              ┌──────────────────────────┐
              │  WatchDashboardViewState │ (纯展示数据模型)
              └────────────┬─────────────┘
                           │ 2. 单向渲染 configure(state:)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    WatchDashboardView                       │
│  - 纯 UIKit UIView                                          │
│  - 严禁 import CoreBluetooth / AVFoundation / LiveKit       │
│  - 严禁持有 Timer / 网络 / 录音状态机 / UserDefaults        │
│  - 仅负责 UI 排版与无障碍呈现                               │
└──────────────────────────┬──────────────────────────────────┘
                           │ 3. 语义动作回调 onAction(action)
                           ▼
              ┌──────────────────────────┐
              │   WatchDashboardAction   │ (语义动作枚举)
              └────────────┬─────────────┘
                           │ 4. 派发给业务方法
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Codex 接线处理：                                           │
│  - .primaryAction          -> phoneToggle() / phoneSend()   │
│  - .pauseResumeRecording   -> phonePause() / phoneStart()   │
│  - .endConversation        -> phoneEnd() / probe.end()      │
│  - .openOutbox             -> showVoiceRecovery()           │
│  - .openDiagnostics        -> present(DeviceDiagnosticsVC)  │
│  - .reconnectOrAddDevice   -> scanBLE() / probe.reconnect() │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 页面区域与组件说明

### 3.1 顶部设备卡片 (Header)
- **设备图标**：Apple Watch / 穿戴设备原生矢量符号。
- **设备友好名称 (`deviceName`)**：例如 `"Relay 语音手表"`。
- **链路副标题 (`deviceSubtitle`)**：例如 `"按键控制 · 手机录音"`。
- **快捷重连按钮**：轻量级 `"重连设备"` 入口。

### 3.2 主区域 1：连接与电量状态卡片 (Status Card)
- **连接状态 (`statusTitle` / `statusDetail` / `connectionState`)**：
  - 动态状态圆点（绿色正常 / 橙色重连中 / 灰色断开 / 红色异常）；
  - 清晰呈现链路延迟或异常原因。
- **电量与充电状态 (`batteryText` / `batteryDetail` / `batteryStatus` / `isCharging`)**：
  - **诚实呈现**：
    - 正常：显示百分比（如 `"85%"`），绿色指示标签 `"正常"`；
    - 充电中：显示闪电图标，绿色指示标签 `"充电中"`；
    - 低电量：小于 20% 时红色告警；
    - 数据过期：硬件长时间未上报时显示 `"数据已过期"`（橙色）；
    - 断连/未知：显示 `"电量未知 (已断连)"`，禁止推算或伪造虚假电量。

### 3.3 主区域 2：真实录音状态与时长卡片 (Recording Card)
- **录音状态胶囊 (`recordingTitle` / `recordingState`)**：
  - 录音中：红底呼吸红点，文案 `"正在录音"`；
  - 草稿暂停：橙底图标，文案 `"录音已暂停 (草稿保留)"`；
  - 待命：灰色文案 `"空闲待命"`。
- **等宽时长大字号 (`recordingTime`)**：
  - 采用系统等宽大字号（如 `"00:24"`、`"01:15"`），录音时醒目呈现，杜绝跳动。
- **声波指示器 (Waveform)**：
  - 录音中动态拉伸高亮，暂停或空闲时回落至基线。
- **录音详细信息 (`recordingDetail`)**：
  - 指示当前采音麦克风（如 `"麦克风：ESP32 硬件采音"`）或手势引导。

### 3.4 主区域 3：待发箱概览卡片 (Outbox Card)
- **待发数量与文本 (`pendingCount` / `pendingText` / `pendingDetail`)**：
  - 离线或弱网下保存的语音分片数量（例如 `"2 条待发"`）；
  - 全部同步时显示绿色 `"全部已发"` 徽章；
  - 点击卡片整体或右侧箭头即可触发 `.openOutbox`。

### 3.5 次区域：对话控制区域 (Conversation Controls)
- **主操作大按钮 (`primaryButton`)**：
  - 高度 52pt，圆角 16pt，充满视觉重心。
  - **空闲时**：蓝色 `"开始说话"`（麦克风图标）；
  - **录音中**：绿色 `"发送本条（保留会话）"`（发送箭头图标）；
  - **草稿暂停时**：蓝色/绿色 `"发送本条（保留会话）"`。
- **次级操作行（双按钮并列）**：
  - **左侧按钮（暂停/继续）**：`"暂停录音"` / `"继续录音"`（浅灰底色）；
  - **右侧按钮（结束会话）**：`"结束当前对话"`（红底浅色微强调，红字）。
- **说明提示**：
  - 文案提示用户：*『发送本条』保留上下文继续多轮对话；『结束当前对话』将完成并归档整轮会话。*

### 3.6 次区域：设备与诊断入口 (Tools Card)
- 原生 iOS 设置列表行式排版：
  1. **配对 / 重连设备**：触发蓝牙重连或添加新配件；
  2. **录音待发箱与恢复**：查看待发队列、补交或导出音频；
  3. **穿戴设备高级诊断**：**保留原有诊断入口**，供 Codex 调起 `DeviceDiagnosticsViewController`。

### 3.7 底部硬件按键快捷说明 (Tips Card)
- 汇总手表硬件操作映射（BOOT 长按 / 短按，PWR 长按），方便用户日常盲操。

---

## 4. 字段接线约定 (Codex Wiring Guide)

### 4.1 数据结构定义（纯数据，无单例）

```swift
public struct WatchDashboardViewState: Equatable {
    public var deviceName: String
    public var deviceSubtitle: String?

    public var statusTitle: String
    public var statusDetail: String
    public var connectionState: ConnectionState

    public var batteryText: String
    public var batteryDetail: String
    public var isCharging: Bool
    public var batteryStatus: BatteryStatus

    public var recordingState: RecordingState
    public var recordingTitle: String
    public var recordingDetail: String
    public var recordingTime: String
    public var isRecording: Bool
    public var isPaused: Bool

    public var pendingCount: Int
    public var pendingText: String
    public var pendingDetail: String?

    public var primaryButton: ButtonConfig
    public var pauseResumeButton: ButtonConfig
    public var endConversationButton: ButtonConfig
    public var reconnectButton: ButtonConfig
    public var outboxButton: ButtonConfig
    public var diagnosticsButton: ButtonConfig

    public var tipsText: String?

    // 便捷字典映射供动态取用
    public var buttonTitles: [String: String]
    public var buttonEnabled: [String: Bool]
}
```

### 4.2 语义动作枚举

```swift
public enum WatchDashboardAction: Equatable {
    case reconnectOrAddDevice        // 配对 / 重连设备
    case primaryAction               // 主按钮：开始说话 / 发送本条保留会话
    case pauseResumeRecording        // 暂停 / 继续录音草稿
    case endConversation             // 明确结束当前会话
    case openOutbox                  // 查看待发箱与恢复
    case openDiagnostics             // 打开原有高级诊断页面
}
```

### 4.3 Codex 接线示例（以 UIViewController 为例）

```swift
final class RelayWatchContainerViewController: UIViewController {
    private let dashboardView = WatchDashboardView()

    override func loadView() {
        self.view = dashboardView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "语音设备"
        setupDashboardBindings()
        observeBusinessState()
    }

    private func setupDashboardBindings() {
        // 绑定语义动作到底层服务
        dashboardView.onAction = { [weak self] action in
            guard let self = self else { return }
            switch action {
            case .reconnectOrAddDevice:
                self.handleScanOrReconnect()
            case .primaryAction:
                self.handlePrimaryAction()
            case .pauseResumeRecording:
                self.handlePauseResume()
            case .endConversation:
                self.handleEndConversation()
            case .openOutbox:
                self.handleOpenOutbox()
            case .openDiagnostics:
                self.handleOpenDiagnostics()
            }
        }
    }

    // 从业务层（WearableService / WatchVoiceSession / BLEProbe）组装 State
    private func refreshDashboard() {
        let isConnected = BLEProbe.shared.isConnected
        let isRecording = WearableService.shared.isRecording
        let isPaused = WatchVoiceSession.shared.isPausedDraft
        let pending = WatchVoiceSession.shared.recoveryItems.filter { $0.state == "pending" }.count

        // 诚实电量计算
        let (batText, batDetail, batStatus, isCharging) = resolveHonestBattery(isConnected: isConnected)

        let state = WatchDashboardViewState(
            deviceName: BLEProbe.shared.currentDeviceName ?? "Relay 语音手表",
            deviceSubtitle: "按键控制 · 手机录音",
            statusTitle: isConnected ? "已连接" : "未连接",
            statusDetail: isConnected ? "蓝牙低功耗链路正常" : "未发现已绑定的手表设备",
            connectionState: isConnected ? .connected : .disconnected,
            batteryText: batText,
            batteryDetail: batDetail,
            isCharging: isCharging,
            batteryStatus: batStatus,
            recordingState: isRecording ? .recording : (isPaused ? .pausedDraft : .idle),
            recordingTitle: isRecording ? "正在录音" : (isPaused ? "录音已暂停 (草稿保留)" : "空闲待命"),
            recordingDetail: isRecording ? "麦克风：ESP32 硬件采音" : "按“发送本条”提交，或按“结束”",
            recordingTime: formatSeconds(WatchVoiceSession.shared.capturedSeconds),
            isRecording: isRecording,
            isPaused: isPaused,
            pendingCount: pending,
            pendingText: pending > 0 ? "\(pending) 条录音等待发送" : "待发箱已清空",
            pendingDetail: pending > 0 ? "断网时已自动保存在本地，网络恢复后补交" : "全部录音已成功交付",
            primaryButton: .init(
                title: isRecording ? "发送本条（保留会话）" : (isPaused ? "发送本条（保留会话）" : "开始说话"),
                isEnabled: isConnected
            ),
            pauseResumeButton: .init(
                title: isRecording ? "暂停录音" : "继续录音",
                isEnabled: isRecording || isPaused
            ),
            endConversationButton: .init(
                title: "结束当前对话",
                isEnabled: isRecording || isPaused
            )
        )

        dashboardView.configure(state: state)
    }

    // 打开原有诊断入口
    private func handleOpenDiagnostics() {
        let diagVC = DeviceDiagnosticsViewController()
        let nav = UINavigationController(rootViewController: diagVC)
        present(nav, animated: true)
    }
}
```

---

## 5. 静态 HTML 预览

在 `docs/ui/preview.html` 中提供了**独立且无需依赖的浏览器预览页面**：
- 双击即可在 Chrome / Safari / Edge 打开；
- 真实模拟 iPhone 15 Pro 屏幕外框与 Dynamic Island；
- 顶部提供 **状态切换标签栏**，可一键切换以下 6 种典型场景：
  1. **空闲待命** (已连接、电量 85%、无待发)
  2. **正在录音** (录音中 00:24、呼吸波纹、主按钮为“发送本条（保留会话）”)
  3. **草稿暂停** (已录 01:15、草稿封口、支持继续说话或发送本条)
  4. **正在充电** (电量 92%、闪电图标、充电中指示)
  5. **断连与待发积压** (断开连接、**电量诚实显示“电量未知 (已断连)”**、2 条待发录音)
  6. **电量过期告警** (电量数据已过期 15 分钟、硬件未刷新)
- 支持 **深色模式 (Dark Mode) / 浅色模式 (Light Mode)** 一键实时切换。
