[CmdletBinding()]
param(
  [string]$ProjectRoot = '',
  [string]$RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'FileTransferFlutter\zerotier'),
  [switch]$SkipBuild,
  [switch]$SkipSmoke,
  [switch]$UseExistingSmokeLogs,
  [switch]$ForceSmoke,
  [switch]$CleanupStaleSmoke,
  [switch]$WriteReport,
  [int]$SmokeTimeoutSec = 30,
  [int]$JoinTimeoutMs = 45000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Write-Section {
  param([string]$Title)
  Write-Host ""
  Write-Host "=== $Title ==="
}

function Get-CmakePath {
  $candidates = @(
    'cmake',
    'E:\DevSoftWare\VisualStudio2026\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
  )
  foreach ($candidate in $candidates) {
    try {
      $cmd = Get-Command $candidate -ErrorAction Stop
      return $cmd.Source
    } catch {
    }
    if (Test-Path $candidate) {
      return (Resolve-Path $candidate).Path
    }
  }
  throw 'cmake was not found.'
}

function Read-KeyValueFile {
  param([string]$Path)
  $latin1 = [System.Text.Encoding]::GetEncoding(28591)
  $text = $latin1.GetString([System.IO.File]::ReadAllBytes($Path))
  $map = [ordered]@{}
  foreach ($line in ($text -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    $parts = $line -split '=', 2
    if ($parts.Count -ne 2) {
      continue
    }
    $map[$parts[0].Trim()] = $parts[1]
  }
  return $map
}

function Decode-DictionaryValueBytes {
  param([string]$Value)
  $bytes = New-Object System.Collections.Generic.List[byte]
  for ($index = 0; $index -lt $Value.Length; $index++) {
    $current = [char]$Value[$index]
    if ($current -eq '\') {
      $index++
      if ($index -ge $Value.Length) {
        break
      }
      $escaped = [char]$Value[$index]
      switch ($escaped) {
        'r' { [void]$bytes.Add(13) }
        'n' { [void]$bytes.Add(10) }
        '0' { [void]$bytes.Add(0) }
        'e' { [void]$bytes.Add([byte][char]'=') }
        default { [void]$bytes.Add([byte][int][char]$escaped) }
      }
      continue
    }
    [void]$bytes.Add([byte][int][char]$current)
  }
  return $bytes.ToArray()
}

function Read-UInt16Be {
  param(
    [byte[]]$Bytes,
    [int]$Offset
  )
  return (($Bytes[$Offset] -shl 8) -bor $Bytes[$Offset + 1])
}

function Format-InetAddressRecord {
  param(
    [string]$Ip,
    [int]$PortOrPrefix
  )
  if ([string]::IsNullOrWhiteSpace($Ip)) {
    return ''
  }
  return "$Ip/$PortOrPrefix"
}

function Read-InetAddressItem {
  param(
    [byte[]]$Bytes,
    [int]$Offset
  )
  if ($Offset -ge $Bytes.Length) {
    return $null
  }
  $tag = $Bytes[$Offset]
  switch ($tag) {
    0x00 {
      return [pscustomobject]@{
        NextOffset = $Offset + 1
        Family = 'none'
        Prefix = 0
        Text = ''
      }
    }
    0x04 {
      if (($Offset + 7) -gt $Bytes.Length) {
        return $null
      }
      $addrBytes = $Bytes[($Offset + 1)..($Offset + 4)]
      $prefix = Read-UInt16Be -Bytes $Bytes -Offset ($Offset + 5)
      $ip = ([System.Net.IPAddress]::new($addrBytes)).ToString()
      return [pscustomobject]@{
        NextOffset = $Offset + 7
        Family = 'ipv4'
        Prefix = $prefix
        Text = (Format-InetAddressRecord -Ip $ip -PortOrPrefix $prefix)
      }
    }
    0x06 {
      if (($Offset + 19) -gt $Bytes.Length) {
        return $null
      }
      $addrBytes = $Bytes[($Offset + 1)..($Offset + 16)]
      $prefix = Read-UInt16Be -Bytes $Bytes -Offset ($Offset + 17)
      $ip = ([System.Net.IPAddress]::new($addrBytes)).ToString()
      return [pscustomobject]@{
        NextOffset = $Offset + 19
        Family = 'ipv6'
        Prefix = $prefix
        Text = (Format-InetAddressRecord -Ip $ip -PortOrPrefix $prefix)
      }
    }
    default {
      return [pscustomobject]@{
        NextOffset = $Bytes.Length
        Family = "tag_$tag"
        Prefix = 0
        Text = "unknown_tag_$tag"
      }
    }
  }
}

function Decode-InetAddressBlob {
  param([string]$Value)
  if ([string]::IsNullOrEmpty($Value)) {
    return @()
  }
  $bytes = Decode-DictionaryValueBytes -Value $Value
  $items = @()
  $offset = 0
  while ($offset -lt $bytes.Length) {
    $item = Read-InetAddressItem -Bytes $bytes -Offset $offset
    if ($null -eq $item) {
      break
    }
    $offset = $item.NextOffset
    if (-not [string]::IsNullOrWhiteSpace($item.Text)) {
      $items += $item.Text
    }
  }
  return $items
}

function Decode-RouteBlob {
  param([string]$Value)
  if ([string]::IsNullOrEmpty($Value)) {
    return @()
  }
  $bytes = Decode-DictionaryValueBytes -Value $Value
  $routes = @()
  $offset = 0
  while ($offset -lt $bytes.Length) {
    $target = Read-InetAddressItem -Bytes $bytes -Offset $offset
    if ($null -eq $target) {
      break
    }
    $offset = $target.NextOffset
    $via = Read-InetAddressItem -Bytes $bytes -Offset $offset
    if ($null -eq $via) {
      break
    }
    $offset = $via.NextOffset
    if (($offset + 4) -gt $bytes.Length) {
      break
    }
    $flags = Read-UInt16Be -Bytes $bytes -Offset $offset
    $metric = Read-UInt16Be -Bytes $bytes -Offset ($offset + 2)
    $offset += 4
    $routes += [pscustomobject]@{
      Target = $target.Text
      Via = $via.Text
      Flags = $flags
      Metric = $metric
    }
  }
  return $routes
}

function Get-NetworkConfDecode {
  param([string]$NetworksDir)
  if (-not (Test-Path $NetworksDir)) {
    return @()
  }
  $items = @()
  foreach ($file in Get-ChildItem -LiteralPath $NetworksDir -Filter '*.conf' | Sort-Object Name) {
    $kv = Read-KeyValueFile -Path $file.FullName
    $staticIps = if ($kv.Contains('I')) { @(Decode-InetAddressBlob -Value $kv['I']) } else { @() }
    $routes = if ($kv.Contains('RT')) { @(Decode-RouteBlob -Value $kv['RT']) } else { @() }
    $items += [pscustomobject]@{
      File = $file.Name
      NetworkId = $kv['nwid']
      ComMeaning = if ($kv.Contains('C')) { 'certificate_of_membership' } else { '' }
      ComBlobLength = if ($kv.Contains('C')) { (Decode-DictionaryValueBytes -Value $kv['C']).Length } else { 0 }
      HasStaticIpBlob = $kv.Contains('I')
      StaticIpBlobLength = if ($kv.Contains('I')) { (Decode-DictionaryValueBytes -Value $kv['I']).Length } else { 0 }
      StaticIps = if (@($staticIps).Count -gt 0) { ($staticIps -join ', ') } else { '' }
      HasRouteBlob = $kv.Contains('RT')
      RouteBlobLength = if ($kv.Contains('RT')) { (Decode-DictionaryValueBytes -Value $kv['RT']).Length } else { 0 }
      Routes = if (@($routes).Count -gt 0) {
        (($routes | ForEach-Object { "$($_.Target) via $($_.Via) flags=$($_.Flags) metric=$($_.Metric)" }) -join '; ')
      } else { '' }
      HasRulesBlob = $kv.Contains('R')
      RulesBlobLength = if ($kv.Contains('R')) { (Decode-DictionaryValueBytes -Value $kv['R']).Length } else { 0 }
      HasDnsBlob = $kv.Contains('DNS')
      DnsBlobLength = if ($kv.Contains('DNS')) { (Decode-DictionaryValueBytes -Value $kv['DNS']).Length } else { 0 }
      AddressDeliveryHint = if (@($staticIps).Count -gt 0) { 'static_ips_present' } else { 'no_static_ip_blob' }
    }
  }
  return $items
}

function Get-NetworkConfSummary {
  param([string]$NetworksDir)
  if (-not (Test-Path $NetworksDir)) {
    return @()
  }
  $items = @()
  foreach ($file in Get-ChildItem -LiteralPath $NetworksDir -Filter '*.conf' | Sort-Object Name) {
    $kv = Read-KeyValueFile -Path $file.FullName
    $items += [pscustomobject]@{
      File = $file.Name
      NetworkId = $kv['nwid']
      Name = $kv['n']
      NodeId = $kv['id']
      Timestamp = $kv['ts']
      Revision = $kv['r']
      Flags = $kv['f']
      Mtu = $kv['mtu']
      HasComBlob = $kv.Contains('C')
      HasStaticIpBlob = $kv.Contains('I')
      HasRouteBlob = $kv.Contains('RT')
      HasRulesBlob = $kv.Contains('R')
      HasDnsBlob = $kv.Contains('DNS')
      ComBlobLength = if ($kv.Contains('C')) { (Decode-DictionaryValueBytes -Value $kv['C']).Length } else { 0 }
    }
  }
  return $items
}

function Build-SmokeHarness {
  param(
    [string]$ProjectRoot,
    [string]$CmakePath
  )
  & $CmakePath -S (Join-Path $ProjectRoot 'windows') -B (Join-Path $ProjectRoot 'build\windows-cmake-direct') | Out-Host
  & $CmakePath --build (Join-Path $ProjectRoot 'build\windows-cmake-direct') --config Release --target zt_runtime_smoke | Out-Host
}

function Test-SmokeHarnessIsStale {
  param([string]$ProjectRoot)
  $exe = Join-Path $ProjectRoot 'build\windows-cmake-direct\runner\Release\zt_runtime_smoke.exe'
  $sources = @(
    (Join-Path $ProjectRoot 'windows\native\zerotier\zt_runtime_smoke.cpp'),
    (Join-Path $ProjectRoot 'windows\native\zerotier\zerotier_windows_runtime.cpp'),
    (Join-Path $ProjectRoot 'windows\native\zerotier\zerotier_windows_runtime.h'),
    (Join-Path $ProjectRoot 'windows\runner\CMakeLists.txt')
  )
  if (-not (Test-Path $exe)) {
    return $true
  }
  $exeTime = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
  foreach ($source in $sources) {
    if (-not (Test-Path $source)) {
      continue
    }
    if ((Get-Item -LiteralPath $source).LastWriteTimeUtc -gt $exeTime) {
      return $true
    }
  }
  return $false
}

function Invoke-SmokeHarness {
  param(
    [string]$ProjectRoot,
    [int]$TimeoutSec,
    [int]$JoinTimeoutMs,
    [switch]$CleanupStaleSmoke
  )
  $exe = Join-Path $ProjectRoot 'build\windows-cmake-direct\runner\Release\zt_runtime_smoke.exe'
  $dllDir = Join-Path $ProjectRoot 'build\windows-cmake-direct\third_party\libzt\lib\Release'
  if (-not (Test-Path $exe)) {
    throw "smoke harness not found: $exe"
  }
  $oldPath = $env:PATH
  $stdoutPath = Join-Path $ProjectRoot 'build\zt_runtime_smoke.stdout.log'
  $stderrPath = Join-Path $ProjectRoot 'build\zt_runtime_smoke.stderr.log'
  $timedOut = $false
  try {
    $env:PATH = "$dllDir;$oldPath"
    if (Test-Path $stdoutPath) { Remove-Item $stdoutPath -Force }
    if (Test-Path $stderrPath) { Remove-Item $stderrPath -Force }
    if ($CleanupStaleSmoke) {
      Get-Process zt_runtime_smoke -ErrorAction SilentlyContinue | ForEach-Object {
        try {
          & taskkill /PID $_.Id /T /F | Out-Null
        } catch {
        }
      }
    }
    $proc = Start-Process -FilePath $exe `
      -NoNewWindow `
      -PassThru `
      -ArgumentList @('--join-timeout-ms', $JoinTimeoutMs.ToString()) `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath
    try {
      Wait-Process -Id $proc.Id -Timeout $TimeoutSec -ErrorAction Stop
    } catch {
      $timedOut = $true
    }
    $proc.Refresh()
    $timedOut = $timedOut -or -not $proc.HasExited
    if ($timedOut) {
      try {
        & taskkill /PID $proc.Id /T /F | Out-Null
      } catch {
        try {
          Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        } catch {
        }
      }
      Start-Sleep -Milliseconds 500
      $proc.Refresh()
    }
    $exitCode = if ($timedOut -or -not $proc.HasExited) { 124 } else { $proc.ExitCode }
  } finally {
    $env:PATH = $oldPath
  }
  $output = @()
  if (Test-Path $stdoutPath) {
    $output += Get-Content -LiteralPath $stdoutPath
  }
  if (Test-Path $stderrPath) {
    $output += Get-Content -LiteralPath $stderrPath
  }
  return [pscustomobject]@{
    ExitCode = $exitCode
    TimedOut = $timedOut
    StdoutPath = $stdoutPath
    StderrPath = $stderrPath
    Output = @($output)
  }
}

function Find-EventLines {
  param(
    [string[]]$Lines,
    [string]$Pattern
  )
  return [object[]]@($Lines | Where-Object { $_ -match $Pattern })
}

function Summarize-SmokeOutput {
  param([string[]]$Lines)
  $networkOk = Find-EventLines -Lines $Lines -Pattern 'ZTS_EVENT_NETWORK_OK|type=networkOnline'
  $networkReadyIp = Find-EventLines -Lines $Lines -Pattern 'ZTS_EVENT_NETWORK_READY_IP4|ZTS_EVENT_NETWORK_READY_IP6|ZTS_EVENT_NETWORK_READY_IP4_IP6'
  $addrAdded = Find-EventLines -Lines $Lines -Pattern 'ZTS_EVENT_ADDR_ADDED_IP4|ZTS_EVENT_ADDR_ADDED_IP6|type=ipAssigned'
  $nodeOffline = Find-EventLines -Lines $Lines -Pattern 'ZTS_EVENT_NODE_OFFLINE|type=nodeOffline'
  $networkDown = Find-EventLines -Lines $Lines -Pattern 'ZTS_EVENT_NETWORK_DOWN|NetworkDown diagnostics'
  $joinRecoveryAnomaly = Find-EventLines -Lines $Lines -Pattern 'Join recovery anomaly'
  $joinSnapshots = Find-EventLines -Lines $Lines -Pattern '\[ZT/WIN\] JoinNetwork wait snapshot'
  $mountSnapshots = Find-EventLines -Lines $Lines -Pattern 'local_mount_state='
  $lastJoinSnapshot = if (@($joinSnapshots).Count -gt 0) { $joinSnapshots[-1] } else { $null }
  $lastMountSnapshot = if (@($mountSnapshots).Count -gt 0) { $mountSnapshots[-1] } else { $null }
  return [pscustomobject]@{
    NetworkOkCount = @($networkOk).Count
    NetworkReadyIpCount = @($networkReadyIp).Count
    AddrAddedCount = @($addrAdded).Count
    NodeOfflineCount = @($nodeOffline).Count
    NetworkDownCount = @($networkDown).Count
    JoinRecoveryAnomalyCount = @($joinRecoveryAnomaly).Count
    LastJoinSnapshot = $lastJoinSnapshot
    LastMountSnapshot = $lastMountSnapshot
    ErrorLines = @(Find-EventLines -Lines $Lines -Pattern 'error=|type=error|timed out|stayed offline')
  }
}

$runtimeNodeDir = Join-Path $RuntimeRoot 'node'
$networksDir = Join-Path $runtimeNodeDir 'networks.d'
$knownNetworksPath = Join-Path $RuntimeRoot 'known_networks.txt'
$report = [ordered]@{}
$stdoutLogPath = Join-Path $ProjectRoot 'build\zt_runtime_smoke.stdout.log'
$stderrLogPath = Join-Path $ProjectRoot 'build\zt_runtime_smoke.stderr.log'
$existingSmokeLogsAvailable = (Test-Path $stdoutLogPath) -or (Test-Path $stderrLogPath)
$shouldUseExistingSmokeLogs = $UseExistingSmokeLogs -or (-not $ForceSmoke -and -not $SkipSmoke -and $existingSmokeLogsAvailable)

Write-Section 'Environment'
$cmakePath = Get-CmakePath
$report.CmakePath = $cmakePath
$report.ProjectRoot = $ProjectRoot
$report.RuntimeRoot = $RuntimeRoot
Write-Host "cmake: $cmakePath"
Write-Host "project: $ProjectRoot"
Write-Host "runtime: $RuntimeRoot"
$smokeHarnessIsStale = Test-SmokeHarnessIsStale -ProjectRoot $ProjectRoot
if ($SkipBuild -and $smokeHarnessIsStale) {
  Write-Host 'warning: zt_runtime_smoke.exe is older than its sources; -SkipBuild may reuse stale join-timeout behavior.'
}

Write-Section 'Known Networks'
$knownNetworks = if (Test-Path $knownNetworksPath) { [object[]]@(Get-Content -LiteralPath $knownNetworksPath) } else { @() }
$report.KnownNetworks = @($knownNetworks)
  if (@($knownNetworks).Count -eq 0) {
  Write-Host 'No known networks file entries.'
} else {
  $knownNetworks | ForEach-Object { Write-Host $_ }
}

Write-Section 'Config Files'
$confSummary = [object[]]@(Get-NetworkConfSummary -NetworksDir $networksDir)
$confDecode = [object[]]@(Get-NetworkConfDecode -NetworksDir $networksDir)
$report.NetworkConfigs = $confSummary
$report.NetworkConfigDecode = $confDecode
  if (@($confSummary).Count -eq 0) {
  Write-Host 'No network conf files found.'
} else {
  $confSummary | Format-Table -AutoSize | Out-Host
}

Write-Section 'Config Decode'
if (@($confDecode).Count -eq 0) {
  Write-Host 'No decodable network config entries found.'
} else {
  $confDecode | Select-Object File, NetworkId, ComMeaning, HasStaticIpBlob, StaticIps, HasRouteBlob, Routes, HasRulesBlob, HasDnsBlob, AddressDeliveryHint |
    Format-Table -Wrap -AutoSize | Out-Host
}

Write-Section 'Adapters'
$adapters = Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, MacAddress, InterfaceIndex
$adapters | Format-Table -AutoSize | Out-Host

Write-Section 'Address Inventory'
$netIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Select-Object InterfaceAlias, IPAddress, PrefixLength, AddressState, ValidLifetime
$netIp | Format-Table -AutoSize | Out-Host

if (-not $SkipBuild -and -not $shouldUseExistingSmokeLogs) {
  Write-Section 'Build Smoke Harness'
  Build-SmokeHarness -ProjectRoot $ProjectRoot -CmakePath $cmakePath
}

if ($shouldUseExistingSmokeLogs) {
  Write-Section 'Use Existing Smoke Logs'
  $smokeLines = @()
  if (Test-Path $stdoutLogPath) {
    $smokeLines += Get-Content -LiteralPath $stdoutLogPath
  }
  if (Test-Path $stderrLogPath) {
    $smokeLines += Get-Content -LiteralPath $stderrLogPath
  }
  $report.SmokeStdoutPath = $stdoutLogPath
  $report.SmokeStderrPath = $stderrLogPath
  $summary = Summarize-SmokeOutput -Lines $smokeLines
  $report.SmokeSummary = $summary
  Write-Host "networkOnline/NETWORK_OK count: $($summary.NetworkOkCount)"
  Write-Host "NETWORK_READY_IP* count: $($summary.NetworkReadyIpCount)"
  Write-Host "ADDR_ADDED/IP count: $($summary.AddrAddedCount)"
  Write-Host "nodeOffline count: $($summary.NodeOfflineCount)"
  Write-Host "networkDown count: $($summary.NetworkDownCount)"
  Write-Host "join recovery anomaly count: $($summary.JoinRecoveryAnomalyCount)"
  if ($summary.LastJoinSnapshot) {
    Write-Host "last join snapshot: $($summary.LastJoinSnapshot)"
  }
  if ($summary.LastMountSnapshot) {
    Write-Host "last mount snapshot: $($summary.LastMountSnapshot)"
  }
  if (@($summary.ErrorLines).Count -gt 0) {
    Write-Host 'error lines:'
    $summary.ErrorLines | Select-Object -Last 10 | ForEach-Object { Write-Host $_ }
  }
}
elseif (-not $SkipSmoke) {
  Write-Section 'Run Smoke Harness'
  $smoke = Invoke-SmokeHarness `
    -ProjectRoot $ProjectRoot `
    -TimeoutSec $SmokeTimeoutSec `
    -JoinTimeoutMs $JoinTimeoutMs `
    -CleanupStaleSmoke:$CleanupStaleSmoke
  $report.SmokeExitCode = $smoke.ExitCode
  $report.SmokeTimedOut = $smoke.TimedOut
  $report.SmokeStdoutPath = $smoke.StdoutPath
  $report.SmokeStderrPath = $smoke.StderrPath
  Write-Host "smoke exit code: $($smoke.ExitCode)"
  if ($smoke.TimedOut) {
    Write-Host "smoke timed out after ${SmokeTimeoutSec}s; summarizing partial logs."
  }
  $summary = Summarize-SmokeOutput -Lines $smoke.Output
  $report.SmokeSummary = $summary
  Write-Host "networkOnline/NETWORK_OK count: $($summary.NetworkOkCount)"
  Write-Host "NETWORK_READY_IP* count: $($summary.NetworkReadyIpCount)"
  Write-Host "ADDR_ADDED/IP count: $($summary.AddrAddedCount)"
  Write-Host "nodeOffline count: $($summary.NodeOfflineCount)"
  Write-Host "networkDown count: $($summary.NetworkDownCount)"
  Write-Host "join recovery anomaly count: $($summary.JoinRecoveryAnomalyCount)"
  if ($summary.LastJoinSnapshot) {
    Write-Host "last join snapshot: $($summary.LastJoinSnapshot)"
  }
  if ($summary.LastMountSnapshot) {
    Write-Host "last mount snapshot: $($summary.LastMountSnapshot)"
  }
  if (@($summary.ErrorLines).Count -gt 0) {
    Write-Host 'error lines:'
    $summary.ErrorLines | Select-Object -Last 10 | ForEach-Object { Write-Host $_ }
  }
}

Write-Section 'Findings'
if (@($confSummary).Count -gt 0) {
  $missingNodeId = @($confSummary | Where-Object { $_.NodeId -ne '6703cc882d' })
  if (@($missingNodeId).Count -eq 0) {
    Write-Host 'All network conf files are bound to node id 6703cc882d.'
  }
  $noAddressEvidence = @($confDecode | Where-Object { -not $_.HasStaticIpBlob -and [string]::IsNullOrWhiteSpace($_.StaticIps) })
  if (@($noAddressEvidence).Count -gt 0) {
    Write-Host 'Some conf files do not show static managed IP evidence in decoded netconf fields:'
    $noAddressEvidence | Format-Table File, NetworkId, ComMeaning, HasRouteBlob, HasRulesBlob, HasDnsBlob, AddressDeliveryHint -AutoSize | Out-Host
  } else {
    Write-Host 'Decoded netconf includes static managed IP assignments.'
  }
  $comOnly = @($confDecode | Where-Object { $_.ComMeaning -eq 'certificate_of_membership' -and -not $_.HasStaticIpBlob })
  if (@($comOnly).Count -gt 0) {
    Write-Host 'Note: C= is the COM blob, not the managed IP list; managed IPs would be carried in I= when present.'
  }
}
if ($report.Contains('SmokeSummary')) {
  if ($report.SmokeSummary.NetworkOkCount -gt 0 -and $report.SmokeSummary.AddrAddedCount -eq 0) {
    Write-Host 'Observed NETWORK_OK without any ADDR_ADDED_IP4/IP6 evidence.'
  }
  if ($report.SmokeSummary.NetworkOkCount -gt 0 -and $report.SmokeSummary.NetworkReadyIpCount -eq 0) {
    Write-Host 'Observed NETWORK_OK without any NETWORK_READY_IP4/IP6 evidence.'
  }
  if ($report.SmokeSummary.JoinRecoveryAnomalyCount -gt 0) {
    Write-Host 'Observed join recovery anomaly: NETWORK_OK arrived without READY_IP or ADDR_ADDED in the pending-join sequence.'
  }
  if ($report.SmokeSummary.NetworkDownCount -gt 0) {
    Write-Host 'Observed NETWORK_DOWN during the captured regression window.'
  }
  if ($report.SmokeSummary.NodeOfflineCount -gt 0) {
    Write-Host 'Observed nodeOffline during join regression; this points to node/routing instability rather than pure UI state mismatch.'
  }
}

if ($WriteReport) {
  $reportPath = Join-Path $ProjectRoot 'build\zt_runtime_audit_report.json'
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
  Write-Host ""
  Write-Host "Report written to $reportPath"
}
