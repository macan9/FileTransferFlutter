# 阶段 7：默认网络组网与收口流程

## 1. 目标

这份文档专门说明默认网络从“开始组网”到“组网成功”，再到“取消组网 / 收口完成”的完整链路。

重点覆盖：

- 用户看到的按钮状态如何变化
- Flutter 编排层、服务端控制面、本地 ZeroTier runtime 各自负责什么
- 哪些状态代表控制面完成，哪些状态代表数据面完成
- 常见卡点出现在什么阶段

## 2. 参与角色

### 2.1 Flutter UI

入口：

- `lib/features/networking/presentation/pages/networking_page.dart`

职责：

- 展示默认网络按钮状态
- 发起 join / leave 请求
- 根据服务端网络状态和本地 runtime 状态综合判定 UI

### 2.2 Flutter 编排状态层

入口：

- `lib/features/networking/presentation/providers/networking_providers.dart`
- `lib/features/networking/presentation/providers/networking_agent_provider.dart`

职责：

- 管理 `activeAction`
- 管理本地 runtime 生命周期
- 轮询 Agent 命令
- 接收 ZeroTier runtime 事件

### 2.3 FileTransferService

入口：

- `D:/Demo/FileTransferService/src/networking/networking.service.ts`
- `D:/Demo/FileTransferService/src/networking/zerotier.service.ts`

职责：

- 维护设备、默认网络、membership
- 授权成员
- 分配 `Service IP`
- 下发 `join_zerotier_network` / `leave_zerotier_network`
- 保证命令幂等和收敛

### 2.4 OwnZeroTierController

入口：

- `D:/Demo/OwnZeroTierController/internal/member/service.go`
- `D:/Demo/OwnZeroTierController/internal/network/service.go`

职责：

- 代理 ZeroTier controller API
- 为成员授权 / 取消授权
- 显式分配成员 IP
- 保存网络与成员快照

### 2.5 Windows ZeroTier Runtime

入口：

- `windows/native/zerotier/zerotier_windows_runtime.cpp`

职责：

- 启动 libzt 节点
- 加入 / 离开网络
- 将本地网络、地址、节点事件回传给 Flutter

## 3. 关键概念

### 3.1 Service IP

含义：

- 服务端控制面已经为当前成员分配的 ZeroTier IP

来源：

- controller 成员记录中的 `ipAssignments`
- Flutter 侧通过 `ManagedNetworkMembership.zeroTierAssignedIp` 展示

注意：

- `Service IP` 只代表控制面已完成分配
- 不代表本机一定已经拿到地址事件

### 3.2 本地映射

含义：

- Windows runtime 当前 `joinedNetworks` 中是否存在该网络

来源：

- `ZeroTierRuntimeStatus.joinedNetworks`
- `ZeroTierNetworkState.status`
- `ZeroTierNetworkState.assignedAddresses`

### 3.3 组网成功

必须同时满足“服务端 + 本地”两个方向已经收敛。

当前项目里的实际判定更接近：

- 本地网络存在
- 且满足以下任一条件：
  - `isConnected == true`
  - `assignedAddresses` 非空
  - `status == OK` 且已知当前 membership 有 `Service IP`

## 4. 正向链路：开始组网到已组网

### 4.1 初始态

用户看到：

- 按钮：`开始组网`

典型特征：

- 当前设备没有 active / authorized membership
- 本地 `joinedNetworks` 中没有默认网络

### 4.2 点击开始组网

UI 动作：

- `networking_page.dart` 调用 `joinDefaultNetwork`

服务端动作：

- `NetworkingService.joinDefaultManagedNetwork(...)`
- 找到默认网络
- 调用 `joinManagedNetworkInternal(...)`
- 授权成员
- 确保分配 `Service IP`
- 写入 membership
- 写入 `join_zerotier_network` 命令

按钮状态：

- `组网中`

### 4.3 服务端编排完成

这一步通常已经能看到：

