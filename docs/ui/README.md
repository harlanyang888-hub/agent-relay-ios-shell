# Relay 语音手表 UI 文档与预览

本目录包含 Relay 语音手表原生 iPhone 设备控制页面的设计规范与浏览器静态预览：

- **设计规范与接线说明**：[design-spec.md](design-spec.md)
  - 视觉层次架构与规范
  - `WatchDashboardViewState` 状态字段定义与诚实电量规范
  - `WatchDashboardAction` 语义动作枚举与接线约定
  - Codex 接线指南与示例代码

- **浏览器可打开的 HTML 静态预览**：[preview.html](preview.html)
  - 采用无依赖独立设计，双击直接在任一浏览器中打开
  - 真实模拟 iPhone 15 Pro 外框与 Dynamic Island
  - 支持 6 种典型业务场景一键切换（空闲、录音中、草稿暂停、充电、断连与待发积压、电量过期）
  - 支持 iOS 暗色模式 (Dark Mode) / 浅色模式 (Light Mode) 实时切换
  - 提供交互反馈浮层（展示点击按钮触发的语义动作）
