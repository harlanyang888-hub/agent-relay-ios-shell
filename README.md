# Agent Relay iOS Shell & 智能穿戴按键 PoC 验证

本项目为 Agent Relay 专属 iOS 客户端，包含**智能穿戴按键 PoC 验证**与**原生 Web 沉浸容器**两大核心模块。

## 🎯 智能穿戴 PoC 验证目标
随身佩戴普通实体按键蓝牙耳机，验证当耳机连接 iPhone 时：
- App 在**后台/锁屏状态**下能否持续捕获耳机的实体按键硬件事件（AVRCP 协议指令）；
- 捕获到按键后，手机产生震动反馈并向耳机发声提示音，且记录精确时间戳与按键类型。

### 核心实现原理
1. **音频后台模式 (Background Audio)**：在 `Info.plist` 中声明 `audio` 模式，允许进程在后台/锁屏常驻。
2. **静音底噪保活 (Silent Audio Loop)**：通过 Swift 内存动态合成 1 秒微振幅静音 PCM 音频循环播放，使系统持续将本应用判定为活跃的 `Now Playing App`，防止媒体控制权被锁屏或系统音乐抢占。
3. **硬件事件拦截 (MPRemoteCommandCenter)**：挂载 `togglePlayPauseCommand`、`playCommand`、`pauseCommand`、`nextTrackCommand`、`previousTrackCommand`，全量捕获单击/双击/三击。
4. **即时体感与听觉反馈**：调用 `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` 触发 iPhone 震动，并通过合成正弦波短音与系统音效向蓝牙耳机输出“哔”提示音。

## 📱 极简验证步骤
1. 佩戴蓝牙耳机并连接 iPhone；
2. 打开 App，首屏即为【穿戴验证】界面；
3. 确认上方状态栏识别出当前蓝牙耳机设备名称；
4. 点击【▶ 启动穿戴按键监听 (后台保活)】；
5. 按手机电源键使 iPhone 进入**黑屏锁屏状态**（或返回桌面）；
6. 按下手头蓝牙耳机上的实体按键（单击或双击）；
7. **验证成功现象**：裤兜/手里的 iPhone 震动，且耳机里发出清脆的提示音！
8. 解锁点开 App，可在实时日志列表中查看捕获的时间戳、按键事件与前后台状态。

## 🛠 云编译打包 IPA
推送本仓库至 GitHub 后，GitHub Actions (`.github/workflows/build-ipa.yml`) 会在 `macos-14` 虚拟机上全自动执行 `xcodebuild`，免证书生成未签名的 `AgentRelay.ipa`：
- 构建完成后可在 Actions 的 **Artifacts** 中下载 `AgentRelay-unsigned-ipa`；
- 或直接在 Releases 页面获取最新版本的 `AgentRelay.ipa`；
- 使用设备端自签工具（如 Feather、TrollStore、AltStore 或自签证书）直接安装至 iPhone 即可开测。
