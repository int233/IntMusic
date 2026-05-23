# IntMusic HarmonyOS 客户端

HarmonyOS 客户端使用 ArkTS / ArkUI 单独实现，不复用 Flutter UI 代码。

共享边界：

- HTTP API: `crates/protocol/openapi.yaml`
- WebSocket events: `crates/protocol/events.schema.json`
- Design tokens: `crates/protocol/design_tokens.json`

DevEco Studio 安装后，可在此目录补齐完整工程文件并按同一协议实现连接、配对、资料库浏览、搜索、播放控制、队列、歌词和设置。