- membership `status = authorized` 或 `active`
- membership `zeroTierAssignedIp` 有值

但这时仍然不能直接认为“已组网”，因为本地 runtime 可能还没真正加入网络。

### 4.4 本地 runtime 初始化

本地常见事件：

- `environmentReady`
- `nodeStarted`
- `nodeOnline`

本地常见日志：

```text
ZeroTier runtime event: type=environmentReady
[ZT/WIN] libzt event code=200 name=ZTS_EVENT_NODE_UP
[ZT/WIN] libzt event code=201 name=ZTS_EVENT_NODE_ONLINE
```

### 4.5 Agent 执行 join 命令

本地编排层动作：

- 拉到 `join_zerotier_network`
- 调用 `_zeroTierService.joinNetworkAndWaitForIp(networkId)`

本地 runtime 常见阶段：

- `REQUESTING_CONFIGURATION`
- `NETWORK_OK`
- `ADDR_ADDED_IP4`

### 4.6 等待本地配置收敛

这是最容易误判的阶段。

可能出现的组合：

- 服务端已有 `Service IP`
- 本地已看到网络
- 本地状态仍是 `REQUESTING_CONFIGURATION`
- `assignedAddresses` 仍为空

这说明：

- 控制面已完成
- 本地数据面尚未完全收敛

这时更准确的 UI 语义应是：

- 正在入网
- 等待本地配置
- 等待地址下发

而不是直接显示“已组网”。

### 4.7 组网成功

常见本地信号：

- `transport_ready = 1`
- `addr_result = ZTS_ERR_OK`
- `assignedAddresses = 172.29.x.x`
- 或 `status = OK` 且 membership 已有 `Service IP`

用户看到：

- 按钮：`取消组网`
- 状态：`网络已在线` / `已组网`

## 5. 反向链路：取消组网到收口完成

### 5.1 点击取消组网

UI 动作：

- `networking_page.dart` 调用 `leaveDefaultNetwork`

服务端动作：

- `leaveDefaultManagedNetwork(...)`
- 撤销 membership
- 清空 `zeroTierAssignedIp`
- 取消未完成的 join 命令
- 写入 `leave_zerotier_network`

按钮状态：

- `收口中`

### 5.2 Agent 执行 leave 命令

本地常见日志：

```text
Executing agent command: type=leave_zerotier_network
[ZT/WIN] libzt event code=218 name=ZTS_EVENT_NETWORK_DOWN
```

注意：

- `NETWORK_DOWN` 并不总是代表错误
- 在主动 leave 场景下，它通常是正常离网过程的一部分

### 5.3 本地 runtime 收口恢复

收口期可能发生：

- 本地网络短暂仍保留旧地址
- 节点短暂 `offline`
- `joinedNetworks` 尚未立刻清空

这就是为什么收口状态必须优先级高于“本地仍有旧地址”。

否则按钮会出现：

- 先灰色 `收口中`
- 又被旧本地地址误判回绿色 `取消组网`

### 5.4 收口完成

最终判定特征：

- membership 已经 `revoked`
- 本地 `joinedNetworks` 不再包含默认网络
- 本地虚拟 IP 面板消失

用户看到：

- 按钮恢复为 `开始组网`

## 6. 建议按钮状态机

### 6.1 状态列表

- `开始组网`
- `组网中`
- `等待本地配置`
- `取消组网`
- `收口中`

### 6.2 进入条件

#### `开始组网`

- 未发起 join
- 没有 active / authorized membership
- 本地也没有默认网络映射

#### `组网中`

- 已点击开始组网
- 或 Agent 正在执行 join
- 但本地还没看到默认网络

#### `等待本地配置`

- 服务端已有 membership
- 已有 `Service IP`
- 本地也已经看到网络
- 但本地状态仍是 `REQUESTING_CONFIGURATION`

#### `取消组网`

- 本地网络已经收敛成功
- 网络真实在线

#### `收口中`

