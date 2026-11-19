# iOS / ESP32 开发工作区

GitHub：`https://github.com/harlanyang888-hub/agent-relay-ios-shell`，当前开发分支 `feature/watch-ask-v3`。

| 位置 | 用途 |
| --- | --- |
| Windows `D:/ahk脚本/agent-relay-ios-voice-poc` | 当前主开发工作树；`AgentRelay/` 为 iOS，`firmware/watch/` 为 ESP32 |
| Ubuntu `/home/complicated/project/agent-relay-ios-watch` | 2026-11-19 新建的当前版本独立 Git 工作区，所有者 complicated，分支 `feature/watch-ask-v3` |
| Ubuntu `/home/complicated/project/agent-relay-ios-shell` | 原有旧工作区，`wearable-poc` 分支；保留，不覆盖，不用于判断当前固件进度 |
| Ubuntu `/home/complicated/project/agent-relay-next` | Agent Relay 平台旧开发工作区；存在本地改动，与 iOS/ESP32 仓库不同 |

此前最新代码主要推送 GitHub，没有同步到 Ubuntu 旧工作区。Ubuntu 新工作区已通过 Git bundle 同步，之后只在工作树干净且能快进时更新，不覆盖 Ubuntu 上的开发改动。它是开发代码目录，不是线上服务部署目录。平台的预设工作区列表和运行中的 connector 不随本次同步重启。

编译：iOS 使用 GitHub Actions 的 Mac/Xcode；ESP32 使用 ESP-IDF 5.5.1 的固件 CI。源码同步不等同于已在 Ubuntu 安装完整的 iOS 或 ESP-IDF 工具链。实机刷写目前在 Windows，通过 USB COM4，保留 NVS / 配对。

多机器开发：先在自己的机器提交并推送当前分支，另一台确认无本地改动后快进；不要在两个工作区同时对同一分支进行不同的未推送修改。需要同时开发时另建功能分支。
