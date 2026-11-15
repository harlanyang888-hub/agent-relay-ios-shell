# 穿戴语音会话生命周期（1.0.11）

已验证基线为 1.0.9 (10)，对应 c4c677b：电脑通过真实 BLE GATT 通知触发，已有 LCK 会话时，在锁屏及其他播放器播放情况下成功开始/停止。用户另测 DJI Mic Mini 2 HFP 输入，后台按钮录音解码 20.476 秒、有声音、停止后系统释放音频。

本轮待实机验证：无需手动建立会话，第一次专用按钮事件自动连接自己的 Agent Relay 并请求 LCK 开始采音。已有会话复用；连接/音频启动期间不排队重放按键。前台需先完成登录、麦克风授权及按钮绑定。网络或系统动作超时清理并允许用户重试；不得把后台权限提示当成成功。

移除启动时静音媒体待命；网页录音和设备页手动说话统一进入 LCK 控制。保留主网页外观，原设备测试入口更名穿戴设备，隐藏旧采样和独立语音测试页。设备页添加按钮、断开、结束会话、复制日志、麦克风授权和手动说话；首次硬件按键不需要用户手动点建立会话。

Cookie 随 WKWebView CookieStore 变化同步，只收集网关域名的未过期 Cookie，退出登录清理缓存。不记录认证内容。

需验证：无通话图标时后台/锁屏首键建立；播放器播放中首键建立；后续多轮开始停止；未登录/断网失败可重试；重开 App 已绑定按钮重连；用户结束会话后按钮再建立；上传、转写、回复播报。

iOS 18 手动划掉 App 后，普通 CoreBluetooth 恢复不能直接唤起。iOS 26 在通过 AccessorySetupKit 设置外设后新增相关唤起能力；升级本身不等于可用，也没有验证恢复进程后后台创建 LCK 会话的完整效果。不要向用户承诺已经解决强退唤起。

## 1.0.12 (13)：系统外设授权

新增 AccessorySetupKit 会话与系统设备选择器，按专用服务 UUID 匹配。首次用户确认后从系统 accessories 列表取回 Bluetooth identifier，并建立 CoreBluetooth 连接与通知订阅。启动时激活 ASK，恢复系统授权列表；继续保留相同 CoreBluetooth restoration identifier。主动断开保留授权，但持久暂停重连，添加/重连时解除暂停；系统移除授权则取消连接并清理本地 identifier。连接失败或断开后有受控重试，不依赖 service 缓存来决定是否重连。

首次升级需使用系统弹窗授权原有模拟器一次，旧的 App 内手动连接不是 ASK 授权。不要用变更 MAC 的陌生设备直接替换旧授权；Windows 模拟器重启可能更换身份，应先保持它运行，再测 App 生命周期。真实 ESP32 要实现稳定设备身份。

验收分开记录：iOS 18 系统授权/重开重连；iOS 26 强退后实际是否收到 BluetoothCentrals 启动键、ASK 授权恢复、重连/重新订阅、真实 BLE 按键触发后台建立 LCK。重启手机先完成首次解锁。断开、取消授权、蓝牙关闭、设备没电和认证失效不保证能采音。当前只完成代码接入与编译验证，不能当作强退录音已通过。

官方依据：
https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules
https://developer.apple.com/forums/thread/806013

当前仍是向正式流程收敛的开发版本，尚未完成全部生命周期与端到端验收。

## 1.0.13 (14)：修正系统授权入口

用户在 iOS 18.6.1 的 1.0.12 上遇到 ASErrorDomain 550（pickerRestricted），未能添加设备。修正为 ASK 先恢复系统授权，首次授权前不创建 CBCentralManager；显示选择器前释放旧管理器，授权后再建连接。引入单窗口 UIScene 生命周期，保留 URL 打开/快捷录音的前台延迟处理；选择器只在 active app + foregroundActive scene 时显示，失败记录系统 error userInfo。加上 service UUID + name 的发现过滤及对应 plist 声明（电脑 RN12108，未来设备 AgentRelay 前缀）。

必须实测系统授权弹窗，以及升级后的页面/URL 打开、后台 BLE 恢复。550 的唯一根因尚未在设备上确认，不把编译成功当成修复已验收。
