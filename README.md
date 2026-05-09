# FileTransferFlutter

## 启动与打包速查（置顶）

### 一次看全命令

```bash
# 启动（自动选择当前设备）
flutter run

# 启动（重点平台）
flutter run -d android
flutter run -d ios
flutter run -d windows
flutter run -d macos

# 启动（次要平台：浏览器 / Linux）
flutter run -d chrome
flutter run -d web-server
flutter run -d linux

# 打包（重点平台）
flutter build apk
flutter build appbundle
flutter build ios --release
flutter build windows --release
flutter build macos --release

# 打包（次要平台：浏览器 / Linux）
flutter build web
flutter build linux --release
```

### 补充说明（精简）

- 多设备时先执行 `flutter devices`，再用 `flutter run -d <deviceId>` 指定设备
- iOS 首次或依赖变更时执行：

```bash
cd ios
pod install
cd ..
```

- iOS 正式发布通常还需在 Xcode 完成签名与 Archive 导出 `.ipa`

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
