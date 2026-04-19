# 阶段 5：Android 原生运行时接入

## 1. 目标

Android 端通过应用内原生节点运行时、`VpnService` 和前台服务实现 ZeroTier 网络接入。

## 2. 核心模块

### 2.1 `ZeroTierAndroidRuntime`

- 初始化节点
- 启动节点
- 停止节点
- 提供 Node ID 和运行状态

### 2.2 `ZeroTierVpnService`

- 承载隧道
- 管理虚拟网络接口
- 管理路由和地址

### 2.3 `ZeroTierForegroundService`

- 保活运行时
- 承载通知
- 处理后台约束

### 2.4 `ZeroTierAndroidPlugin`

- 接 Flutter 命令
- 回传事件

## 3. 需要对接的功能

- VPN 权限申请
- 节点启动与停止
- join / leave
- 网络状态监听
- 地址分配监听
- 错误与诊断回传

## 4. 与 Flutter 的接口建议

- `prepareEnvironment`
- `startNode`
- `stopNode`
- `joinNetworkAndWaitForIp`
- `leaveNetwork`
- `listNetworks`
- `watchRuntimeEvents`

Android 特有补充：

- `prepareVpnPermission`
- `isVpnPermissionGranted`
- `openBatteryOptimizationSettings`

## 5. 本阶段建议实施顺序

1. 先完成 VPN 权限握手
2. 再完成前台服务和节点启动
3. 再完成 join/leave
4. 最后补稳定性和后台保活

## 6. 完成标准

- 授权后可稳定建立隧道
- 节点状态、网络状态、地址状态都能回流 Flutter
- 服务端命令链跑通

## 7. 结论

Android 的核心不在命令调用，而在 `VpnService + 前台服务 + 原生事件回流` 这一整套运行时模型。
