# IntMusic 发布构建和产物管理

本文档说明 IntMusic 的发布产物、统一归档目录，以及 macOS 签名/公证需要准备的内容。

## 产物目标

当前项目包含这些发布目标：

- Android 客户端：Flutter APK，必要时也生成 AAB。
- Windows 客户端：Flutter Windows release 目录压缩包。
- Windows Core：Core 可执行文件和内置 FFmpeg/ffprobe 的压缩包。
- Windows 安装程序：Inno Setup 生成的 `IntMusic-Windows-Setup.exe`。
- macOS 客户端：Flutter macOS `IntMusic.app` 压缩包。
- macOS/Linux Core：Core、内置 FFmpeg/ffprobe、许可证和对应源码归档。

统一归档目录为：

```text
packaging/dist/releases/<release-id>/
  android/
  macos/
  windows/
  manifest.json
  SHA256SUMS.txt
```

`manifest.json` 记录版本、Git SHA、构建时间、宿主系统和每个产物的 SHA-256。`SHA256SUMS.txt` 便于上传发布页后校验文件完整性。

## 构建限制

Flutter 桌面构建受宿主系统限制：

- macOS `.app`、Developer ID 签名和 Apple 公证必须在 macOS 上完成。
- Windows 桌面客户端和 Inno Setup 安装程序必须在 Windows 上完成。
- Android APK/AAB 可以在 macOS 或 Windows 上完成，只要 Android SDK、JDK 和 Flutter 配置正确。

因此“全量发布”推荐由两台宿主或 CI matrix 完成：

1. macOS runner 生成 `macos/` 和可选的 `android/`。
2. Windows runner 生成 `windows/`、安装器和可选的 `android/`。
3. 上传两个 runner 的 `packaging/dist/releases/<release-id>/` 内容到同一个发布目录或 GitHub Release。

## macOS 构建

在 macOS 上执行：

```bash
./scripts/build-release-artifacts.sh
```

默认会构建：

- `cargo build --release -p core-cli`
- LGPL-only FFmpeg 和 ffprobe
- `flutter build apk --release`
- `flutter build appbundle --release`
- `flutter build macos --release`

常用参数：

```bash
./scripts/build-release-artifacts.sh --skip-android
./scripts/build-release-artifacts.sh --skip-android-aab
./scripts/build-release-artifacts.sh --skip-bundled-ffmpeg
./scripts/build-release-artifacts.sh --release-id IntMusic-1.0.0-20260707
./scripts/build-release-artifacts.sh --output /tmp/IntMusic-release
```

## macOS 签名和公证

如果只在自己机器上运行，Flutter/Xcode 的本地签名通常够用。要分发给其他用户，需要 Developer ID 签名并建议公证。

Apple 官方入口：

