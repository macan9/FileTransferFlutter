# Flutter UI 层：Widget 生命周期与结构梳理

## 1. 这份文档是讲什么的

这份文档专门用来帮助理解 Flutter UI 层的基本组成，重点回答两个问题：

1. Flutter 里的界面元素到底是什么
2. Flutter 里的 UI 生命周期大致是怎么运转的

如果你有 Web、React、Vue 之类的背景，可以把它理解成一份“Flutter UI 对照理解版”。

## 2. Flutter 里的界面元素叫什么

Flutter 里最常见、最重要的界面单位叫 `Widget`。

例如：

- 文本：`Text`
- 按钮：`ElevatedButton`
- 容器：`Container`
- 横向布局：`Row`
- 纵向布局：`Column`
- 页面：`Scaffold`

所以平时说“一个界面元素”“一个组件”“一个 UI 块”，通常都是在说某个 `Widget`。

## 3. Flutter UI 的三层概念

如果只从开发角度看，记住 `Widget` 就够用了。  
但如果想理解生命周期，就最好知道 Flutter 实际上有三层：

### 3.1 `Widget`

作用：

- 描述“界面应该长什么样”
- 是一种配置对象
- 本身通常是不可变的

你平时写的大多数 UI 代码，都是在写 `Widget`。

### 3.2 `Element`

作用：

- 负责把 `Widget` 挂到界面树上
- 维护运行时树结构
- 连接 `Widget` 和渲染层

可以把它理解成 Flutter 运行时里的“挂载节点”。

### 3.3 `RenderObject`

作用：

- 负责布局
- 负责绘制
- 负责命中测试

如果类比 Web：

- `Widget` 更像声明式组件描述
- `Element` 更像运行时节点
- `RenderObject` 更像真正参与布局与绘制的底层对象

## 4. Flutter UI 层的大致结构

一个 Flutter 页面通常会有下面几层：

```text
Page
  -> Scaffold
    -> Layout Widgets
      -> Business Widgets
        -> Basic Widgets
```

可以拆开理解成：

### 4.1 页面壳层

常见组件：

- `MaterialApp`
- `Scaffold`
- `AppBar`
- `NavigationBar`

职责：

- 页面基础结构
- 导航
- 整体布局容器

### 4.2 布局层

常见组件：

- `Row`
- `Column`
- `Stack`
- `Expanded`
- `Padding`
- `SizedBox`
- `Align`

职责：

- 决定元素怎么排布
- 决定尺寸、间距、对齐方式

### 4.3 业务组件层

常见形式：

- 自定义卡片
- 列表项
- 表单块
- 某个业务模块的局部区域

职责：

- 承载具体业务展示和交互
- 组合多个基础 Widget

### 4.4 基础展示层

常见组件：

- `Text`
- `Icon`
- `Image`
- `Container`
- `ColoredBox`

职责：

- 真正把视觉内容画出来

## 5. Flutter 中常见的 Widget 类型

开发时最常见的是两类：

### 5.1 `StatelessWidget`

特点：

- 自身不维护可变状态
- 依赖外部传入的数据
- 适合纯展示组件

例如：

- 标题栏
- 静态信息卡片
- 只根据参数渲染的按钮

### 5.2 `StatefulWidget`

特点：

- 自身有状态
- 会和一个 `State` 对象配对使用
- 适合需要响应交互、异步结果、生命周期管理的组件

例如：

- 表单
- Tab 页
- 动画组件
- 需要监听订阅、定时器、控制器的页面

## 6. 最重要的 UI 生命周期：`StatefulWidget`

Flutter 里最接近前端组件生命周期的，是 `StatefulWidget` 对应的 `State` 生命周期。

可以先看主流程：

```text
createState
  -> initState
  -> didChangeDependencies
  -> build
  -> didUpdateWidget
  -> build
  -> dispose
```

下面分别解释。

### 6.1 `createState()`

作用：

- `StatefulWidget` 创建时，生成对应的 `State`

特点：

- 这是 Widget 自己的方法
- 一般只写一次，返回对应 `State`

示例理解：

```dart
class MyPage extends StatefulWidget {
  const MyPage({super.key});

  @override
  State<MyPage> createState() => _MyPageState();
}
```

### 6.2 `initState()`

作用：

- `State` 第一次创建时调用
- 只会调用一次

适合做的事：

- 初始化控制器
- 初始化定时器
- 发起首次非依赖 `context` 的准备工作
- 注册监听

不适合直接做的事：

- 依赖 `InheritedWidget` 的读取
- 过早调用依赖完整布局结果的逻辑

Web 类比：

- 接近“组件初始化”
- 类似 mounted 之前的准备阶段

### 6.3 `didChangeDependencies()`

作用：

- 当当前组件依赖的上层依赖发生变化时调用
- 首次创建后也会调用一次

适合做的事：

- 读取依赖 `context` 的对象
- 响应主题、`InheritedWidget`、本地化等变化

如果你需要“基于上下文做初始化”，很多时候这里比 `initState()` 更合适。

