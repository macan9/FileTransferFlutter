# 阶段 2：Flutter 编排层与调用链改造

## 1. 目标

在不改动服务端控制面逻辑的前提下，把当前 Flutter 侧从“直接执行本地工具”改造成“统一调用原生 ZeroTier 运行时”。

## 2. 当前项目里已经可以复用的部分

### 2.1 控制面服务

- `NetworkingService`
- `HttpNetworkingService`

这些代码已经负责：

- `bootstrapDevice`
- `heartbeatAgent`
- `fetchAgentCommands`
- `ackAgentCommand`
- 网络创建与邀请码入网

### 2.2 Agent 编排层

- `NetworkingAgentRuntimeController`

它已经具备：

- 启动时自动探测
- 自动 bootstrap
- 心跳轮询
- 命令轮询
- 命令执行后的 ack

### 2.3 需要被替换的部分

- `ProcessZeroTierLocalService`

这个实现适合原型阶段，但不适合最终原生级接入。

## 3. Flutter 侧目标调用链

```text
Networking Page / Settings Page
  -> Riverpod Controller
  -> ZeroTierFacade
  -> ZeroTierPlatformApi
  -> MethodChannel / EventChannel
  -> Native Runtime
  -> EventChannel 回流
  -> Riverpod State
  -> UI
```

## 4. 建议新增的 Dart 文件

- `lib/core/services/zerotier_platform_api.dart`
- `lib/core/services/method_channel_zerotier_service.dart`
- `lib/core/models/zerotier_runtime_status.dart`
- `lib/core/models/zerotier_runtime_event.dart`
- `lib/core/models/zerotier_network_state.dart`
- `lib/core/models/zerotier_permission_state.dart`

## 5. 推荐的职责拆分

### 5.1 `ZeroTierPlatformApi`

职责：

- 定义 Flutter 与原生层的桥接协议
- 不承载业务逻辑

### 5.2 `MethodChannelZeroTierService`

职责：

- 负责命令调用
- 负责事件流订阅
- 负责把原生 JSON 映射成 Dart 模型

### 5.3 `ZeroTierFacade`

职责：

- 统一命令超时
- 统一错误处理
- 统一跨平台差异对外表现

## 6. 与当前 Agent 链路的结合方式

### 6.1 启动链路

1. `NetworkingAgentRuntimeController` 启动
2. 调 `detectStatus`
3. 如环境未准备好，更新错误状态
4. 如环境可用，必要时执行 `prepareEnvironment` 和 `startNode`
5. 获取 `nodeId`
6. 调 `bootstrapDevice`
7. 持久化本机身份

### 6.2 命令链路

1. 轮询服务端命令
2. 将命令映射给 `ZeroTierFacade`
3. `ZeroTierFacade` 调原生平台能力
4. 原生执行完成后返回或推送事件
5. Flutter ack 命令

### 6.3 UI 链路

1. UI 发起动作
2. Riverpod 触发服务端请求
3. 服务端下发命令
4. 本机 Agent 执行
5. 结果回流到 UI

## 7. 本阶段推荐改造顺序

1. 抽出 `ZeroTierPlatformApi`
2. 定义状态模型和事件模型
3. 将 `zeroTierLocalServiceProvider` 改成平台桥接实现
4. 给 `NetworkingAgentRuntimeController` 增加事件订阅
5. 保留现有服务端编排逻辑
6. 页面只读取统一运行时状态

## 8. 本阶段完成标准

- Flutter 代码里不再直接 `Process.run`
- 原生调用全部经由统一桥接层
- 页面不关心平台差异
- Agent 编排逻辑不依赖某个平台的命令格式

## 9. 结论

阶段 2 的目标是先把 Flutter 这一层变稳。只有编排层稳定了，后面每接一个平台才不会回头重改 Dart 代码。
