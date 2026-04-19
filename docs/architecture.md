# 项目架构说明

## 1. 文档目的

这份文档用于说明当前项目的整体目标、目录职责、推荐分层方式，以及接下来适合继续推进的方向。它不是一份死板的规范，而是一份帮助我们统一理解项目结构的说明书。

## 2. 项目当前目标

当前项目的核心目标有三类：

1. 支持类似私有云的文件浏览、管理和传输
2. 支持局域网设备发现和点对点文件传输
3. 保持移动端、桌面端、平板端尽可能共享大部分业务逻辑

换句话说，这个项目不是单纯做一个文件列表页面，而是在逐步搭一个“本地文件传输 + 内网互联 + 后续可扩展到 ZeroTier 组网”的跨平台客户端。

## 3. 当前目录职责

目前仓库里的核心目录可以这样理解：

- `lib/app/`
  - 放应用壳层内容，比如应用入口、路由、主题
- `lib/core/`
  - 放跨业务复用的基础能力，比如模型、错误定义、通用服务、配置
- `lib/features/`
  - 放按业务域拆分的功能模块，例如文件、设备、网络、传输
- `lib/shared/`
  - 放跨多个功能复用的 Provider 和 Widget
- `android/`、`ios/`、`macos/`、`windows/`、`linux/`
  - 放各平台原生工程
- `docs/`
  - 放项目文档

## 4. 推荐的业务分层

随着功能继续变复杂，建议每个功能模块逐步往下面这个结构演进：

```text
features/<feature>/
  data/
    datasources/
    models/
    repositories/
  domain/
    entities/
    repositories/
    usecases/
  presentation/
    pages/
    providers/
    widgets/
```

这套结构的意思很简单：

- `data/`
  - 负责和外部系统打交道，比如 HTTP、本地存储、原生接口
- `domain/`
  - 负责业务规则和抽象
- `presentation/`
  - 负责页面、状态管理、交互展示

不是要求现在立刻把所有代码都改成这样，而是后续新增复杂功能时，尽量按这个方向落。

## 5. 当前项目已经形成的结构特点

从现有代码看，项目已经有一些比较明确的分工：

### 5.1 应用壳层

- `lib/app/app.dart`
- `lib/app/router/`
- `lib/app/theme/`

这一层主要负责：

- 应用启动
- 页面路由
- 全局主题

### 5.2 基础服务层

- `lib/core/services/`
- `lib/core/models/`
- `lib/core/config/`

这一层主要负责：

- 网络服务封装
- 配置读取与持久化
- 共享模型定义
- ZeroTier 本地服务抽象

### 5.3 业务模块层

- `lib/features/files/`
- `lib/features/devices/`
- `lib/features/networking/`
- `lib/features/transfers/`
- `lib/features/settings/`
- `lib/features/dashboard/`

这一层主要负责：

- 页面功能拆分
- 各业务域自己的状态和交互

### 5.4 共享层

- `lib/shared/widgets/`
- `lib/shared/providers/`

这一层主要负责：

- 通用 UI 组件
- 跨模块复用的 Provider

## 6. 当前架构上的一个重点

这个项目现在最关键的演进点，其实是“网络能力和本地运行时”的收口。

尤其是 ZeroTier 相关能力，已经出现了两层明显分工：

1. 服务端控制面
   - 负责 bootstrap、heartbeat、命令下发、ack
2. 客户端本地运行时
   - 负责本机网络能力、加网、退网、状态探测、权限与安全控制

这也是为什么后续 ZeroTier 文档被单独整理到 `docs/zerotier/` 目录中，因为它已经不是一个零散功能点，而是一条完整的跨平台能力线。

## 7. 当前建议保留的架构原则

后续继续开发时，建议尽量遵守下面几条：

### 7.1 页面不要直接操作底层细节

页面只关心：

- 当前状态是什么
- 用户触发了什么动作
- 结果如何反馈

页面不应直接处理：

- 原生命令格式
- HTTP 参数细节
- 本地存储结构

### 7.2 通用能力尽量收口到 `core/`

例如：

- 配置读取
- 网络服务
- ZeroTier 运行时抽象
- 错误模型

只要某个能力会被多个功能模块共享，就优先考虑放到 `core/`。

### 7.3 功能差异尽量收口到 `features/`

例如：

- 文件页自己的交互逻辑
- 网络页自己的状态展示
- 传输页自己的任务列表

不要把所有业务判断都塞进 `shared/`。

### 7.4 平台差异尽量收口到原生层

Flutter 层应尽量看到统一接口，而不是直接处理：

- Windows 怎么做
- macOS 怎么做
- Android 怎么做
- iOS 怎么做

这条原则对于 ZeroTier 原生接入尤其重要。

## 8. 接下来适合继续推进的方向

结合当前仓库现状，后续比较值得推进的方向有这些：

1. 完善 ZeroTier 统一运行时抽象
2. 补强 Flutter 到原生层的桥接接口
3. 逐平台实现原生网络运行时
4. 增加更稳定的本地持久化层
5. 增加日志、诊断、错误追踪能力
6. 为关键链路补测试

## 9. 文档导航

如果你接下来要看 ZeroTier 相关设计，请直接看：

- `docs/zerotier/zerotier_00_roadmap.md`
- `docs/zerotier/zerotier_01_phase1_architecture.md`
- `docs/zerotier/zerotier_02_phase2_flutter_runtime.md`
- `docs/zerotier/zerotier_03_phase3_windows_native.md`
- `docs/zerotier/zerotier_04_phase4_macos_native.md`
- `docs/zerotier/zerotier_05_phase5_android_native.md`
- `docs/zerotier/zerotier_06_phase6_ios_native.md`

## 10. 总结

当前项目的主线已经比较清楚：

- `app` 负责应用壳
- `core` 负责基础抽象
- `features` 负责业务模块
- `shared` 负责复用能力
- `docs` 负责设计和约定沉淀

后续只要继续沿着“业务逻辑统一、平台差异收口、运行时能力抽象清晰”这条路线推进，项目结构会越来越稳，不会越做越乱。
