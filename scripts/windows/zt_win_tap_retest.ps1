param(
  [Parameter(Mandatory = $true)]
  [string]$NetworkId,
  [string]$DriverPackageDir = "",
  [string]$WintunDllPath = "",
  [switch]$RequireRouteBound,
  [switch]$AllowMountDegraded,
  [switch]$InstallDriver,
  [int]$JoinTimeoutMs = 90000,
  [int]$LeaveTimeoutMs = 60000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section([string]$Text) {
  Write-Host ""
  Write-Host "==== $Text ===="
}

function Test-IsAdmin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-CMakePath {
  $candidates = @(
    "D:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
    "D:\Program Files\Microsoft Visual Studio\17\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }
  $cmd = Get-Command cmake -ErrorAction SilentlyContinue
  if ($cmd -ne $null) {
    return $cmd.Source
  }
  throw "cmake not found. Install CMake or Visual Studio CMake workload first."
}

function Find-DriverFiles([string[]]$SearchRoots) {
  foreach ($root in $SearchRoots) {
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
      continue
    }
    $inf = Join-Path $root "zttap300.inf"
    $sys = Join-Path $root "zttap300.sys"
    $cat = Join-Path $root "zttap300.cat"
    if ((Test-Path -LiteralPath $inf) -and (Test-Path -LiteralPath $sys) -and (Test-Path -LiteralPath $cat)) {
      return @{
        Root = $root
        Inf = $inf
        Sys = $sys
        Cat = $cat
      }
    }
  }
  return $null
}

function Find-WintunDll([string[]]$SearchPaths) {
  foreach ($path in $SearchPaths) {
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      return (Resolve-Path -LiteralPath $path).Path
    }
    if (Test-Path -LiteralPath $path -PathType Container) {
      $candidate = Join-Path $path "wintun.dll"
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
      }
      $recursive = Get-ChildItem -Path $path -Filter "wintun.dll" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($null -ne $recursive) {
        return $recursive.FullName
      }
    }
  }
  return $null
}