### 6.4 `build()`

作用：

- 根据当前状态构建 UI

特点：

- 可能会被调用很多次
- 不代表组件重新创建
- 只是重新描述“现在界面应该长什么样”

适合做的事：

- 返回 Widget 树
- 读取状态
- 做纯计算型 UI 组合

不适合做的事：

- 发网络请求
- 创建订阅
- 创建一次性资源
- 做重副作用逻辑

一句话理解：

`build()` 是“画 UI 说明书”的地方，不是“做初始化副作用”的地方。

### 6.5 `didUpdateWidget(oldWidget)`

作用：

- 当父组件传入了新的 Widget 配置，但当前 `State` 被复用时调用

适合做的事：

- 响应外部参数变化
- 处理旧参数和新参数的差异
- 更新依赖某个参数的内部资源

例如：

- 外部传入的 `id` 变了，需要重新加载对应数据
- 外部传入的控制器对象变了，需要解除旧监听并绑定新监听

### 6.6 `setState()`

它不是生命周期方法，但和生命周期强相关。

作用：

- 通知 Flutter：当前状态变了，需要重新执行 `build()`

特点：

- 调用后通常会触发重新构建
- 不会重新走 `initState()`
- 重点是刷新 UI，不是重建整个页面对象

### 6.7 `deactivate()`

作用：

- 当组件暂时从树中移除时调用

这个方法平时用得不多。  
大多数业务开发场景下，不需要主动依赖它。

### 6.8 `dispose()`

作用：

- 组件真正销毁前调用
- 只会调用一次

适合做的事：

- 释放控制器
- 取消订阅
- 取消定时器
- 清理监听器

这是 Flutter 生命周期里非常重要的“收尾阶段”。

如果你在 `initState()` 里创建了资源，通常就要在 `dispose()` 里释放。

## 7. 一个最实用的生命周期记法

日常开发里，你可以先只记这 5 个：

1. `initState()`
   - 第一次初始化
2. `didChangeDependencies()`
   - 依赖变化或首轮上下文准备完成
3. `build()`
   - 构建界面
4. `didUpdateWidget()`
   - 外部参数变化
5. `dispose()`
   - 销毁清理

## 8. App 生命周期和 Widget 生命周期不是一回事

这个点很容易混。

### 8.1 Widget 生命周期

关注的是：

- 某个页面组件什么时候创建
- 什么时候重建
- 什么时候销毁

### 8.2 App 生命周期

关注的是：

- 应用回到前台
- 应用切到后台
- 应用失去焦点
- 应用被挂起

常见状态包括：

- `resumed`
- `inactive`
- `paused`
- `detached`

所以：

- 页面销毁，不一定等于应用退后台
- 应用退后台，也不一定等于某个 Widget 被销毁

## 9. Flutter 和 Web / React 思维对照

可以粗略这样理解：

| Web / React 思维 | Flutter 中更接近的概念 |
| --- | --- |
| DOM 元素 | `Element` |
| 组件描述 | `Widget` |
| 真正布局绘制 | `RenderObject` |
| 挂载 | `initState()` 之后进入树 |
| 更新 | `didUpdateWidget()` / `build()` |
| 卸载 | `dispose()` |

要注意，这只是帮助理解，不是完全一一对应。

## 10. 在项目里怎么用这个理解

结合当前项目，通常可以这样分：

### 10.1 页面级 Widget

例如：

- 文件页
- 网络页
- 设置页

适合用：

- `StatefulWidget`

因为往往会涉及：

- 首次加载
- 订阅状态
- 交互控制器
- 生命周期清理

### 10.2 展示型组件

例如：

- 信息卡片
- 状态标签
- 静态按钮区

适合用：

- `StatelessWidget`

### 10.3 有局部交互的小组件

例如：

- 展开折叠区域
- 临时输入框
- 本地动画块

可以根据状态复杂度决定是否使用：

- `StatefulWidget`

## 11. 日常开发里最容易踩的坑

### 11.1 在 `build()` 里做副作用

例如：

- 发请求
- 创建控制器
- 注册监听

这样很容易因为多次 `build()` 导致重复执行。

### 11.2 忘记在 `dispose()` 里清理资源

例如：

- `TextEditingController`
- `AnimationController`
- `StreamSubscription`
- `Timer`

### 11.3 把“重新 build”误以为“组件重建”

很多时候只是 UI 重新描述，不是整个生命周期重来一遍。

### 11.4 过度使用 `StatefulWidget`

如果只是纯展示，其实 `StatelessWidget` 更简单也更清晰。

## 12. 一句话总结

Flutter UI 层最核心的理解是：

- 你平时写的是 `Widget`
- 真正最常用的生命周期在 `StatefulWidget` 的 `State` 上
- `build()` 负责描述界面
- `initState()` 负责初始化
- `dispose()` 负责清理

只要先把这套思路建立起来，后面再看更底层的 `Element`、`RenderObject`、渲染管线，就会顺很多。