- 已发起 leave
- 或 membership 已经 `revoked`
- 但本地默认网络仍未完全消失

### 6.3 优先级原则

建议优先级：

1. `收口中`
2. `等待本地配置`
3. `取消组网`
4. `组网中`
5. `开始组网`

关键原因：

- 收口阶段最容易被旧本地地址误判
- 等待本地配置阶段最容易被已分配 `Service IP` 误判为已组网

## 7. 技术细节补充

### 7.1 为什么 `Service IP` 不等于本地已在线

因为这两个状态来自不同层：

- `Service IP` 来自 controller 成员记录
- 本地已在线来自 libzt runtime 的地址和 transport 状态

只有控制面完成，并不能保证本地数据面已经收敛。

### 7.2 为什么之前会卡在 `REQUESTING_CONFIGURATION`

本轮排障中已经确认过一个关键原因：

- 默认网络曾缺失 `routes`

表现为：

- controller 已授权并分配 `ipAssignments`
- 本地也已经进入该网络
- 但始终收不到最终地址事件

修复方式：

- 为默认网络补充 `routes`
- 同时把新建网络默认配置中的 `routes` 一并补齐

### 7.3 为什么收口会短暂回绿

因为收口是异步过程：

- 服务端 membership 可能先变 `revoked`
- 本地 runtime 仍短暂保留旧地址

如果按钮逻辑只看本地地址，就会把收口态误判回“已组网”。

### 7.4 为什么命令幂等很重要

如果没有幂等保护，会出现：

- 旧 `leave_zerotier_network` 在下一次启动时又被拉到
- 重复 `join_zerotier_network` 堆积在队列中

后果：

- 本地 runtime 被同一网络的 join / leave 反复打架
- UI 状态会反复跳变

本轮已经做过的收敛策略包括：

- leave 时取消同网络未完成 join
- join 时取消同网络未完成 leave
- join 时复用已有 pending join，避免继续堆积

## 8. 关键日志对照

### 8.1 服务端成功编排

可观察信号：

- membership `status = active`
- membership `zeroTierAssignedIp` 非空

### 8.2 本地开始入网

典型日志：

```text
Executing agent command: type=join_zerotier_network
[ZT/WIN] JoinNetwork request network_id=...
```

### 8.3 本地等待配置

典型日志：

```text
[ZT/WIN] Event network snapshot ... status=REQUESTING_CONFIGURATION
```

### 8.4 本地成功拿到地址

典型日志：

```text
[ZT/WIN] libzt event code=... name=ZTS_EVENT_ADDR_ADDED_IP4
[ZT/WIN] UpdateAddressFromEvent network_id=... address=172.29.x.x
```

### 8.5 本地主动离网

典型日志：

```text
Executing agent command: type=leave_zerotier_network
[ZT/WIN] libzt event code=218 name=ZTS_EVENT_NETWORK_DOWN
```

## 9. 当前仓库建议阅读入口

- Flutter 页面状态：`lib/features/networking/presentation/pages/networking_page.dart`
- Flutter 本地编排：`lib/features/networking/presentation/providers/networking_agent_provider.dart`
- Flutter 服务端编排：`lib/features/networking/presentation/providers/networking_providers.dart`
- 服务端 ZeroTier 编排：`D:/Demo/FileTransferService/src/networking/networking.service.ts`
- 服务端 controller 适配：`D:/Demo/FileTransferService/src/networking/zerotier.service.ts`
- Windows runtime：`windows/native/zerotier/zerotier_windows_runtime.cpp`

## 10. 一句话总结

默认网络链路不是“拿到虚拟 IP 就算成功”，而是必须经历：

- 服务端完成授权和 IP 分配
- 本地 runtime 加入网络
- 本地配置收敛
- 本地地址和 transport 稳定

反向收口也不是“点一次取消立刻结束”，而是必须经历：

- 服务端撤销 membership
- 本地执行 leave
- 本地 runtime 恢复稳定
- UI 才能回到 `开始组网`
