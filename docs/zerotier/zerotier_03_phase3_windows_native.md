# 阶段 3：Windows 原生运行时接入

## 1. 目标

Windows 端不依赖系统已安装的 ZeroTier One，不依赖 CLI，也不依赖外部守护进程。目标是把 ZeroTier 节点作为应用自带的原生运行时能力接入到当前项目中。

## 2. 核心设计原则

- 应用内自带 ZeroTier 原生节点库
- 应用自己负责节点生命周期
- 应用自己负责网络状态观测
- 应用自己负责 Windows 防火墙规则管理
- Flutter 只通过原生桥接层调用，不直接碰系统命令

## 3. Windows 端需要实现的模块

### 3.1 `ZeroTierWindowsRuntime`

职责：

- 初始化 ZeroTier 原生节点
- 启动节点
- 停止节点
- 提供 Node ID
- 提供版本信息

### 3.2 `ZeroTierWindowsNetworkManager`

职责：

- 加入网络
- 离开网络
- 查询网络列表
- 监听网络状态
- 等待分配地址

### 3.3 `ZeroTierWindowsAdapterBridge`

职责：

- 处理虚拟网络接口
- 处理路由同步
- 处理地址更新
- 处理接口存活状态

### 3.4 `ZeroTierWindowsFirewallManager`

职责：

- 下发允许规则
- 删除规则
- 按 `ruleScopeId` 做规则隔离

### 3.5 `ZeroTierWindowsPlugin`

职责：

- 接收 Flutter `MethodChannel` 请求
- 发送运行时事件给 Flutter
- 统一返回 JSON 结构

## 4. Windows 原生开发技术栈

只列 Windows 原生接入阶段真正需要额外用到的技术栈，不重复写 Flutter 常规开发内容。

- `C++17`
  - 用于 Windows 原生运行时、插件桥接层、网络状态管理实现
- `CMake`
  - 用于原生代码编译、第三方库接入、目标链接配置
- `Visual Studio 2022 + Desktop development with C++`
  - 用于 Windows 原生构建、调试、符号查看
- `Windows SDK`
  - 用于防火墙、网络接口、系统网络相关 API
- `MethodChannel`
  - 用于 Flutter 与 Windows 原生命令调用
- `EventChannel`
  - 用于 Windows 原生运行时事件回流
- `libzt`
  - 用于在应用内嵌入 ZeroTier 原生节点运行时

## 5. Windows 开发环境

### 5.1 必需环境

- Visual Studio 2022
- Visual Studio 工作负载：`Desktop development with C++`
- Windows 10 或 Windows 11 SDK
- CMake
- Git

### 5.2 建议约束

- 首版只支持 `x64`
- 首版只维护 `Debug` 和 `Release`
- 原生依赖单独放在仓库内，例如 `third_party/libzt/`

## 6. 功能与依赖、技术栈对应关系

这一节只写“额外需要什么”，没有额外依赖的功能不展开写。

### 6.1 节点初始化、启动、停止、获取 Node ID

需要技术栈与依赖：

- `libzt`
  - 负责应用内 ZeroTier 节点生命周期
- `C++17`
  - 负责运行时对象封装
- `CMake`
  - 负责链接 `libzt`

对应模块：

- `ZeroTierWindowsRuntime`

### 6.2 加入网络、离开网络、查询网络状态、等待分配 IP

需要技术栈与依赖：

- `libzt`
  - 负责 join、leave、网络状态查询
- `C++17`
  - 负责状态轮询、超时控制、状态映射

对应模块：

- `ZeroTierWindowsNetworkManager`

### 6.3 虚拟网络接口、地址同步、路由同步

需要技术栈与依赖：

- `Windows SDK`
  - 用于网络接口和系统网络状态读取
- `C++17`
  - 用于封装接口信息与状态同步逻辑

对应模块：

- `ZeroTierWindowsAdapterBridge`

### 6.4 防火墙规则下发与清理

需要技术栈与依赖：

- `Windows SDK`
  - 用于 Windows 防火墙相关 API
- `C++17`
  - 用于规则对象封装和 `ruleScopeId` 规则隔离

对应模块：

- `ZeroTierWindowsFirewallManager`

### 6.5 Flutter 到 Windows 原生命令调用

需要技术栈与依赖：

- `MethodChannel`
  - 用于命令调用桥接

对应模块：

- `ZeroTierWindowsPlugin`

### 6.6 Windows 原生事件回流 Flutter

需要技术栈与依赖：

- `EventChannel`
  - 用于状态变化、错误、网络事件回流
- `C++17`
  - 用于事件对象组装和推送

对应模块：

- `ZeroTierWindowsPlugin`

### 6.7 原生依赖接入与构建产物管理

需要技术栈与依赖：

- `CMake`
  - 用于头文件、静态库或动态库、链接参数管理
- `Visual Studio 2022`
  - 用于本地构建与调试

使用场景：

- 接入 `libzt`
- 区分 Debug 和 Release 产物
- 管理第三方库输出目录

## 7. 需要对接的具体功能

### 7.1 环境准备

1. 加载应用内置原生库
2. 初始化节点运行目录
3. 初始化日志目录
4. 准备配置存储

### 7.2 节点启动

1. 原生层创建运行时对象
2. 启动 ZeroTier 节点
3. 监听节点在线状态
4. 回传 `nodeId`

### 7.3 网络加入

1. 接收 `joinNetworkAndWaitForIp`
2. 触发原生 join
3. 监听网络状态变化
4. 等待地址分配完成
5. 回传 `network_online`

### 7.4 网络退出

1. 执行 leave
2. 清理本地网络状态
3. 清理必要的防火墙规则

## 8. 与 Flutter 的接口建议

建议 Windows 插件至少实现：

- `detectStatus`
- `prepareEnvironment`
- `startNode`
- `stopNode`
- `joinNetworkAndWaitForIp`
- `leaveNetwork`
- `listNetworks`
- `applyFirewallRules`
- `removeFirewallRules`
- `watchRuntimeEvents`

## 9. Windows 开发时的关键难点

- 原生节点如何长期稳定运行
- 虚拟网卡与路由信息如何回流给应用
- 网络状态事件如何准确映射到 Dart 层
- 防火墙规则如何做精确增删

## 10. 本阶段建议实施顺序

1. 先完成 `ZeroTierWindowsRuntime`
2. 再完成网络状态读取和 join、leave
3. 再做事件回调
4. 最后补防火墙规则和诊断信息

## 11. 推荐的原生依赖落位

建议把 Windows 原生相关依赖和代码按下面方式放置：

- `third_party/libzt/`
  - 放 ZeroTier 原生库、头文件、构建产物
- `windows/native/zerotier/`
  - 放 Windows 原生运行时代码
- `windows/runner/`
  - 只保留 Runner 入口和插件注册接入

这样做的目的：

- Runner 不会被第三方依赖代码污染
- 原生运行时代码和 Flutter Runner 解耦
- 后续 CMake 接入更清晰

## 12. 本阶段完成标准

- 不安装 ZeroTier One 也能完成节点启动
- 不依赖 CLI 也能加网、退网、读状态
- Flutter 可拿到实时事件
- 服务端命令链在 Windows 端闭环跑通

## 13. 结论

Windows 阶段的本质不是“把 CLI 换个地方执行”，而是把 ZeroTier 节点真正内嵌进应用自己的原生运行时里。
