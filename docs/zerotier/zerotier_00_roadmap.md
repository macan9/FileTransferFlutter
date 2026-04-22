# ZeroTier 原生接入文档总览

## 1. 分类方式

本轮文档不再按“公共逻辑 / 平台”平铺分类，而是改成按实际开发顺序分类。这样阅读顺序、设计顺序、实施顺序保持一致。

## 2. 开发顺序

1. 阶段 1：统一架构与接口边界
2. 阶段 2：Flutter 编排层与调用链改造
3. 阶段 3：Windows 原生运行时接入
4. 阶段 4：macOS 原生运行时接入
5. 阶段 5：Android 原生运行时接入
6. 阶段 6：iOS 原生运行时接入

## 3. 文档列表

1. `zerotier_01_phase1_architecture.md`
2. `zerotier_02_phase2_flutter_runtime.md`
3. `zerotier_03_phase3_windows_native.md`
4. `zerotier_04_phase4_macos_native.md`
5. `zerotier_05_phase5_android_native.md`
6. `zerotier_06_phase6_ios_native.md`
7. `zerotier_07_join_leave_flow.md`

## 4. 当前调整重点

- Windows 不再依赖已安装 ZeroTier One 或 CLI。
- macOS 不再依赖已安装 ZeroTier One 或 CLI。
- 桌面端统一改为“应用内自带原生 ZeroTier 节点运行时”思路。
- Flutter 层仍保持统一编排，平台差异全部收口到原生实现层。

## 5. 与当前仓库的对应入口

- `lib/core/services/zerotier_local_service.dart`
- `lib/features/networking/presentation/providers/networking_agent_provider.dart`
- `lib/core/services/networking_service.dart`
- `lib/features/networking/presentation/providers/networking_providers.dart`

## 6. 推荐阅读方式

建议严格按阶段阅读，不要直接先看某个平台。

原因很简单：

- 阶段 1 决定接口边界
- 阶段 2 决定 Flutter 怎么调用
- 阶段 3 到 6 才是各平台如何实现

如果跳过前两阶段，后面平台实现很容易各写各的，最终又要回头改 Dart 层抽象。
