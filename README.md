# FileTransferFlutter

一个面向“轻量网盘 + 局域网文件传输”场景的 Flutter 多平台客户端脚手架。

当前项目已经包含基础的分层结构、路由、状态管理，以及为文件、设备、传输、设置等模块预留的扩展空间，适合作为后续功能开发的基础工程。

## 当前包含内容

- 清晰的分层结构：`app`、`core`、`features`、`shared`
- `Riverpod` 状态管理入口
- `GoRouter` 路由管理
- 面向多模块演进的首页导航壳
- 文件、传输、设备、设置四个功能模块占位
- 面向后续扩展的服务接口与领域模型基础

## 目录结构

```text
lib/
  app/
    app.dart
    router/
    theme/
  core/
    constants/
    error/
    models/
    services/
  features/
    dashboard/
    devices/
    files/
    settings/
    transfers/
  shared/
    providers/
    widgets/
```

## 环境要求

在开始运行或打包前，请先确保本机已经安装并配置好以下环境：

- Flutter SDK
- Dart SDK（通常随 Flutter 一起提供）
- 对应平台的构建工具链

可先执行以下命令检查环境：

```bash
flutter --version
flutter doctor
```

安装依赖：

```bash
flutter pub get
```

查看当前可用设备：

```bash
flutter devices
```

## 各平台运行方式

### 通用运行

如果你已经连接了目标设备，或者当前只有一个默认设备，可以直接运行：

```bash
flutter run
```

### Android

前置条件：

- 安装 Android Studio 或 Android SDK
- 已配置 Android SDK / 模拟器
- 已连接真机，或已启动 Android Emulator

运行命令：

```bash
flutter run -d android
```

如果本机有多个 Android 设备，先查看设备列表再指定设备 ID：

```bash
flutter devices
flutter run -d <deviceId>
```

### iOS

前置条件：

- 只能在 macOS 上构建和运行
- 已安装 Xcode
- 已安装 CocoaPods
- 已启动 iOS Simulator，或连接 iPhone 并完成签名配置

运行命令：

```bash
flutter run -d ios
```

如果需要指定模拟器或真机：

```bash
flutter devices
flutter run -d <deviceId>
```

首次进入 iOS 目录后，如依赖有变化，可执行：

```bash
cd ios
pod install
cd ..
```

### Web

前置条件：

- Flutter 已启用 Web 支持
- 本机安装了 Chrome，或可用其他 Web 设备

运行命令：

```bash
flutter run -d chrome
```

如果需要使用 Web Server：

```bash
flutter run -d web-server
```

### Windows

前置条件：

- Windows 已启用桌面端支持
- 已安装 Visual Studio，并包含 Desktop development with C++ 组件

运行命令：

```bash
flutter run -d windows
```

### macOS

前置条件：

- 只能在 macOS 上运行
- 已安装 Xcode
- Flutter 已启用 macOS 桌面支持

运行命令：

```bash
flutter run -d macos
```

### Linux

前置条件：

- Flutter 已启用 Linux 桌面支持
- 已安装 GTK、clang、cmake、ninja 等桌面构建依赖

运行命令：

```bash
flutter run -d linux
```

## 各平台打包方式

### Android 打包

构建 APK：

```bash
flutter build apk
```

构建按架构拆分的 APK：

```bash
flutter build apk --split-per-abi
```

构建 AAB（应用商店发布推荐）：

```bash
flutter build appbundle
```

默认产物位置：

- APK：`build/app/outputs/flutter-apk/`
- AAB：`build/app/outputs/bundle/release/`

### iOS 打包

先生成 iOS Release 构建：

```bash
flutter build ios --release
```

如果只想生成归档所需工程，不自动签名：

```bash
flutter build ios --release --no-codesign
```

随后可使用 Xcode 打开 `ios/Runner.xcworkspace`，执行 Archive，并导出 `.ipa` 包。

说明：

- iOS 正式发布通常需要在 Xcode 中完成证书、描述文件和归档导出
- `.ipa` 导出流程依赖 Apple 签名体系，无法像 Android 一样只靠单条 Flutter 命令完整替代

### Web 打包

构建 Web 静态资源：

```bash
flutter build web
```

默认产物位置：

- `build/web/`

可将该目录部署到 Nginx、Apache、静态托管平台或对象存储站点中。

### Windows 打包

构建 Windows Release：

```bash
flutter build windows --release
```

默认产物位置：

- `build/windows/x64/runner/Release/`

通常可以将该目录整体分发，或进一步使用安装包工具制作 `.exe` / `.msi` 安装程序。

### macOS 打包

构建 macOS Release：

```bash
flutter build macos --release
```

默认产物位置：

- `build/macos/Build/Products/Release/`

如需对外分发，通常还需要：

- 应用签名
- 公证
- 制作 `.dmg` 或 `.pkg`

### Linux 打包

构建 Linux Release：

```bash
flutter build linux --release
```

默认产物位置：

- `build/linux/x64/release/bundle/`

一般可以将该目录整体打包分发，也可以结合目标发行版制作：

- `.deb`
- `.rpm`
- `AppImage`

## 常用命令

清理构建缓存：

```bash
flutter clean
```

重新安装依赖：

```bash
flutter pub get
```

运行测试：

```bash
flutter test
```

## 后续建议

1. 接入本地存储与文件索引
2. 设计局域网设备发现协议
3. 抽象传输任务队列与断点续传能力
4. 补充网络层、权限层与平台适配层
