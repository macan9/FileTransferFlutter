# Windows TAP 驱动补齐清单 + 一键复测

目标：打通 `route_not_bound -> ready`，并完成 `join/leave` 回收验收。

## 1. 必备前置

1. 以管理员权限运行 PowerShell（驱动安装时必需）。
2. 具备 CMake（当前推荐路径）：
   - `D:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`
3. 准备完整 TAP 驱动包目录，且同目录包含三个文件：
   - `zttap300.inf`
   - `zttap300.sys`
   - `zttap300.cat`

说明：
- 仓库默认仅含 `zttap300.inf`，不含 `.sys/.cat`，无法完成真实驱动安装与挂载。
- 若缺 `.sys/.cat`，运行时会停在 `awaiting_address` / `missing_adapter`，不会进入 `route_not_bound -> ready`。

## 2. 一键复测脚本

脚本路径：
- `scripts/windows/zt_win_tap_retest.ps1`

### 用法（推荐）

```powershell
pwsh -File scripts/windows/zt_win_tap_retest.ps1 `
  -NetworkId 31756fbd65bfbf76 `
  -DriverPackageDir "C:\path\to\zttap-package" `
  -InstallDriver `
  -RequireRouteBound
```

参数说明：
- `-NetworkId`：16 位十六进制 ZeroTier Network ID（必填）。
- `-DriverPackageDir`：驱动包目录（可选；也可用环境变量 `ZTTAP_PACKAGE_DIR`）。
- `-InstallDriver`：执行 `pnputil /add-driver ... /install`。
- `-RequireRouteBound`：要求 `systemRouteBound=true`。
- `-JoinTimeoutMs` / `-LeaveTimeoutMs`：超时配置（可选）。

## 3. 验收标准

日志中应满足：
1. `join ok=true`
2. 出现挂载状态推进（理想：先 `route_not_bound`，后 `ready`）
3. `systemIpBound=true`
4. （启用 `-RequireRouteBound` 时）`systemRouteBound=true`
5. `leave ok=true`
6. leave 后网络从 runtime 中消失

## 4. 常见阻塞与定位

1. `unable to read zttap driver INF file`
   - 说明运行时找不到 `zttap300.inf`（或路径不对）。
2. `mount_candidate=false` 且 `missing_adapter`
   - 系统中无可用 zttap 适配器，通常是驱动未安装。
3. `join ok=false` + `Timed out waiting ... mount the managed address`
   - ZeroTier 已拿到托管地址，但系统网卡挂载未完成。

## 5. 输出日志

脚本会将完整日志写到：
- `logs/zerotier/zt_runtime_smoke_retest_yyyyMMdd_HHmmss.log`
