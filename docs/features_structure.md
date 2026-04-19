# features 目录结构梳理

## 1. 这份文档是讲什么的

这份文档用来说明 `lib/features/` 目录在当前项目中的作用、现有结构、每层目录应该放什么，以及后续新增功能时推荐怎么组织。

简单说，它是“业务模块目录说明书”。

## 2. `features` 目录的作用

`lib/features/` 主要用来按业务功能拆分代码。

也就是说，这里不是按技术类型拆，而是按“这个功能是干什么的”来拆。

例如当前项目里已经有这些业务模块：

- `dashboard`
- `devices`
- `files`
- `networking`
- `settings`
- `transfers`

这样拆的好处是：

- 不同业务边界更清楚
- 页面、状态、交互更容易聚合在一起
- 后续模块越来越多时，不会所有页面都堆在同一个目录里

## 3. 当前项目里的 `features` 结构

当前项目已经存在的目录大致是这样：

```text
lib/features/
  dashboard/
    presentation/
      pages/
      providers/
  devices/
    presentation/
      pages/
  files/
    presentation/
      pages/
  networking/
    presentation/
      pages/
      providers/
  settings/
    presentation/
      pages/
  transfers/
    presentation/
      pages/
```

从当前现状看，项目还处在比较早期的阶段，`features` 下主要以 `presentation` 层为主，还没有大规模拆到 `data`、`domain`。

这没问题，说明项目现在主要还是先把页面、交互、状态链路搭起来。

## 4. 每个 feature 可以怎么理解

### 4.1 `dashboard`

作用：

- 首页
- 总览信息
- 各模块入口聚合

当前已有：

- 页面
- 页面相关 provider

### 4.2 `devices`

作用：

- 设备发现
- 设备列表展示
- 设备状态查看

当前已有：

- 页面

### 4.3 `files`

作用：

- 文件浏览
- 文件列表展示
- 文件相关操作入口

当前已有：

- 页面

### 4.4 `networking`

作用：

- 组网
- ZeroTier 相关状态
- 设备注册
- 网络控制面交互

当前已有：

- 页面
- 状态 provider
- Agent runtime provider

这是当前项目里相对更重的一个模块。

### 4.5 `settings`

作用：

- 配置项展示与修改
- 本地环境设置
- 运行参数调整

当前已有：

- 页面

### 4.6 `transfers`

作用：

- 传输任务展示
- 传输状态查看
- 队列和记录入口

当前已有：

- 页面

## 5. `features` 下常见的推荐分层

后续随着项目复杂度增加，建议每个功能模块逐步往下面这个结构演进：

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

## 6. 每一层该放什么

### 6.1 `presentation/`

作用：

- 页面
- 状态管理
- 用户交互
- 界面局部组件

常见子目录：

- `pages/`
- `providers/`
- `widgets/`

这是现在项目里已经在使用的主结构。

### 6.2 `data/`

作用：

- 调接口
- 调本地存储
- 调原生层
- 做数据转换

常见子目录：

- `datasources/`
  - 外部数据来源，例如 HTTP、本地数据库、平台接口
- `models/`
  - 数据传输模型
- `repositories/`
  - 对数据来源进行统一封装

### 6.3 `domain/`

作用：

- 放业务规则
- 放业务实体
- 放用例逻辑

常见子目录：

- `entities/`
- `repositories/`
- `usecases/`

这层适合在业务逻辑明显变复杂时再引入，不需要为了“看起来规范”而强行一开始全铺开。

## 7. 当前项目最适合的使用方式

结合当前仓库现状，我建议这样理解：

### 7.1 现在可以继续保持轻量结构

如果某个功能还不复杂，可以先只保留：

```text
features/<feature>/
  presentation/
    pages/
    providers/
    widgets/
```

这样开发成本低，也最贴合当前项目。

### 7.2 只有在功能明显变重时再拆 `data` 和 `domain`

例如下面这些场景，就值得开始拆：

- 一个功能对应多个接口来源
- 本地缓存逻辑变多
- 业务规则不止页面里那几行判断
- 同一套业务逻辑要被多个页面复用

对当前项目来说，最可能最先变重的是：

- `networking`
- `files`
- `transfers`

## 8. 当前目录下每种文件大概该放哪

### 8.1 页面文件

放在：

- `presentation/pages/`

例如：

- `files_page.dart`
- `networking_page.dart`
- `settings_page.dart`

### 8.2 页面状态和交互编排

放在：

- `presentation/providers/`

例如：

- `networking_providers.dart`
- `networking_agent_provider.dart`
- `dashboard_providers.dart`

### 8.3 页面局部组件

放在：

- `presentation/widgets/`

适合放：

- 某个 feature 专属卡片
- 某个 feature 专属表单区
- 某个 feature 专属列表项

如果这个组件会跨多个模块复用，就不要放这里，应该放到：

- `lib/shared/widgets/`

## 9. `features` 和 `core`、`shared` 的边界

这个边界很重要。

### 9.1 该放 `features/` 的内容

- 某个业务模块自己的页面
- 某个业务模块自己的状态管理
- 某个业务模块自己的局部组件
- 某个业务模块自己的业务流程

### 9.2 该放 `core/` 的内容

- 全项目共用模型
- 基础服务
- 配置服务
- 网络服务
- 错误定义
- ZeroTier 统一运行时抽象

### 9.3 该放 `shared/` 的内容

- 多个模块都能复用的 Widget
- 多个模块都能复用的 Provider

一句话记：

- 业务归 `features`
- 基础抽象归 `core`
- 跨业务复用归 `shared`

## 10. 新增一个 feature 时推荐怎么建

如果你后面新增一个业务模块，比如 `history`，可以先按下面这个最小结构开始：

```text
features/history/
  presentation/
    pages/
    providers/
    widgets/
```

只有当这个模块明显变复杂时，再继续补：

```text
features/history/
  data/
  domain/
  presentation/
```

## 11. 对当前项目的建议

结合当前项目，我建议后续按下面方式推进：

1. 继续保持 `features/<feature>/presentation/` 作为主结构
2. 给已经变复杂的模块补 `presentation/widgets/`
3. 当 `networking`、`files`、`transfers` 逻辑继续膨胀时，再逐步拆 `data/`
4. 只有当业务规则开始独立成型时，再考虑拆 `domain/`

## 12. 总结

`lib/features/` 的核心作用，就是按业务模块组织代码。

当前项目已经具备了一个比较清晰的基础方向：

- 每个功能模块独立成目录
- 先以 `presentation` 为主
- 后续根据复杂度再逐步演进到 `data / domain / presentation`

这样做的好处是：

- 现在不会为了“架构完整”而过度设计
- 以后功能变大时，又有明确的演进方向
