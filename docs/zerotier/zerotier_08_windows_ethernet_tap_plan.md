# ZeroTier Windows OS 级虚拟网卡实现方案

## 1. 目标

本文档单独描述 Windows 端接入 `WindowsEthernetTap / EthernetTap` 这条 OS 级虚拟网卡链路的实现方案。

目标不是仅让 `libzt` 在应用进程内拿到 managed IP，而是让 Windows 系统本身出现一个可用、可识别、可观测的 ZeroTier 虚拟网卡。

最终目标包括：

- ZeroTier 网络加入后，Windows 侧存在真实可用的虚拟网卡
- 虚拟网卡从系统视角可见，不再长期停留在 `Disconnected`
- managed IP、路由、接口状态能够反映到 Windows 系统层
- Flutter/UI 以“系统级挂载完成”作为最终 ready 信号
- join/leave 过程中的系统网卡状态、地址状态、libzt 状态能统一诊断

## 2. 当前问题

当前工程实际走的是 `NodeService -> VirtualTap -> lwIP netif` 这条用户态链路。

现状是：

- `NodeService` 直接创建 `VirtualTap`
- `VirtualTap::addIp()` 只调用 `zts_lwip_init_interface()`
- 该路径只让进程内 lwIP `netif` 就绪
- 没有真正进入 `ZeroTierOne osdep/WindowsEthernetTap` 的 Windows TAP bring-up 逻辑

这导致：

- `transport_ready = 1`
- `zts_addr_get_all()` 能读到 managed IP
- `NETWORK_READY_IP4 / ADDR_ADDED_IP4` 能出现
- 但 Windows 系统中的 `TAP-Windows Adapter V9` 仍然是 `Disconnected`
- `GetAdaptersAddresses()` 看不到 ZeroTier managed IP 已经绑定到某张系统网卡

因此当前链路已经证明控制面和 libzt 内部数据面可用，但尚未打通 Windows 宿主机网络层。

## 3. 两条链路的本质区别

### 3.1 当前链路：`VirtualTap + lwIP`

特点：

- 网络终止在应用进程内
- IP 仅存在于 libzt 管理的 lwIP `netif`
- 宿主机未必看到真实可用的系统网卡
- 适合应用仅通过 libzt socket 通信

限制：

- Windows `ipconfig`、接口状态、系统路由、系统防火墙语义不完整
- “已组网”无法等价映射为“Windows 网卡已挂载”

### 3.2 目标链路：`WindowsEthernetTap / EthernetTap`

特点：

- 网络终止在 Windows OS 级 TAP 设备
- TAP 会被真正打开、置为 media up
- managed IP 与路由作用于系统虚拟网卡
- 系统其他程序也可感知该接口

这条链路才是当前“Windows 原生层链路打通”的正确落点。

## 4. 目标责任划分

### 4.1 libzt / ZeroTierOne 负责

- 创建或接管 Windows TAP 设备
- 拉起 TAP 设备到可用状态
- 向 TAP 注入/移除 managed IP
- 同步路由、MTU、接口别名、网络事件

### 4.2 本工程 Windows Runtime 负责

- 管理节点生命周期
- 发起 join/leave
- 监听网络事件
- 将 libzt 与系统接口诊断信息统一汇总
- 将“进程内 ready”和“系统挂载 ready”分层暴露给 Flutter

### 4.3 Flutter / Provider 负责

- 展示 join 中间态
- 以系统挂载完成字段作为“已组网”判定
- 向用户展示可诊断状态，而不是简单等同 `NETWORK_OK`

## 5. 核心实现思路

核心原则是：Windows 端不能再让 `NodeService` 直接裸用 `VirtualTap` 作为最终宿主网络终点，而要接入 `EthernetTap` 抽象的 Windows 实现。

建议方案：

1. 保留 `libzt` 的事件、控制面、lwIP 栈调度能力
2. 在 Windows 平台将网络接口宿主切换为 `WindowsEthernetTap`
3. 让 managed IP 的挂载、设备启用、媒体状态拉起走 `WindowsEthernetTap`
4. Runtime 继续使用本地 probe 诊断接口状态，但 ready 判定改为“目标 TAP 设备 up 且持有预期地址”

## 6. 需要落地的代码改造面

### 6.1 `NodeService` 网络设备创建路径

当前代码：

- `third_party/libzt/src/NodeService.cpp`
- 在 `nodeVirtualNetworkConfigFunction()` 中直接 `new VirtualTap(...)`

目标：

- Windows 平台不要直接把 `VirtualTap` 当最终设备实现
- 引入 `EthernetTap::newInstance(...)` 风格的创建路径
- 由平台分发到 `WindowsEthernetTap`

建议：

- 新增一个适配层，而不是到处散落平台判断
- 将“进程内用户态 tap”与“平台 OS tap”概念分开命名

### 6.2 `VirtualTap` 角色重构

当前 `VirtualTap` 同时承担了：

- lwIP `netif` 宿主
- 简化版虚拟口线程
- 地址容器

