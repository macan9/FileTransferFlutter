# 阶段 1：统一架构与接口边界

## 1. 目标

在任何平台实现开始前，先冻结一套统一的 ZeroTier 运行时抽象。这里的重点不是某个平台怎么写，而是先明确 Flutter、服务端控制面、原生节点运行时之间的边界。

## 2. 当前项目现状

当前仓库已经有一条可复用的业务链：

- `ZeroTierLocalService` 负责本地 ZeroTier 动作
- `NetworkingAgentRuntimeController` 负责本机 Agent 生命周期
- `NetworkingService` 负责与服务端控制面通信

这说明真正要重构的是本地执行层，而不是整条业务链。

## 3. 架构总图

```text
Flutter UI
  -> Riverpod Runtime Controller
  -> ZeroTierFacade
  -> ZeroTierPlatformApi
  -> MethodChannel / EventChannel
  -> Native ZeroTier Runtime
  -> OS Network Capability

Service Control Plane
  -> bootstrap / heartbeat / command / ack
```

## 4. 必须先统一的公共能力

### 4.1 节点生命周期

- 初始化节点
- 启动节点
- 停止节点
- 获取节点状态
- 获取 Node ID
- 获取版本信息

### 4.2 网络生命周期

- 加入网络
- 离开网络
- 查询网络列表
- 查询网络授权状态
- 查询分配地址

### 4.3 平台安全能力

- 权限检测
- 权限引导
- 防火墙或访问规则下发
- 安全规则清理

### 4.4 运行时观测能力

- 节点是否在线
- 网络是否可用
- 是否已分配 IP
- 最近一次错误
- 诊断日志

## 5. 统一 Dart 接口建议

建议把现有 `ZeroTierLocalService` 演进为下面这组能力：

- `detectStatus()`
- `prepareEnvironment()`
- `startNode()`
- `stopNode()`
- `joinNetworkAndWaitForIp(networkId)`
- `leaveNetwork(networkId)`
- `listNetworks()`
- `getNetworkDetail(networkId)`
- `applyFirewallRules(...)`
- `removeFirewallRules(...)`
- `watchRuntimeEvents()`

## 6. 建议统一的数据模型

### 6.1 `ZeroTierRuntimeStatus`

至少包含：

- `nodeId`
- `version`
- `serviceState`
- `permissionState`
- `isNodeRunning`
- `joinedNetworks`
- `lastError`
- `updatedAt`

### 6.2 `ZeroTierNetworkState`

至少包含：

- `networkId`
- `networkName`
- `status`
- `assignedAddresses`
- `isAuthorized`
- `isConnected`

### 6.3 `ZeroTierRuntimeEvent`

建议统一这些事件：

- `environment_ready`
- `permission_required`
- `node_started`
- `node_stopped`
- `network_joining`
- `network_waiting_authorization`
- `network_online`
- `network_left`
- `ip_assigned`
- `error`

## 7. 与服务端控制面的标准对接方式

### 7.1 首次注册

1. 本地检测 ZeroTier 环境
2. 启动本地节点
3. 获取 `nodeId`
4. 调 `bootstrapDevice`
5. 保存 `deviceId`、`agentToken`、`zeroTierNodeId`

### 7.2 常驻运行

1. 定时心跳
2. 定时拉命令
3. 执行本地 ZeroTier 动作
4. 回执命令执行结果

## 8. 本阶段交付物

这一阶段不写平台代码，重点产出这些东西：

1. Dart 抽象接口
2. 统一状态模型
3. 统一事件模型
4. 统一错误模型
5. 原生桥接协议清单

## 9. 完成标准

只有下面这些问题都明确了，才进入平台开发：

- Flutter 到原生到底有哪些方法
- 原生回流给 Flutter 哪些事件
- 服务端命令怎么映射到本地能力
- 不同平台的差异点在哪里收口

## 10. 结论

阶段 1 的核心任务是“先把边界钉住”。如果这一步不做，Windows、macOS、Android、iOS 最后一定会出现四套不同的接入风格。
