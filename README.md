# IntMusic 本地音乐系统

IntMusic 是一个本地音乐资料库和多设备播放系统。当前架构由无界面的 Core 服务和多个图形客户端组成：Core 负责资料库、扫描、搜索、播放状态、播放设备和 API；客户端负责浏览、控制、播放界面。

本项目完全通过Codex开发。

## 项目结构

```text
crates/
  core-cli/        local-music-core 命令行管理入口
  core-daemon/     local-music-core-daemon 服务入口，用于 Windows 服务
  core-api/        HTTP API、WebSocket 事件和 Core 运行时
  core-db/         SQLite 数据库迁移和数据访问
  library-scanner/ MP3/FLAC 扫描、标签读取、歌词和封面提取
  search-index/    SQLite FTS 和 CJK n-gram 搜索索引
  audio-engine/    解码和 PCM/DSP 抽象
  output-cpal/     本机输出设备发现
  playback/        播放状态和播放控制
  protocol/        OpenAPI、事件 schema、共享 DTO
apps/
  client-flutter/  Windows、Linux、macOS、Android 客户端
  client-harmony/  HarmonyOS ArkTS/ArkUI 客户端骨架
packaging/
  windows-installer/ Windows 安装器和服务注册脚本
```

客户端 v2 的状态归属、跨平台边界、原生能力矩阵和合并门槛见
[docs/client-v2-architecture.md](docs/client-v2-architecture.md)。

## 开发环境

打开新的 PowerShell 后先执行：

```powershell
.\scripts\dev-shell.ps1
```

这个脚本会把 Rust/Cargo、Flutter、Android SDK、JDK、DevEco Studio 加入当前终端的 `PATH`。也可以执行完整环境检查：

```powershell
.\scripts\check-env.ps1
```

## 运行 Core

开发模式：

```powershell
.\scripts\run-core.ps1
```

或手动运行：

```powershell
.\scripts\dev-shell.ps1
cargo run -p core-cli -- serve
```

正式 Windows 部署建议使用安装器安装“仅 Core”或“Core + 客户端”，此时 Core 会注册为 `IntMusicCore` Windows 服务并开机自动启动。

## 端口和局域网发现

IntMusic Core 不再使用固定单一端口。当前默认配置是：

```toml
[server]
bind = "0.0.0.0:49330"
auto_port = true
port_range_start = 49330
port_range_end = 49360
advertise_mdns = true
```

当 `auto_port = true` 时，Core 会在 `49330-49360` 范围内选择一个可用端口监听。监听地址是 `0.0.0.0`，因此同一个 Core 同时支持本机访问和局域网访问。

示例：

```text
本机访问：http://127.0.0.1:49347
局域网访问：http://192.168.50.153:49347
```

实际端口以 Core 启动日志、客户端发现结果或 `/api/v1/status` 为准。客户端会先尝试 mDNS 服务 `_intmusic-core._tcp.local.`，再扫描 `49330-49360` 端口范围，并通过 `/api/v1/status` 校验对方确实是 IntMusic Core，避免误连到其他程序。

Windows 安装器会在安装 Core 组件时创建防火墙入站规则：

```text
IntMusic Core HTTP       TCP 49330-49360
IntMusic Core Discovery  UDP 5353
```

如果局域网其他客户端能发现地址但连接超时，优先检查 Windows 防火墙、网络类型是否为“专用网络”，以及 `IntMusicCore` 服务是否正在运行。

## 添加并扫描音乐库

推荐在客户端 `Settings -> Music folders` 中添加音乐文件夹并点击重新扫描。注意：这里填写的是 Core 所在机器能访问到的路径。

也可以使用命令行：

```powershell
.\scripts\dev-shell.ps1
cargo run -p core-cli -- library add F:/Music
cargo run -p core-cli -- scan start
```

常用 CLI：

```powershell
cargo run -p core-cli -- status
cargo run -p core-cli -- library list
cargo run -p core-cli -- outputs list
cargo run -p core-cli -- playback play <track_id>
cargo run -p core-cli -- playback pause
cargo run -p core-cli -- playback stop
```

## 运行 Flutter 客户端

开发模式：

```powershell
.\scripts\dev-shell.ps1
cd apps\client-flutter
flutter run -d windows
```

客户端默认从 `http://127.0.0.1:49330` 开始尝试连接，并会通过 mDNS 和端口扫描发现局域网 Core。

## Windows 安装器

生成安装器：

```powershell
.\scripts\build-windows-installer.ps1
```

输出文件：

```text
packaging\dist\installer\IntMusic-Windows-Setup.exe
```

安装器提供三种模式：

```text
仅客户端        只安装桌面客户端
仅 Core         只安装无界面 Core，并注册 IntMusicCore 服务
Core + 客户端   同时安装 Core 服务和桌面客户端
```

## 发布构建和产物归档

发布构建统一归档到：

```text
packaging/dist/releases/<release-id>/
```

macOS 主机：

```bash
./scripts/build-release-artifacts.sh
```

Windows 主机：

```powershell
.\scripts\build-release-artifacts.ps1
```

更多关于 macOS 签名/公证、Android/Windows/macOS 产物结构和校验文件的信息见 [packaging/README.md](packaging/README.md)。

## 多端播放模型

当前播放模型已经把 Core 和客户端都视为可播放节点：

- Core 本机保留 `local` zone，也会暴露本机 CPAL 输出，例如 `cpal:0`、`cpal:1`。
- Flutter 客户端启动后会注册为远端 renderer，并暴露 `renderer:<client>:default` zone。
- 每个输出设备都是独立 zone，可以选中不同 zone 后播放不同音乐。
- Playback 页是统一播放中心，负责当前歌曲控制、seek、歌曲详情、歌词滚动、zone 选择、暂停、恢复、停止、移动到指定设备、同播到所有在线设备。
- 切换播放设备调用 `/api/v1/zones/{zone_id}/transfer`。
- 同时在多个设备播放调用 `/api/v1/zones/play-many`。
- 远端客户端通过 WebSocket 接收 Core 下发的 play、pause、stop、seek 命令，再从 `/api/v1/tracks/{track_id}/stream` 拉取音频流本地播放。

## 验证

```powershell
.\scripts\dev-shell.ps1
cargo fmt --all
cargo check --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd apps\client-flutter
flutter analyze
flutter test
```
