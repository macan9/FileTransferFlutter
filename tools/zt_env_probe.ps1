$ErrorActionPreference = "Continue"

function Write-Section {
  param([string]$Title)
  Write-Host ""
  Write-Host ("=" * 20 + " " + $Title + " " + "=" * 20)
}

function Try-Run {
  param(
    [string]$Label,
    [scriptblock]$Block
  )
  Write-Host ""
  Write-Host ("[Probe] " + $Label)
  try {
    & $Block
  } catch {
    Write-Host ("[Probe:ERROR] " + $_.Exception.Message)
  }
}

$timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff K")
Write-Host ("ZeroTier Local Env Probe @ " + $timestamp)

$ztNetworkId = "31756fbd65bfbf76"
$ztIpPrefix = "172.29."

Write-Section "System"
Try-Run "Windows Version" { Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber }
Try-Run "PowerShell Version" { $PSVersionTable | Select-Object PSVersion, PSEdition, Platform }

Write-Section "Adapters"
Try-Run "All Up Adapters" {
  Get-NetAdapter | Where-Object { $_.Status -eq "Up" } |
    Select-Object Name, InterfaceDescription, InterfaceIndex, MacAddress, LinkSpeed, Status |
    Sort-Object InterfaceIndex | Format-Table -AutoSize
}
Try-Run "All Adapters (including Down/Hidden)" {
  Get-NetAdapter -IncludeHidden |
    Select-Object Name, InterfaceDescription, InterfaceIndex, Status, MediaConnectionState, LinkSpeed |
    Sort-Object InterfaceIndex | Format-Table -AutoSize
}
Try-Run "ZeroTier/TAP/Wintun Related Adapters" {
  Get-NetAdapter -IncludeHidden | Where-Object {
    $_.Name -match "ZeroTier|TAP|Wintun|VPN" -or $_.InterfaceDescription -match "ZeroTier|TAP|Wintun|VPN"
  } | Select-Object Name, InterfaceDescription, InterfaceIndex, Status, LinkSpeed | Format-Table -AutoSize
}

Write-Section "Services & Drivers"
Try-Run "ZeroTier/TAP/Wintun Service" {
  Get-Service | Where-Object {
    $_.Name -match "ZeroTier|Wintun|tap" -or $_.DisplayName -match "ZeroTier|Wintun|TAP"
  } | Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize
}
Try-Run "Network Class PnP (ZeroTier/TAP/Wintun)" {
  Get-PnpDevice -Class Net | Where-Object {
    $_.FriendlyName -match "ZeroTier|TAP|Wintun|VPN" -or $_.InstanceId -match "Wintun|tap"
  } | Select-Object Status, Class, FriendlyName, InstanceId | Format-Table -AutoSize
}

Write-Section "IP Addressing"
Try-Run "IPv4 Addresses" {
  Get-NetIPAddress -AddressFamily IPv4 |
    Select-Object InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState |
    Sort-Object InterfaceIndex | Format-Table -AutoSize
}
Try-Run "Target ZeroTier Prefix ($ztIpPrefix*)" {
  Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "$ztIpPrefix*" } |
    Select-Object InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState |
    Format-Table -AutoSize
}

Write-Section "Routing"
Try-Run "IPv4 Routes (ActiveStore)" {
  Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore |
    Select-Object DestinationPrefix, InterfaceIndex, NextHop, RouteMetric, State |
    Sort-Object InterfaceIndex, DestinationPrefix | Format-Table -AutoSize
}
Try-Run "Routes related to $ztIpPrefix* or interface with ZeroTier keyword" {
  $zeroTierIfs = Get-NetAdapter | Where-Object {
    $_.Name -match "ZeroTier|TAP|Wintun|VPN" -or $_.InterfaceDescription -match "ZeroTier|TAP|Wintun|VPN"
  } | Select-Object -ExpandProperty InterfaceIndex

  Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore | Where-Object {
    $_.DestinationPrefix -like "$ztIpPrefix*" -or $zeroTierIfs -contains $_.InterfaceIndex
  } | Select-Object DestinationPrefix, InterfaceIndex, NextHop, RouteMetric, State |
    Sort-Object InterfaceIndex, DestinationPrefix | Format-Table -AutoSize
}

Write-Section "Runtime Files"
$rtRoot = Join-Path $env:LOCALAPPDATA "FileTransferFlutter\\zerotier"
$knownNetworksFile = Join-Path $rtRoot "known_networks.txt"
Try-Run "Runtime Root" { Write-Host $rtRoot }
Try-Run "Known Networks File Exists" { Test-Path $knownNetworksFile }
Try-Run "Known Networks Content" {
  if (Test-Path $knownNetworksFile) {
    Get-Content $knownNetworksFile
  } else {
    Write-Host "(missing)"
  }
}

Write-Section "Focused Checks"
Try-Run "Check target network id in known networks" {
  if (Test-Path $knownNetworksFile) {
    $content = Get-Content $knownNetworksFile
    $found = $content | Where-Object { $_.Trim().ToLower() -eq $ztNetworkId }
    if ($found) {
      Write-Host "FOUND $ztNetworkId"
    } else {
      Write-Host "NOT FOUND $ztNetworkId"
    }
  } else {
    Write-Host "known_networks.txt missing"
  }
}
Try-Run "Check if any interface has $ztIpPrefix*" {
  $rows = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "$ztIpPrefix*" }
  if ($rows) {
    $rows | Select-Object InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState | Format-Table -AutoSize
  } else {
    Write-Host "No interface has IP $ztIpPrefix*"
  }
}

Write-Section "Done"
Write-Host "Probe completed."
