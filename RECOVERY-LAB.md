# 蓝牙恢复链路实验

保留稳定基线 1.0.21 (22)，不引入前台预建/暂停语音会话。实验在 `voice/restoration-lab`，专用 GATT 服务为 `A8D70200-6B44-4E93-A2D5-73F2A34B8180`，不同于原模拟器。测试版与原 App bundle ID 相同，需覆盖安装，稳定 IPA 保留以便恢复。两实验配置共享实验绑定缓存及固定 restoration ID，和正式基线缓存分开。

## 配置

- legacy：1.0.24 (25)，普通 CoreBluetooth，无 ASK plist 声明。先在 iOS 18 验证。
- ask：1.0.25 (26)，相同传输/录音代码，增加 ASK 授权。可在 iOS 18 做对照；用户强退后唤起仅在 iOS 26 验证。
- 两配置都不会提前建立系统语音会话。首次 START 才进入 LCK，录音时长持续增长后才确认 START 执行；STOP 确认表示已停止且有效音频上传已排队。HTTP accepted、会话 ID 和服务端消息才是发送成功证据。

## 电脑模拟器

`python -X utf8 tools/ble-recovery-simulator.py`，控制页 `http://127.0.0.1:8767/`。依赖沿用 builds/ble-simulator-deps。队列保存在仓库外 builds/ble-recovery-state.json，包含稳定的应用设备 ID、nonce、序号、待发命令、终态历史。Windows BLE 广播身份仍可能在进程重启后变化，不能把应用设备 ID 稳定当成已实现操作系统配对身份稳定；因此优先保持模拟器进程运行。

旧端口8766和新服务可能争用 Windows 广播资源。只能在旧端无订阅时停止旧模拟器，再启动新广播；明确显示广播 STARTED 才可搜索。停止广播不保证断开已有 BLE 连接，不把它标为“断链”。回到旧测试时仍可运行原 `ble-button-simulator.py`。

协议 v2 为16字节：AR、版本2、动作 START=1/STOP=2、nonce4、seq UInt32LE、过期时间 Unix 秒 UInt32LE。EVENT支持Read/Notify，ACK支持Write-with-response，应用设备ID支持Read。ACK为原命令16字节+状态1字节：1已执行、2失败、3过期、4已收到。收到不出队，终态才出队。队首每2秒重送，手机只执行一次；终态确认写丢时通过持久化收据补确认。命令默认120秒过期，过期不得启动录音；缓存不等于能补录断线期间的声音。START/STOP不用toggle，避免重复包把录音翻转。

这是受控实验协议，不宣称具备正式设备的配对加密或防伪认证。手机只处理当前选定连接；正式 ESP32 还需稳定可识别身份和设备认证，不能用服务 UUID 当密码。

## iOS 18 验收

1.0.22 真机首轮已证实：后台 START 执行确认、STOP 执行确认、13.23秒音频、HTTP 200 会话/消息 ID。第二轮失败：Windows 主循环卡在 Bluetooth COM 调用/对象结束路径，HTTP 状态查询也超时；不是未点击去重按钮造成。1.0.24 把异步操作、结果、请求和事件对象的末次释放移到专用线程，并将固定设备身份改为静态 GATT 值。此修正仍需手机连续多轮读写验证。

用户同时报告暂停后微信音频不可用。原日志有 didDeactivate，不能据此认定其他 App 已能用麦。新版暂停时立即停止录音确认定时器；专用 GATT 模式不再注册媒体键或保留 Now Playing；暂停后的异步回复不自动恢复音频；系统停用时清除输入偏好并记录路由。没有为此强制结束用户的系统会话。必须真机检查“停止并发送后，保持系统会话，微信播放语音和录制语音，再回来继续下一轮”。

已完成电脑侧检查：真实 Windows 广播启停与恢复、未连接时命令持久化排队和过期丢弃、HTTP 控制令牌校验。Windows 适配器在显式停止广播后报告过 ABORTED（error=0），随后恢复可回到 STARTED，因此不能仅按 STOPPED 数值判断是否成功停止。六项 Python 队列测试和 Swift 命令收据测试、现有 BLE 协议测试通过；两配置 IPA 编译通过（构建 43712941507，源码 6fd67fb）。这些不替代下面的手机实测。

1. 装legacy包，登录和麦克风授权，添加恢复按钮。只连接，不手动建立会话。
2. 锁屏，电脑点START，等历史显示已执行；说话后STOP。看手机解码、HTTP accepted及会话消息。
3. 录音中重发上条原编号。手机只补确认，不能停止或重新录音；正常STOP仍能发送。
4. 手机点“断链15秒”，确认电脑订阅变0；锁屏并在电脑点START。命令先缓存，15秒后重连、补交、真实录音、执行确认。此测试用有限后台任务完成定时重连，不冒称强退唤起已验证。
5. 手动划掉App，在电脑点START；在120秒内手动打开App。应出现新PID/运行标识、恢复连接、读取队首并录音。仅证明进程重建后的队列和状态恢复，不声称iOS18支持强退自动唤起。
6. 超过120秒再打开，过期START应不执行。停止、系统结束、上传成功与失败分别记录。
7. 换ASK包，重复普通锁屏首键。若再现错误6，记录它与legacy的差异，不把升级系统视为已证实修复。

## iOS 26验收

在上面通过后再升级实测。ASK授权目标设备、连接订阅完成后手动划掉，按电脑START。不得手动打开App。依次取证：新LAB BOOT（PID、run UUID、启动原因）→willRestoreState→实际重连/订阅→特定命令编号→采音时长增长→STOP→HTTP accepted→服务端消息。设备重启后首次解锁前的情况单独记录，不与日常锁屏混淆。

官方依据：
- https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules
- https://developer.apple.com/forums/thread/806013
- https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionenableautoreconnect
- https://developer.apple.com/forums/thread/840468

官方支持的是有条件的恢复资格，并不保证每次物理连接不断、每个按键已缓存或LCK一定成功。这些必须分别验收。
