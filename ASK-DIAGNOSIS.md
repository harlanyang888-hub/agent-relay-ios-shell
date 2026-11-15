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

## 本机抓取环境

pymobiledevice3 11.55.0 已安装到仓库外独立 venv，syslog live 的过滤命令已检查。当前 USB 探测无法连接 usbmuxd；本机没有 Apple Mobile Device 服务。已通过 winget 从苹果官网下载 iTunes 12.13.12.3（SHA256 221a24203f6182b7dc0e18055b1e9338a0c3c992c7fefe6b3be0460caf29db4d），只提取 AppleMobileDeviceSupport64.msi，并检查签名为有效 Apple Inc.。安装退出1603，MSI明确记录当前进程没有全机安装管理员权限。未绕过系统权限。仓库外 builds/Install-Apple-USB-Support.cmd 已准备，需用户右键以管理员身份运行后连接并信任 iPhone，再执行 USB probe 和短时过滤抓取。尚未采集任何手机系统日志。
