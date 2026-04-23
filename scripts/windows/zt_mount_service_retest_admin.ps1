param(
  [Parameter(Mandatory = $true)]
  [string]$NetworkId,
  [string]$BuildDir = "build/win_step5",
  [int]$JoinTimeoutMs = 120000,
  [int]$LeaveTimeoutMs = 90000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Sc([string]$Arguments) {
  & sc.exe $Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "sc.exe $Arguments failed with exit code $LASTEXITCODE"
  }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$logDir = Join-Path $repoRoot "logs\zerotier"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $logDir ("zt_mount_service_retest_" + $stamp + ".log")

Start-Transcript -LiteralPath $logPath -Force | Out-Null
try {
  $cmakeBin = "E:\DevSoftWare\VisualStudio2026\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
  if (Test-Path (Join-Path $cmakeBin "cmake.exe")) {
    $env:Path = $cmakeBin + ";" + $env:Path
  }

  $serviceExe = Join-Path $repoRoot ($BuildDir + "\runner\Debug\zt_mount_service.exe")
  if (-not (Test-Path $serviceExe)) {
    throw "Service executable missing: $serviceExe"
  }

  Write-Host "Stopping service if running..."
  & sc.exe stop ZeroTierMountService | Out-Host
  Start-Sleep -Seconds 2

  Write-Host "Repointing service binary..."
  & sc.exe config ZeroTierMountService binPath= ("`"" + $serviceExe + "`"") | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to reconfigure ZeroTierMountService binary path."
  }

  Write-Host "Starting service..."
  & sc.exe start ZeroTierMountService | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to start ZeroTierMountService."
  }

  $driverDir = Join-Path $repoRoot "third_party\libzt\ext\ZeroTierOne\ext\bin\tap-windows-ndis6\x64"
  if (-not (Test-Path (Join-Path $driverDir "zttap300.inf"))) {
    throw "Driver package missing: $driverDir"
  }

  Write-Host "Running strict join/leave retest..."
  & powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot "scripts\windows\zt_win_tap_retest.ps1") `
    -NetworkId $NetworkId `
    -DriverPackageDir $driverDir `
    -InstallDriver `
    -RequireRouteBound `
    -JoinTimeoutMs $JoinTimeoutMs `
    -LeaveTimeoutMs $LeaveTimeoutMs | Out-Host

  Write-Host "Service retest finished."
} finally {
  Stop-Transcript | Out-Null
  Write-Host "RETEST_LOG=$logPath"
}
