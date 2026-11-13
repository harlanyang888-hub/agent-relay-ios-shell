# 快捷录音

安装新版 iOS 壳，在 App 中登录 Agent Relay。保留原快捷指令中的“连接 Tailscale”。

“开始录音”快捷指令接着添加两个动作：

1. URL：`agentrelay://record/start`
2. 打开 URL。

这会打开 Agent Relay 并开始原生录音。看到录音时长增长后，可以切换到其他 App 阅读或操作。无需让快捷指令等待录音完成。

另建“结束并发送”快捷指令：

1. URL：`agentrelay://record/stop`
2. 打开 URL。

也可以回到 Agent Relay，点击底部“结束并发送”。点击“取消录音”会丢弃本次文件。录音没有预设结束时限，不会在 90 秒时自动发送。

原快捷指令中的系统录音、格式化日期、保存文件、Base64 编码和 HTTP 上传步骤，由原生 App 接管。原录音会保留在“文件 → 我的 iPhone → Agent Relay → Recordings”，取消或启动失败的录音除外。

录音允许使用系统提供的蓝牙 HFP、USB 和有线麦克风输入，优先选择名称含 DJI 的输入。界面显示实际输入；如果显示 iPhone 麦克风，说明当前未使用大疆输入。蓝牙扫描能找到设备，不代表 iOS 已将它作为音频输入连接。

录音期间如被电话或其他录音打断，会提示中断且不自动发送。开始录音需要打开 App；这个入口不承诺锁屏后直接启动录音，也不包含蓝牙按键触发。

开始 URL 可以携带 `hostId`、`project`、`cwd`、`prompt`、`conversationId`、`title`。参数值需要 URL 编码；最近一次明确设置的参数会保存在本机并用于后续快捷录音。无参数且尚未配置时，沿用原生语音入口的默认目标。不要在 URL 中放 token、Cookie 或密码。
