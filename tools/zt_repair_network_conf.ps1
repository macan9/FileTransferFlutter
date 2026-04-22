[CmdletBinding()]
param(
  [string]$RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'FileTransferFlutter\zerotier\node'),
  [string[]]$NetworkIds = @(),
  [switch]$ForceRewrite,
  [switch]$SkipBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Latin1Text {
  param([string]$Path)
  $latin1 = [System.Text.Encoding]::GetEncoding(28591)
  return $latin1.GetString([System.IO.File]::ReadAllBytes($Path))
}

function Write-Latin1Text {
  param(
    [string]$Path,
    [string]$Text
  )
  $latin1 = [System.Text.Encoding]::GetEncoding(28591)
  [System.IO.File]::WriteAllBytes($Path, $latin1.GetBytes($Text))
}

function Read-KeyValueFilePreserveOrder {
  param([string]$Path)
  $text = Read-Latin1Text -Path $Path
  $order = New-Object System.Collections.Generic.List[string]
  $map = [ordered]@{}
  foreach ($line in ($text -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    $parts = $line -split '=', 2
    if ($parts.Count -ne 2) {
      continue
    }
    $key = $parts[0]
    $value = $parts[1]
    if (-not $map.Contains($key)) {
      $order.Add($key)
    }
    $map[$key] = $value
  }
  return [pscustomobject]@{
    Order = $order
    Map = $map
  }
}

function ConvertTo-EscapedValue {
  param([byte[]]$Bytes)
  $builder = New-Object System.Text.StringBuilder
  foreach ($byte in $Bytes) {
    switch ($byte) {
      0 { [void]$builder.Append('\0') }
      10 { [void]$builder.Append('\n') }
      13 { [void]$builder.Append('\r') }
      61 { [void]$builder.Append('\e') }
      92 { [void]$builder.Append('\') }
      default { [void]$builder.Append([char]$byte) }
    }
  }
  return $builder.ToString()
}

function ConvertTo-UInt16BeBytes {
  param([int]$Value)
  return [byte[]]@(
    (($Value -shr 8) -band 0xff),
    ($Value -band 0xff)
  )
}

function ConvertTo-Ipv4AddressBytes {
  param(
    [string]$IpAddress,
    [int]$PrefixLength
  )
  $ip = [System.Net.IPAddress]::Parse($IpAddress)
  $addressBytes = $ip.GetAddressBytes()
  if ($addressBytes.Length -ne 4) {
    throw "Only IPv4 is supported: $IpAddress"
  }
  $output = New-Object System.Collections.Generic.List[byte]
  [void]$output.Add(0x04)
  foreach ($byte in $addressBytes) {
    [void]$output.Add($byte)
  }
  foreach ($byte in (ConvertTo-UInt16BeBytes -Value $PrefixLength)) {
    [void]$output.Add($byte)
  }
  return $output.ToArray()
}

function ConvertTo-NullInetAddressBytes {
  return [byte[]]@(0x00)
}

function ConvertTo-RouteBlobBytes {
  param(
    [string]$TargetCidr,
    [int]$Flags = 0,
    [int]$Metric = 0
  )
  $parts = $TargetCidr -split '/', 2
  if ($parts.Count -ne 2) {
    throw "Invalid CIDR: $TargetCidr"
  }
  $targetBytes = ConvertTo-Ipv4AddressBytes -IpAddress $parts[0] -PrefixLength ([int]$parts[1])
  $viaBytes = ConvertTo-NullInetAddressBytes
  $output = New-Object System.Collections.Generic.List[byte]
  foreach ($byte in $targetBytes) { [void]$output.Add($byte) }
  foreach ($byte in $viaBytes) { [void]$output.Add($byte) }
  foreach ($byte in (ConvertTo-UInt16BeBytes -Value $Flags)) { [void]$output.Add($byte) }
  foreach ($byte in (ConvertTo-UInt16BeBytes -Value $Metric)) { [void]$output.Add($byte) }
  return $output.ToArray()
}

function Get-NodeId {
  param([string]$RuntimeRoot)
  $identityPath = Join-Path $RuntimeRoot 'identity.public'
  if (-not (Test-Path $identityPath)) {
    throw "identity.public not found under $RuntimeRoot"
  }
  $raw = (Get-Content -LiteralPath $identityPath -TotalCount 1).Trim()
  $parts = $raw -split ':', 2
  if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace($parts[0])) {
    throw "Failed to read node id from $identityPath"
  }
  return $parts[0].Trim().ToLowerInvariant()
}

function Get-ManagedIpv4Plan {
  param(
    [string]$NetworkId,
    [string]$NodeId
  )
  $nwid = [UInt64]::Parse($NetworkId, [System.Globalization.NumberStyles]::HexNumber)
  $nodeTail = [UInt32]::Parse($NodeId.Substring([Math]::Max(0, $NodeId.Length - 2)), [System.Globalization.NumberStyles]::HexNumber)
  $secondOctet = 64 + (($nwid -shr 16) -band 0x3f)
  $thirdOctet = (($nwid -shr 8) -band 0xff)
  $hostOctet = (($nodeTail % 253) + 1)
  return [pscustomobject]@{
    Route = "10.$secondOctet.$thirdOctet.0/24"
    Address = "10.$secondOctet.$thirdOctet.$hostOctet/24"
  }
}

function Set-KeyValue {
  param(
    $Map,
    [System.Collections.Generic.List[string]]$Order,
    [string]$Key,
    [string]$Value,
    [string]$AfterKey = 'mtu'
  )
  if ($Map.Contains($Key)) {
    $Map[$Key] = $Value
    return
  }
  $insertIndex = -1
  for ($index = 0; $index -lt $Order.Count; $index++) {
    if ($Order[$index] -eq $AfterKey) {
      $insertIndex = $index + 1
      break
    }
  }
  if ($insertIndex -lt 0 -or $insertIndex -gt $Order.Count) {
    $Order.Add($Key)
  } else {
    $Order.Insert($insertIndex, $Key)
  }
  $Map[$Key] = $Value
}

function Write-KeyValueFilePreserveOrder {
  param(
    [string]$Path,
    $Map,
    [System.Collections.Generic.List[string]]$Order
  )
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($key in $Order) {
    if ($Map.Contains($key)) {
      $lines.Add("$key=$($Map[$key])")
    }
  }
  $text = ($lines -join "`r`n") + "`r`n"
  Write-Latin1Text -Path $Path -Text $text
}

$networksDir = Join-Path $RuntimeRoot 'networks.d'
if (-not (Test-Path $networksDir)) {
  throw "networks.d not found under $RuntimeRoot"
}

$nodeId = Get-NodeId -RuntimeRoot $RuntimeRoot
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$targetFiles = Get-ChildItem -LiteralPath $networksDir -Filter '*.conf' | Sort-Object Name
if ($NetworkIds.Count -gt 0) {
  $wanted = @{}
  foreach ($networkId in $NetworkIds) {
    $wanted[$networkId.ToLowerInvariant()] = $true
  }
  $targetFiles = @($targetFiles | Where-Object {
      $wanted.ContainsKey(([System.IO.Path]::GetFileNameWithoutExtension($_.Name)).ToLowerInvariant())
    })
}

if ($targetFiles.Count -eq 0) {
  throw 'No matching network conf files were found.'
}

$results = @()
foreach ($file in $targetFiles) {
  $parsed = Read-KeyValueFilePreserveOrder -Path $file.FullName
  $map = $parsed.Map
  $order = $parsed.Order
  $networkId = [string]$map['nwid']
  if ([string]::IsNullOrWhiteSpace($networkId)) {
    $networkId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
  }
  $plan = Get-ManagedIpv4Plan -NetworkId $networkId -NodeId $nodeId
  $hadRoute = $map.Contains('RT')
  $hadIp = $map.Contains('I')
  $needsRewrite = $ForceRewrite -or (-not $hadRoute) -or (-not $hadIp)
  if (-not $needsRewrite) {
    $results += [pscustomobject]@{
      NetworkId = $networkId
      File = $file.Name
      Changed = $false
      Route = $plan.Route
      Address = $plan.Address
      Note = 'already_has_route_and_ip'
    }
    continue
  }

  if (-not $SkipBackup) {
    $backupPath = "$($file.FullName).bak-$timestamp"
    Copy-Item -LiteralPath $file.FullName -Destination $backupPath -Force
  }

  $routeBlob = ConvertTo-EscapedValue -Bytes (ConvertTo-RouteBlobBytes -TargetCidr $plan.Route)
  $ipParts = $plan.Address -split '/', 2
  $ipBlob = ConvertTo-EscapedValue -Bytes (ConvertTo-Ipv4AddressBytes -IpAddress $ipParts[0] -PrefixLength ([int]$ipParts[1]))

  Set-KeyValue -Map $map -Order $order -Key 'RT' -Value $routeBlob
  Set-KeyValue -Map $map -Order $order -Key 'I' -Value $ipBlob
  Write-KeyValueFilePreserveOrder -Path $file.FullName -Map $map -Order $order

  $results += [pscustomobject]@{
    NetworkId = $networkId
    File = $file.Name
    Changed = $true
    Route = $plan.Route
    Address = $plan.Address
    Note = if ($ForceRewrite) { 'rewritten' } else { 'repaired_missing_route_or_ip' }
  }
}

$results | Format-Table -AutoSize | Out-Host
