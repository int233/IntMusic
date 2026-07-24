# IntMusic Windows 安装器

这个目录包含 Windows 安装器脚本。打包流程会构建 Rust Core、Core 服务进程和 Flutter Windows 客户端，将产物整理到 staging 目录，然后用 Inno Setup 生成安装程序。

## 构建安装器

先在 MSYS2 UCRT64 shell 中构建固定版本、LGPL-only 的 FFmpeg 工具包：

```bash
./scripts/build-bundled-ffmpeg.sh \
  --output packaging/ffmpeg/windows-x64
```

GitHub Actions 会自动完成这一步；本地打包不会在缺少工具包时静默生成一个没有转码能力的 Core。

```powershell
.\scripts\build-windows-installer.ps1
```

如工具包位于其他目录，可明确指定：

```powershell
.\scripts\build-windows-installer.ps1 `
  -FfmpegBundle C:\path\to\ffmpeg-bundle
```

如果当前机器没有安装 Inno Setup，脚本仍会生成 staging 目录：

```text
packaging\dist\windows\
  client\IntMusic.exe
  core\local-music-core.exe
  core\local-music-core-daemon.exe
  core\tools\ffmpeg\bin\ffmpeg.exe
  core\tools\ffmpeg\bin\ffprobe.exe
```

安装 Inno Setup 6 或 7 后，重新运行同一个脚本即可生成安装器：

```text
packaging\dist\installer\IntMusic-Windows-Setup.exe
```

也可以让脚本通过 `winget` 安装 Inno Setup：

```powershell
.\scripts\build-windows-installer.ps1 -InstallInnoSetup
```

只准备 staging 目录、不生成安装器：

```powershell
.\scripts\build-windows-installer.ps1 -SkipInstaller
```

## 安装模式

安装器提供三种部署模式：

- 仅客户端：只安装 Flutter 桌面客户端。
- 仅 Core：只安装无界面 Core，并注册 `IntMusicCore` Windows 服务。
- Core + 客户端：同时安装 Core 服务和桌面客户端。

安装 Core 组件时，安装器会写入当前用户的环境变量：

- `INTMUSIC_HOME`
- `INTMUSIC_CORE_EXE`
- `INTMUSIC_CORE_SERVICE_EXE`

安装器也可以选择把 Core 目录加入当前用户的 `PATH`。

## Windows 服务

Core 服务信息：

```text
服务名：IntMusicCore
显示名：IntMusic Core
启动类型：自动启动
```

服务程序：

```text
C:\Program Files\IntMusic\core\local-music-core-daemon.exe
```

内置转码工具：

```text
C:\Program Files\IntMusic\core\tools\ffmpeg\bin\ffmpeg.exe
C:\Program Files\IntMusic\core\tools\ffmpeg\bin\ffprobe.exe
```

Core 服务从安装目录自动发现这两个程序，因此不依赖系统或服务账户的 `PATH`。

服务数据目录：

```text
C:\ProgramData\IntMusic\Core
```

Core 启动成功后会把当前实际监听地址写入：

```text
C:\ProgramData\IntMusic\Core\data\core-endpoint.json
```

完整安装模式的快捷方式会等待该端点通过 `/api/v1/status` 健康检查后再启动客户端，客户端也会优先读取该文件，不依赖上次保存的端口。

常用管理命令：

```powershell
Get-Service IntMusicCore
Start-Service IntMusicCore
Stop-Service IntMusicCore
Restart-Service IntMusicCore
```

## 端口和防火墙

Core 默认不固定使用单一端口，而是在 `49330-49360` 范围内自动选择可用端口：

```toml
[server]
bind = "0.0.0.0:49330"
auto_port = true
port_range_start = 49330
port_range_end = 49360
advertise_mdns = true
```

安装 Core 组件时会创建 Windows 防火墙入站允许规则：

```text
IntMusic Core HTTP       TCP 49330-49360
IntMusic Core Discovery  UDP 5353
```

TCP `49330-49360` 用于 HTTP API、WebSocket 和音频流；UDP `5353` 用于 mDNS 局域网发现。客户端发现 Core 后仍会访问 `/api/v1/status` 做校验。

如果局域网客户端连接超时，优先检查：

- `IntMusicCore` 服务是否正在运行。
- Windows 当前网络是否为“专用网络”或域网络。
- 防火墙规则 `IntMusic Core HTTP` 是否存在。
- 客户端使用的端口是否是 Core 当前实际监听端口。

服务注册、启动或健康检查失败时查看：

```text
C:\ProgramData\IntMusic\Core\install.log
C:\ProgramData\IntMusic\Core\service.log
```