- [Distributing software on macOS](https://developer.apple.com/macos/distribution/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Distribute outside the Mac App Store](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html)
- [Outgoing Connections entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)

需要准备：

- Apple Developer Program 账号。
- Xcode 和 Command Line Tools。
- `Developer ID Application` 证书安装在登录钥匙串中。
- App Store Connect API Key，或 `notarytool` 已保存的 keychain profile。
- 当前 app 的 bundle id：`dev.intmusic.intmusicClient`。
- macOS release entitlements：`apps/client-flutter/macos/Runner/Release.entitlements`。

检查可用签名身份：

```bash
security find-identity -v -p codesigning
```

保存公证凭据示例：

```bash
xcrun notarytool store-credentials "intmusic-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID1234" \
  --password "app-specific-password"
```

使用统一脚本签名：

```bash
./scripts/build-release-artifacts.sh \
  --skip-android \
  --sign-macos "Developer ID Application: Your Name (TEAMID1234)"
```

签名并公证：

```bash
./scripts/build-release-artifacts.sh \
  --skip-android \
  --sign-macos "Developer ID Application: Your Name (TEAMID1234)" \
  --notary-profile "intmusic-notary" \
  --notarize-macos
```

脚本会对 `IntMusic.app` 执行：

- `codesign --force --deep --timestamp --options runtime`
- `codesign --verify --deep --strict`
- `xcrun notarytool submit ... --wait`
- `xcrun stapler staple`
- 重新生成可分发 zip

macOS 客户端连接局域网 Core 需要 App Sandbox 出站网络权限。项目已在 release/debug entitlements 中加入：

```xml
<key>com.apple.security.network.client</key>
<true/>
```

## Windows 构建

在 Windows PowerShell 中执行：

```powershell
.\scripts\build-release-artifacts.ps1
```

默认会构建：

- Rust Core CLI 和 Core daemon。
- Flutter Windows release 客户端。
- Inno Setup 安装程序。
- Android APK 和 AAB。

常用参数：

```powershell
.\scripts\build-release-artifacts.ps1 -SkipAndroid
.\scripts\build-release-artifacts.ps1 -SkipAndroidAab
.\scripts\build-release-artifacts.ps1 -SkipInstaller
.\scripts\build-release-artifacts.ps1 -InstallInnoSetup
.\scripts\build-release-artifacts.ps1 -ReleaseId IntMusic-1.0.0-20260707
.\scripts\build-release-artifacts.ps1 -Output D:\release\IntMusic
```

Windows 安装器逻辑仍由 `scripts/build-windows-installer.ps1` 维护；统一发布脚本只负责调用它并收集产物。

## 内置 FFmpeg

Core 通过独立的 FFmpeg/ffprobe 进程完成分发转码，Flutter Client 不携带转码器。构建脚本固定使用 FFmpeg 8.1.2 源码及其 SHA-256，并使用不含 `--enable-gpl`、不含 `--enable-nonfree` 的配置进行编译。

Unix/macOS 可以单独准备工具包：

```bash
./scripts/build-bundled-ffmpeg.sh \
  --output "packaging/ffmpeg/macos-$(uname -m)"
```

Windows CI 使用 MSYS2 UCRT64 运行同一个脚本，并输出到：

```text
packaging\ffmpeg\windows-x64
```

Windows 产物会静态链接 MinGW 运行时，并在 `DEPENDENCIES.txt` 中记录
`ffmpeg.exe` 和 `ffprobe.exe` 的 PE 依赖。可以从普通 PowerShell 环境验证
工具包不依赖 MSYS2：

```powershell
.\scripts\test-windows-ffmpeg-bundle.ps1 `
  -Bundle packaging\ffmpeg\windows-x64
```

也可以通过 `INTMUSIC_FFMPEG_DIR` 指向已经验证的工具包。最终 Core 目录包含：

```text
core/
  local-music-core
  tools/ffmpeg/
    bin/ffmpeg
    bin/ffprobe
    LICENSE.LGPLv2.1.txt
    BUILD-CONFIG.txt
    DEPENDENCIES.txt        # Windows
    NOTICE.txt
    source/ffmpeg-8.1.2.tar.xz
```

安装后的 Core 优先查找自身旁边的 `tools/ffmpeg/bin`，不依赖服务账户的 `PATH`。发布包包含对应源码归档和构建配置；下载页和应用“关于/转码引擎”区域也应保留 FFmpeg LGPL 声明。

## Android 签名注意

当前 Android `release` build type 仍使用 debug signing config，适合内部测试安装，不适合作为正式商店分发包。

正式分发前需要：

- 生成并保管 upload keystore。
- 在 Android Gradle 配置中增加 release signing config。
- 使用 CI secret 或本地未提交的 `key.properties` 注入 keystore 路径和密码。
- 确认 `IntMusic-Android-*.aab` 由正式 upload key 签名。

## 推荐发布流程

1. 确认版本号：`apps/client-flutter/pubspec.yaml` 中的 `version`。
2. 在 macOS runner 运行 macOS 构建、签名、公证。
3. 在 Windows runner 运行 Windows 客户端、Core 和安装器构建。
4. 两边使用相同 `--release-id` 或 `-ReleaseId`。
5. 汇总 `packaging/dist/releases/<release-id>/` 下的内容。
6. 上传所有文件和 `SHA256SUMS.txt` 到 GitHub Release。
7. 在一台干净机器上验证：
   - macOS zip 解压后可打开，`spctl` 识别为 notarized Developer ID。
   - Windows 安装器可安装 Core + Client，服务能启动。
   - Android APK 可安装并能发现或连接 Core。

## GitHub Actions 自动编译

仓库包含两个自动化 workflow：

- `.github/workflows/ci.yml`：格式、lint 和测试检查。
- `.github/workflows/build.yml`：Ubuntu、Windows、macOS 三个平台的 release 编译。

`Build` workflow 会在 `push`、`pull_request` 和手动 `workflow_dispatch` 时运行：

- Ubuntu：构建带 FFmpeg 的 Rust Core 和 Flutter Linux 客户端，并上传 `intmusic-ubuntu` artifact。
- Windows：构建带 FFmpeg 的 Rust Core、Flutter Windows 客户端和 Inno Setup 安装器，并上传 `intmusic-windows` artifact。
- macOS：构建带 FFmpeg 的 Rust Core 和 Flutter macOS 客户端 zip，并上传 `intmusic-macos` artifact。

CI 中的 macOS 编译不会做 Developer ID 签名或 Apple 公证，因为这需要证书和 Apple 凭据。正式发布时仍建议在受控 macOS runner 或本地机器上运行带 `--sign-macos` 和 `--notarize-macos` 的发布脚本。
