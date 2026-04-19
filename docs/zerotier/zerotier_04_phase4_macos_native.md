# 阶段 4：macOS 原生运行时接入

## 1. 目标

macOS 端与 Windows 一样，不依赖已安装的 ZeroTier One，也不依赖 CLI。目标是通过原生运行时和系统网络扩展能力，把 ZeroTier 节点内嵌到应用自身。

## 2. 核心设计原则

- 应用内自带 ZeroTier 原生节点库
- 网络隧道与系统网络接口协同由原生层管理
- Flutter 不直接感知 macOS 网络细节
- 状态、日志、错误统一经原生桥接层回流

## 3. macOS 端需要实现的模块

### 3.1 `ZeroTierMacRuntime`

职责：

- 初始化 ZeroTier 节点
- 启动与停止节点
- 读取 Node ID
- 读取运行状态

### 3.2 `ZeroTierMacNetworkExtensionBridge`

职责：

- 处理系统网络扩展能力
- 协调隧道启动和停止
- 同步系统接口与路由状态

### 3.3 `ZeroTierMacNetworkManager`

职责：

- join / leave
- 网络状态同步
- 地址分配监听

### 3.4 `ZeroTierMacFirewallOrPolicyManager`

职责：

- 管理访问控制策略
- 管理应用层附加安全规则

### 3.5 `ZeroTierMacPlugin`

职责：

- 作为 Flutter 与原生层的唯一桥接入口

## 4. 需要对接的具体功能

### 4.1 环境准备

1. 初始化原生节点库
2. 初始化本地状态目录
3. 初始化日志目录
4. 准备网络扩展配置

### 4.2 节点启动

1. 创建运行时实例
2. 启动节点
3. 建立系统网络通道
4. 回传 `node_started`

### 4.3 网络加入

1. 执行 join
2. 监听网络授权状态
3. 监听地址分配状态
4. 更新路由与接口状态
5. 回传 `network_online`

### 4.4 网络退出

1. 执行 leave
2. 清理本地状态
3. 必要时清理附加策略

## 5. 与 Flutter 的接口建议

建议与 Windows 保持完全同构：

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

## 6. macOS 开发时的关键难点

- 原生节点与系统网络扩展的协同
- 隧道状态和系统接口状态同步
- 权限、签名、系统能力声明
- 事件回流和诊断输出

## 7. 本阶段建议实施顺序

1. 先完成节点运行时封装
2. 再完成网络扩展桥接
3. 再完成 join/leave 和地址分配监听
4. 最后补策略管理与诊断能力

## 8. 本阶段完成标准

- 不安装 ZeroTier One 也可运行
- 不依赖 CLI 也可完成加网和退网
- Flutter 能实时看到节点、网络、地址状态
- macOS 平台接入方式与 Windows 在 Dart 层完全对齐

## 9. 结论

macOS 阶段的重点不是复用桌面现成客户端，而是把“原生节点运行时 + 系统网络扩展协同”这层能力做完整。