在 Windows OS 级方案中，建议它退化为下列两种之一：

1. 只保留为 lwIP 数据面辅助对象，由 `WindowsEthernetTap` 负责宿主设备
2. 完全由 `WindowsEthernetTap` 替代当前 Windows 路径下的 `VirtualTap`

优先建议第 2 种，因为语义更清晰。

### 6.3 `WindowsEthernetTap` 接入与裁剪

需要重点评估并接入的现成能力：

- `setPersistentTapDeviceState(...)`
- `TAP_WIN_IOCTL_SET_MEDIA_STATUS`
- TAP 设备查找、启用、重试
- 接口名/友好名设置
- IP 查询与缓存
- MTU 与路由相关同步

目标是尽量复用 ZeroTierOne 已有 Windows TAP bring-up 逻辑，而不是在本工程重新发明一套。

### 6.4 地址与路由同步

当前问题已经证明控制面配置可以下发到本地 `.conf`，下一阶段要保证：

- 设备被拉起后，managed IPv4 能真正绑定到对应 TAP
- Windows 路由表能反映 ZeroTier 子网
- leave 后地址与路由被回收

### 6.5 Runtime 诊断字段扩展

当前已有：

- `localMountState`
- `matchedInterfaceName`
- `matchedInterfaceUp`

建议继续补充：

- `mountDriverKind`
- `mountCandidateNames`
- `systemIpBound`
- `systemRouteBound`
- `tapMediaStatus`
- `tapDeviceInstanceId`
- `tapNetCfgInstanceId`

这样后续可以快速区分：

- libzt 已 ready
- TAP 已找到但未启用
- TAP 已启用但未绑 IP
- IP 已绑但路由未就绪

## 7. 推荐分阶段实施步骤

### 阶段 A：接通设备创建链路

目标：

- 明确 Windows 平台下谁创建网络宿主设备
- 让 `WindowsEthernetTap` 真正进入当前 libzt 路径

完成标志：

- join 时能看到 `WindowsEthernetTap` 的初始化日志
- 不再只有 `VirtualTap::addIp` 与 lwIP `netif_add`

### 阶段 B：打通 TAP bring-up

目标：

- TAP 设备被接管
- 设备从 `Disconnected` 变为系统可用

完成标志：

- `GetAdaptersAddresses()` 能稳定看到目标 TAP
- 接口 `OperStatus` 从 `Down` 变为 `Up`

### 阶段 C：打通 IP 挂载

目标：

- managed IP 真正进入 Windows TAP 设备

完成标志：

- 目标 TAP 适配器上能看到 `172.29.x.x`
- runtime `expected_ip_bound = true`
- `localMountState = ready`

### 阶段 D：打通 leave 回收

目标：

- 离网后接口状态、IP、路由回收正确

完成标志：

- leave 后系统 TAP 不再持有 ZeroTier managed IP
- 路由被清理
- provider/UI 状态正确回落

## 8. 风险与难点

### 8.1 libzt 当前实现与 ZeroTierOne osdep 分层不同

这是当前最大风险。

libzt 现在明显偏向用户态 `VirtualTap + lwIP` 路线，而 `WindowsEthernetTap` 属于 ZeroTierOne 的 OS 级接口实现体系。两套代码并不是天然已经接好的。

### 8.2 驱动与设备生命周期复杂

Windows TAP bring-up 涉及：

- 设备实例发现
- 设备启停
- 媒体状态设置
- 权限与系统策略
- 设备异常重试

这部分不能只靠 `GetAdaptersAddresses()` 观察结果，必须有明确的设备控制链。

### 8.3 不能再把“有地址事件”直接当最终成功

当前已证明：

- `ADDR_ADDED_IP4`
- `NETWORK_READY_IP4`
- `transport_ready = 1`

都不等于 Windows 系统侧已经挂载完成。

后续 UI 和 provider 必须坚持以系统挂载字段为准。

## 9. 验收标准

满足以下条件才算 Windows OS 级链路打通：

- join 后存在明确的目标 TAP 设备
- TAP `OperStatus = Up`
- TAP 上出现预期 managed IPv4
- runtime `localMountState = ready`
- `JoinNetworkAndWaitForIp` 成功条件基于系统挂载完成
- leave 后 IP 与路由被回收
- probe / smoke / join / leave 日志可完整复盘

## 10. 建议的落地顺序

1. 先改设备创建责任链，让 Windows 平台真实进入 `WindowsEthernetTap`
2. 再验证 TAP bring-up，不急着先改 Flutter/UI
3. bring-up 成功后再验证 IP 绑定与路由同步
4. 最后再把最终 ready 判定和 UI 文案切到系统挂载完成

## 11. 本文档结论

当前工程已经证明：

- 控制面配置修复有效
- libzt 内部地址分配有效
- Windows 侧问题集中在 OS 级虚拟网卡未真正接入

下一阶段不应继续围绕 controller、provider、UI 做猜测，而应直接围绕 `NodeService -> EthernetTap -> WindowsEthernetTap` 这条链完成 Windows 系统级挂载实现。
