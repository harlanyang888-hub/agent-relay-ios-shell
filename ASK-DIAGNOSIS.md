# ASK 后台启动回归：证据和下一步

## 已确认

- 同一份录音实现的 legacy 1.0.24 在 iOS 18.6.1 后台连续 START/STOP、去重、上传成功；用户实测断链补交也成功。
- ASK 1.0.25 已授权、恢复连接、订阅、收命令。失败点在 `ConversationManager.perform(StartConversationAction)`，错误 domain=com.apple.CallKit.error.requesttransaction、code=6；不是蓝牙未收到，也不是录音文件或服务器上传失败。
- code=6 是 invalidAction，只说明交易包含无效动作，不提供系统拒绝的具体条件。不能从这个值推导出升级 iOS 26 能修复。
- 最新 ASK 日志还出现两个不同 PID 的 bluetoothCentrals 后台启动；当前日志不能确定前一进程的退出原因，也不能证明属于用户强退后的重启。
- 两配置源码共用同一个 StartConversationAction 构造和录音实现；配置差别是 ASK 声明、ASAccessorySession 授权和蓝牙管理器恢复时序。audio/voip/bluetooth-central 后台模式相同。
- 不把 `conversationManagerDidBegin`、后台时间、隐私授权、授权配件数量、系统通话状态猜测中的任何一个直接认定为根因。过去等待/重建 manager 的尝试未证实修复，不能重复包装为新结论。

## 下一条必要证据

在保持 ASK 1.0.25 的情况下，通过已信任 USB 设备抓 callservicesd / CallKit / LiveCommunicationKit 过滤日志。复现同一进程前台成功、退到后台失败，记录准确时间；随后单独测试冷恢复，避免把普通后台和恢复后的状态混在一起。对照系统拒绝理由，而不是继续发送功能不同的 IPA。

`tools/ios-callkit-capture.py --probe` 检查 USB；不采集日志。
`tools/ios-callkit-capture.py --seconds 120` 采集过滤日志，最长 300 秒、5000 行、8 MB，保存仓库外 builds/ios-background-call-logs。需先在仓库外 ios-debug-venv 安装 pymobiledevice3，Windows 需 Apple Mobile Device 支持和已信任 USB 连接。

## 官方依据

- invalidAction：https://developer.apple.com/documentation/callkit/cxerrorcoderequesttransactionerror-swift.struct/code/invalidaction
- iOS 26 增加 ASK 特定强退恢复资格，不承诺语音会话建立成功：https://developer.apple.com/forums/thread/806013
- 蓝牙到通话服务之间存在后台执行断档，必须管理有限后台任务；本项目 connect 已申请，仍需核对实际拒绝日志：https://developer.apple.com/forums/thread/804205

本记录不是根因已定位或修复完成的声明。

## 同进程对照和下一项单变量实验

用户补充同一 PID 30569 的完整对照：16:07:09 前台新建并录音成功；16:07:40 后台恢复已有会话成功；16:08:28 完全结束系统会话；16:08:38 后台新建立即 invalidAction。由此排除“仅冷启动/蓝牙恢复初始化导致失败”的解释。失败条件已收窄到 ASK 路径后台新建系统会话，但仍没有系统内部拒绝理由。

实际解包核对：1.0.24 和 1.0.25 的 AgentRelay 可执行文件 SHA256 均为 7515144e0de23f284334a66d0f71d8e11789491549fdc55aea0137e83d8cbc0a。SDK 都是 iphoneos18.5 / Xcode16F6、最低iOS15，audio/voip/bluetooth-central、麦克风和通用蓝牙声明相同。Info.plist 只在版本号、ASK 三项声明和运行开关不同。这排除不同编译录音代码、漏配 voip 作为两包差异的解释。

1.0.27 ASK（legacy对照为1.0.26）新增实验开关：默认立即请求系统会话，取消请求前的网络预检等待；另一路保持原 GET /api/bootstrap 后启动。两路都保留本地登录检查、录音上传鉴权、同样的系统动作和采音回调。不预建系统会话。设备页可在完全结束系统会话后切换，不用重装或接USB。

日志增加 LAB CALL 阶段、单调时钟耗时、managerDidBegin 标记、manager中的会话数量、后台任务状态/剩余时间、CBManager授权值、麦克风授权、NSError domain/code/reason/debug/underlying。该开关不被描述成已证实修复。测试必须在同一进程、同一蓝牙连接中，分别从无系统会话的锁屏状态尝试两条启动路径；每次复测先完全结束系统会话，不能拿“恢复已有会话”当“新建成功”。

## 本机抓取环境

### sysdiagnose 已确认系统拒绝条件

用户提供353102703字节诊断包，已在本机用 Mandiant macos-UnifiedLogs v0.7.0 解码，原始文件未上传到第三方。00:30:08 +0800 对应 UTC16:30:08，callservicesd明确记录 `Not allowing requested CXStartCallAction because user intent could not be validated`，并确认 hasVoIPBackgroundMode=1。紧邻检查为 callservicesd向tccd查询本App的kTCCServiceBluetoothAlways（请求30245.7），返回authValue=1、authReason=0；随后查询媒体状态Paused，再拒绝用户意图。16:21:26/29两次也重复同一序列。直接拒绝关卡已确认；ASK配件授权与通话服务通用蓝牙/用户意图检查之间的兼容问题为强推断，不能把隐私遮蔽的内部布尔条件当作已读到。详见 ASK-BACKGROUND-CALL-REPORT.md；未对外提交。

### 1.0.27 立即请求实验结果

用户 PID30713 在前台完成授权/连接，managerDidBegin已回调，再锁屏。16:21:26与16:21:28两次命令均走 immediate 路径；perform-start 距收到命令0.161/0.209秒，错误6发生于0.225/0.305秒。managerReady=true、conversations=0、有限后台任务已申请，麦克风授权为granted；NSError reason/debug/underlying均nil。由此排除网络预检等待是失败的必要条件、manager未就绪、旧manager会话数已满等解释。bluetoothAuth=0记录的是通用授权值，不能因ASK配件已可通信却通用授权未确定，就认定缺权限为根因。下一步需要系统日志；继续增加相同App层错误输出或无证据调整录音设置不能提供系统拒绝条件。USB不是唯一方式，可手机本机生成sysdiagnose后网络导出。

pymobiledevice3 11.55.0 已安装到仓库外独立 venv，syslog live 的过滤命令已检查。当前 USB 探测无法连接 usbmuxd；本机没有 Apple Mobile Device 服务。已通过 winget 从苹果官网下载 iTunes 12.13.12.3（SHA256 221a24203f6182b7dc0e18055b1e9338a0c3c992c7fefe6b3be0460caf29db4d），只提取 AppleMobileDeviceSupport64.msi，并检查签名为有效 Apple Inc.。安装退出1603，MSI明确记录当前进程没有全机安装管理员权限。未绕过系统权限。仓库外 builds/Install-Apple-USB-Support.cmd 已准备，需用户右键以管理员身份运行后连接并信任 iPhone，再执行 USB probe 和短时过滤抓取。尚未采集任何手机系统日志。