function Save-RouteSnapshot([string]$Path) {
  $rows = Get-NetRoute -AddressFamily IPv4 |
    Sort-Object -Property ifIndex, DestinationPrefix, NextHop |
    Select-Object ifIndex, DestinationPrefix, NextHop, RouteMetric, PolicyStore
  $rows | Format-Table -AutoSize | Out-String | Set-Content -LiteralPath $Path -Encoding UTF8
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$buildDir = Join-Path $repoRoot "build\win_step4_on"
$smokeDir = Join-Path $buildDir "runner\Debug"
$smokeExe = Join-Path $smokeDir "zt_runtime_smoke.exe"
$logDir = Join-Path $repoRoot "logs\zerotier"
$nodeHome = Join-Path $env:LOCALAPPDATA "FileTransferFlutter\zerotier\node"

$driverSearchRoots = @()
if (-not [string]::IsNullOrWhiteSpace($DriverPackageDir)) {
  $driverSearchRoots += $DriverPackageDir
}
if ($env:ZTTAP_PACKAGE_DIR) {
  $driverSearchRoots += $env:ZTTAP_PACKAGE_DIR
}
$driverSearchRoots += Join-Path $repoRoot "third_party\libzt\ext\ZeroTierOne\windows\TapDriver6"

$wintunSearchPaths = @()
if (-not [string]::IsNullOrWhiteSpace($WintunDllPath)) {
  $wintunSearchPaths += $WintunDllPath
}
if ($env:ZT_WINTUN_DLL) {
  $wintunSearchPaths += $env:ZT_WINTUN_DLL
}
$wintunSearchPaths += Join-Path $repoRoot "build\windows\x64\runner\Debug\wintun.dll"
$wintunSearchPaths += Join-Path $repoRoot "build\win_step4_on\runner\Debug\wintun.dll"
$wintunSearchPaths += Join-Path $repoRoot "third_party\wintun\0.14.1\extract\wintun\bin\amd64\wintun.dll"
$wintunSearchPaths += Join-Path $repoRoot "third_party\wintun"

Write-Section "Precheck"
Write-Host "RepoRoot: $repoRoot"
Write-Host "NodeHome: $nodeHome"
Write-Host "BuildDir: $buildDir"
Write-Host "Search Driver Roots:"
$driverSearchRoots | ForEach-Object { Write-Host "  - $_" }
Write-Host "Search Wintun Paths:"
$wintunSearchPaths | ForEach-Object { Write-Host "  - $_" }

$wintunDll = Find-WintunDll -SearchPaths $wintunSearchPaths
if ($null -eq $wintunDll) {
  Write-Warning "wintun.dll not found; wintun backend bootstrap may fail."
} else {
  Write-Host "WintunDll: $wintunDll"
}

$driver = Find-DriverFiles -SearchRoots $driverSearchRoots
$effectiveAllowMountDegraded = $AllowMountDegraded.IsPresent
if ($driver -eq $null) {
  Write-Warning "zttap package not found (zttap300.inf/.sys/.cat)."
  if ($InstallDriver) {
    throw "InstallDriver requested but no complete zttap package found."
  }
  if (-not $effectiveAllowMountDegraded) {
    Write-Warning "Auto enabling degraded mount mode because driver package is missing."
    $effectiveAllowMountDegraded = $true
  }
} else {
  Write-Host "DriverPackage: $($driver.Root)"
  Write-Host "  inf: $($driver.Inf)"
  Write-Host "  sys: $($driver.Sys)"
  Write-Host "  cat: $($driver.Cat)"

  New-Item -ItemType Directory -Force -Path $nodeHome | Out-Null
  Copy-Item -LiteralPath $driver.Inf -Destination (Join-Path $nodeHome "zttap300.inf") -Force
  Copy-Item -LiteralPath $driver.Sys -Destination (Join-Path $nodeHome "zttap300.sys") -Force
  Copy-Item -LiteralPath $driver.Cat -Destination (Join-Path $nodeHome "zttap300.cat") -Force
  Write-Host "Copied driver files to node home."
}

if ($InstallDriver) {
  Write-Section "Driver Install"
  if (-not (Test-IsAdmin)) {
    throw "Driver installation requires Administrator. Re-run PowerShell as admin."
  }
  $pnputilOut = & pnputil /add-driver (Join-Path $nodeHome "zttap300.inf") /install 2>&1
  $pnputilOut | ForEach-Object { Write-Host $_ }
}

Write-Section "Build zt_runtime_smoke (ON)"
$cmake = Resolve-CMakePath
& $cmake -S (Join-Path $repoRoot "windows") -B $buildDir -DZTS_ENABLE_WINDOWS_OS_TAP=ON
& $cmake --build $buildDir --config Debug --target zt_runtime_smoke -- /m:1

if (-not (Test-Path -LiteralPath $smokeExe)) {
  throw "zt_runtime_smoke not found: $smokeExe"
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $logDir ("zt_runtime_smoke_retest_" + $stamp + ".log")
$routeBeforePath = Join-Path $logDir ("zt_route_before_" + $stamp + ".txt")
$routeAfterPath = Join-Path $logDir ("zt_route_after_" + $stamp + ".txt")

Write-Section "Capture route snapshot (before)"
Save-RouteSnapshot -Path $routeBeforePath
Write-Host "RouteSnapshotBefore: $routeBeforePath"

Write-Section "Run smoke join/leave"
$args = @(
  "--join-network", $NetworkId,
  "--join-timeout-ms", "$JoinTimeoutMs",
  "--leave-timeout-ms", "$LeaveTimeoutMs"
)
if ($RequireRouteBound) {
  $args += "--require-route-bound"
}
if ($effectiveAllowMountDegraded) {
  $args += "--allow-mount-degraded"
}

$env:ZT_WIN_TAP_BACKEND = "wintun"
if ($null -ne $wintunDll) {
  $env:ZT_WINTUN_DLL = $wintunDll
}
$env:Path = (Join-Path $buildDir "third_party\libzt\lib\Debug") + ";" + $env:Path
if ($null -ne $wintunDll) {
  $env:Path = (Split-Path -Path $wintunDll -Parent) + ";" + $env:Path
}
Push-Location $smokeDir
try {
  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $previousNativePref = $null
  if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $previousNativePref = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
  }
  $allOut = & $smokeExe @args 2>&1
  $ErrorActionPreference = $previousErrorActionPreference
  if ($null -ne $previousNativePref) {
    $PSNativeCommandUseErrorActionPreference = $previousNativePref
  }
  $allOut | Tee-Object -FilePath $logPath | Out-Host
  $exitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = "Stop"
  Pop-Location
}

Write-Section "Capture route snapshot (after)"
Save-RouteSnapshot -Path $routeAfterPath
Write-Host "RouteSnapshotAfter: $routeAfterPath"

Write-Section "Result Summary"
Write-Host "Log: $logPath"
Write-Host "ExitCode: $exitCode"

$joined = Select-String -Path $logPath -Pattern "join ok=true" -Quiet
$left = Select-String -Path $logPath -Pattern "leave ok=true" -Quiet
$assignedAddrReady = Select-String -Path $logPath -Pattern "assigned_addr_count=([1-9][0-9]*)|address_count=([1-9][0-9]*)|assignedAddressCount=([1-9][0-9]*)" -Quiet
$ready = Select-String -Path $logPath -Pattern "local_mount_state=ready" -Quiet
$routeNotBoundSeen = Select-String -Path $logPath -Pattern "local_mount_state=route_not_bound" -Quiet
$ipBound = Select-String -Path $logPath -Pattern "systemIpBound=true" -Quiet
$routeBound = Select-String -Path $logPath -Pattern "systemRouteBound=true" -Quiet
$routeMountAttemptSeen = Select-String -Path $logPath -Pattern "RouteMount attempt" -Quiet
$routeMountCleanupSeen = Select-String -Path $logPath -Pattern "RouteMount cleanup" -Quiet

Write-Host "join ok: $joined"
Write-Host "leave ok: $left"
Write-Host "assigned_addr_count>0 seen: $assignedAddrReady"
Write-Host "route_not_bound seen: $routeNotBoundSeen"
Write-Host "ready seen: $ready"
Write-Host "systemIpBound=true seen: $ipBound"
Write-Host "systemRouteBound=true seen: $routeBound"
Write-Host "RouteMount attempt seen: $routeMountAttemptSeen"
Write-Host "RouteMount cleanup seen: $routeMountCleanupSeen"
Write-Host "allowMountDegraded: $effectiveAllowMountDegraded"
Write-Host "tapBackend: wintun"
Write-Host "wintunDll: $wintunDll"

if ($exitCode -ne 0) {
  throw "Smoke test failed. See log: $logPath"
}

if (-not $assignedAddrReady) {
  throw "Smoke test invalid: managed address was never assigned (assigned_addr_count/address_count stayed 0). See log: $logPath"
}

Write-Host "Smoke test passed."
