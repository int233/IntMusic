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

安装或升级开始前，安装器会根据所选组件：

- 向正在运行的客户端发送正常退出请求；旧版客户端不响应时，仅终止安装目录中的 `IntMusic.exe`。
- 停止 `IntMusicCore` 服务并等待服务确实进入 `Stopped` 状态。
- 遇到旧 Core 的 Windows 1061 控制通道故障时，临时关闭服务恢复策略，并只按已核验的安装目录和服务 PID 终止旧 daemon；新服务安装后会恢复自动启动与故障恢复。
- 清理安装目录中残留的 Core CLI/daemon 进程，避免新文件被旧进程锁定。

停止过程最多等待 45 秒；失败时安装会中止，而不是在程序仍运行时继续覆盖文件。诊断日志位于：

```text
C:\ProgramData\IntMusic\Installer\install.log
```

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

安装桌面客户端后，也可以右键任务栏通知区域的 IntMusic 图标：

- 显示或隐藏客户端。
- 播放/暂停、上一首、下一首。
- 查看 Core 服务当前状态。
- 启动、重启或停止 Core 服务。
- 完全退出客户端。

Core 服务控制需要管理员权限，Windows 会显示 UAC 确认窗口；拒绝提权不会改变服务状态。

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
