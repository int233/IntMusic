# IntMusic Flutter 客户端

这是 IntMusic 的跨平台图形客户端，目标平台包括 Windows、Linux、macOS 和 Android。

客户端职责：

- 浏览专辑、艺术家、歌曲、歌单、历史记录和统计。
- 搜索本地音乐库。
- 控制 Core 和其他客户端暴露的播放设备。
- 作为 renderer 注册到 Core，使当前客户端设备也可以播放音乐。
- 管理设置、语言、别名、音乐库目录和重新扫描。

客户端不直接访问数据库。所有资料库数据都来自 IntMusic Core API。

## 运行

```powershell
.\scripts\dev-shell.ps1
cd apps\client-flutter
flutter run -d windows
```

## 构建 Windows 客户端

```powershell
.\scripts\dev-shell.ps1
cd apps\client-flutter
flutter build windows --release
```

输出目录：

```text
apps\client-flutter\build\windows\x64\runner\Release\
```

正式 Windows 分发建议使用根目录的安装器脚本：

```powershell
.\scripts\build-windows-installer.ps1
```

## 构建 Android 客户端

```powershell
.\scripts\dev-shell.ps1
cd apps\client-flutter
flutter build apk --debug
```

输出文件：

```text
apps\client-flutter\build\app\outputs\flutter-apk\app-debug.apk
```

## Core 连接和端口

客户端默认从下面地址开始连接：

```text
http://127.0.0.1:49330
```

Core 默认会在 `49330-49360` 端口范围内自动选择可用端口。客户端会通过 mDNS 和端口扫描发现 Core，并通过 `/api/v1/status` 校验服务身份。

局域网连接示例：

```text
http://192.168.50.153:49347
```

如果 Android 或其他局域网客户端连接超时，请检查 Windows 防火墙是否允许 `IntMusic Core HTTP` 规则，以及服务端机器当前网络是否为“专用网络”。
