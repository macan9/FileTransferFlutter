# FileTransferFlutter

一个面向“简化版网盘 + 局域网文件传输”的 Flutter 客户端初始化脚手架。

## 当前骨架包含

- 清晰的分层结构：`app`、`core`、`features`、`shared`
- `Riverpod` 状态管理入口
- `GoRouter` 路由管理
- 适合多模块演进的首页导航壳
- 文件、传输、设备、设置四个功能模块占位
- 面向后续扩展的服务接口与领域模型占位

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

## 启动前准备

当前机器环境里还没有可用的 `flutter` 命令，所以本次是手工搭建项目骨架。

你本地安装并配置好 Flutter SDK 后，执行：

```bash
flutter pub get
flutter run
```

跑 Windows 桌面
```bash
flutter run -d windows
```

跑 Android
```bash
flutter devices
flutter run -d <deviceId>
```

## 建议下一步

1. 接入本地存储与文件索引
2. 设计局域网设备发现协议
3. 抽象传输任务队列与断点续传
4. 加入网络层、权限层、平台适配层
