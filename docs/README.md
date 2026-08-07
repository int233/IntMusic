# IntMusic 文档中心

这里保存 IntMusic 的产品、架构和使用文档。顶层 [README](../README.md) 是完整的产品主页，包含功能介绍、界面截图和快速开始；本目录进一步拆分架构约束、详细能力和日常操作，便于按主题维护与查阅。

## 推荐阅读顺序

| 文档 | 面向读者 | 内容 |
| --- | --- | --- |
| [使用手册](user-guide.md) | 普通用户、测试人员 | 安装、连接、添加音乐、播放、离线、分发、维护与排错 |
| [详细功能](features.md) | 用户、产品设计、测试人员 | 当前功能边界、交互入口、预期行为与 macOS 功能截图 |
| [总体架构](architecture.md) | 开发者、维护者 | Core/Client 职责、音乐身份、数据同步、播放与平台结构 |
| [Client v2 架构约束](client-v2-architecture.md) | Client 开发者 | Flutter 分层、状态归属、平台桥接、性能预算与合并门槛 |
| [弱网与离线架构](client-core-resilience-v3.md) | 协议与播放开发者 | 连接状态机、本地投影、播放会话、命令幂等与迁移计划 |
| [发布与签名](../packaging/README.md) | 发布维护者 | 跨平台构建、产物、FFmpeg、签名、公证和 CI |

## 文档职责

- `architecture.md` 描述系统为什么这样划分，以及跨模块必须遵守的长期约束。
- `features.md` 描述产品具备什么能力，以及相应功能应表现为何种行为。
- `user-guide.md` 描述用户应该怎样完成任务，不依赖阅读源代码。
- 专题文档可以深入某个版本或子系统，但不应重复维护安装和入门步骤。

当实现与文档不一致时，应在同一个提交中修正文档。新增 API、事件或跨平台能力时，还需要同步更新 `crates/protocol/openapi.yaml`、`crates/protocol/events.schema.json` 或平台能力矩阵。

## 项目状态

IntMusic 1.2 仍处于开发阶段。数据库迁移会由 Core 自动执行，但在测试新版本前仍应备份 `library.sqlite3`，并为原始音乐文件保留独立备份。Client 本地缓存可以重建，不能替代 Core 数据库或音乐文件备份。
