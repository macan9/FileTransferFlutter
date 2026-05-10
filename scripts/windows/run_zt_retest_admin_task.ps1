param(
  [Parameter(Mandatory = $true)]
  [string]$NetworkId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_common.ps1")

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$logDir = Join-Path $repoRoot "logs\zerotier"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$taskLog = Join-Path $logDir ("zt_admin_task_" + $stamp + ".log")

Start-Transcript -LiteralPath $taskLog -Force | Out-Null
try {
  $cmake = Resolve-CMakePath
  $env:Path = (Split-Path -Path $cmake -Parent) + ";" + $env:Path

  $driverDir = Join-Path $repoRoot "third_party\libzt\ext\ZeroTierOne\ext\bin\tap-windows-ndis6\x64"
  if (-not (Test-Path (Join-Path $driverDir "zttap300.inf"))) {
    throw "Driver package missing: $driverDir"
  }

  Write-Host "Running elevated retest..."
  & powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot "scripts\windows\zt_win_tap_retest.ps1") `
    -NetworkId $NetworkId `
    -DriverPackageDir $driverDir `
    -InstallDriver `
    -RequireRouteBound `
    -JoinTimeoutMs 120000 `
    -LeaveTimeoutMs 90000

  Write-Host "Elevated retest finished."
} finally {
  Stop-Transcript | Out-Null
  Write-Host "TASK_LOG=$taskLog"
}
