# 阶段 6：iOS 原生运行时接入

## 1. 目标

iOS 端通过主 App、`Network Extension` 和应用内 ZeroTier 原生节点运行时完成接入。

## 2. 核心模块

### 2.1 主 App 侧管理器

- 安装 VPN 配置
- 启动与停止隧道
- 与 Flutter 通信

### 2.2 `PacketTunnelProvider`

- 承载 ZeroTier 运行时
- 管理虚拟网络接口
- join / leave
- 回写状态

### 2.3 共享存储

- 保存运行时状态
- 保存日志
- 保存配置

### 2.4 `ZeroTierIOSPlugin`

- 方法调用桥接
- 事件桥接

## 3. 需要对接的功能

- VPN Profile 安装
- 隧道启动与停止
- 节点启动与停止
- join / leave
- 网络状态同步
- 地址分配同步
- 错误诊断同步

## 4. 与 Flutter 的接口建议

- `installVpnProfile`
- `prepareEnvironment`
- `startNode`
- `stopNode`
- `joinNetworkAndWaitForIp`
- `leaveNetwork`
- `listNetworks`
- `watchRuntimeEvents`

## 5. 本阶段建议实施顺序

1. 先完成 VPN Profile 安装
2. 再完成 `PacketTunnelProvider`
3. 再完成节点运行时接入
4. 再完成 join/leave 和状态同步
5. 最后补诊断与日志共享

## 6. 完成标准

- 主 App 能稳定拉起 Extension
- Flutter 能读到统一运行时状态
- 服务端命令链跑通

## 7. 结论

iOS 的关键是把主 App、Extension、共享状态三者关系建立好。一旦这层稳定，Flutter 侧就能和其他平台保持一致的调用方式。
