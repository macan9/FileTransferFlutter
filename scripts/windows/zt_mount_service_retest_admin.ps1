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

function Test-ServiceExists([string]$Name) {
  & sc.exe query $Name *> $null
  return $LASTEXITCODE -eq 0
}

function Test-ZtTapPackage([string]$Path) {
  return (Test-Path (Join-Path $Path "zttap300.inf")) -and
    (Test-Path (Join-Path $Path "zttap300.sys")) -and
    (Test-Path (Join-Path $Path "zttap300.cat"))
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
  if (Test-ServiceExists "ZeroTierMountService") {
    & sc.exe stop ZeroTierMountService | Out-Host
    Start-Sleep -Seconds 2
  } else {
    Write-Host "Service does not exist; it will be created."
  }

  if (Test-ServiceExists "ZeroTierMountService") {
    Write-Host "Repointing service binary..."
    & sc.exe config ZeroTierMountService binPath= ("`"" + $serviceExe + "`"") | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to reconfigure ZeroTierMountService binary path."
    }
  } else {
    Write-Host "Creating service..."
    & sc.exe create ZeroTierMountService binPath= ("`"" + $serviceExe + "`"") start= demand DisplayName= "ZeroTier Mount Service" | Out-Host
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to create ZeroTierMountService."
    }
  }

  Write-Host "Starting service..."
  & sc.exe start ZeroTierMountService | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to start ZeroTierMountService."
  }

  $driverDirs = @(
    (Join-Path $repoRoot "third_party\libzt\ext\ZeroTierOne\ext\bin\tap-windows-ndis6\x64"),
    (Join-Path $repoRoot "third_party\libzt\ext\ZeroTierOne\windows\TapDriver6")
  )
  $driverDir = $driverDirs | Where-Object { Test-ZtTapPackage $_ } | Select-Object -First 1
  $retestArgs = @(
    "-NetworkId", $NetworkId,
    "-RequireRouteBound",
    "-JoinTimeoutMs", "$JoinTimeoutMs",
    "-LeaveTimeoutMs", "$LeaveTimeoutMs"
  )
  if ($driverDir) {
    $retestArgs += @("-DriverPackageDir", $driverDir, "-InstallDriver")
  } else {
    Write-Warning "Complete zttap package not found; running Wintun degraded retest."
    $wintunDll = Join-Path $repoRoot "build\windows\x64\runner\Debug\wintun.dll"
    if (Test-Path $wintunDll) {
      $retestArgs += @("-WintunDllPath", $wintunDll)
    }
    $retestArgs += "-AllowMountDegraded"
  }

  Write-Host "Running strict join/leave retest..."
  & powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot "scripts\windows\zt_win_tap_retest.ps1") @retestArgs | Out-Host

  Write-Host "Service retest finished."
} finally {
  Stop-Transcript | Out-Null
  Write-Host "RETEST_LOG=$logPath"
}
