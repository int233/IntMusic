# IntMusic Windows 服务

这个目录保留给 Windows 服务相关资料。当前 Windows 服务安装逻辑已经迁移到：

```text
packaging\windows-installer\
```

正式安装方式请使用 Windows 安装器：

```powershell
.\scripts\build-windows-installer.ps1
```

安装器选择“仅 Core”或“Core + 客户端”后会注册服务：

```text
服务名：IntMusicCore
显示名：IntMusic Core
启动类型：自动启动
```

服务程序：

```text
C:\Program Files\IntMusic\core\local-music-core-daemon.exe
```

服务数据目录：

```text
C:\ProgramData\IntMusic\Core
```

端口范围：

```text
TCP 49330-49360
UDP 5353
```

其中 TCP `49330-49360` 用于 Core API、WebSocket 和音频流；UDP `5353` 用于 mDNS 局域网发现。
