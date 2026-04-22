param(
  [int]$Seconds = 90,
  [int]$IntervalMs = 1000,
  [string]$IpPrefix = "172.29.",
  [string]$OutputFile = ""
)

$ErrorActionPreference = "Continue"

if ([string]::IsNullOrWhiteSpace($OutputFile)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutputFile = Join-Path $PSScriptRoot ("zt_env_watch_" + $stamp + ".log")
}

"ZeroTier Env Watch started @ $(Get-Date -Format o)" | Out-File -FilePath $OutputFile -Encoding UTF8
"Seconds=$Seconds IntervalMs=$IntervalMs IpPrefix=$IpPrefix" | Out-File -FilePath $OutputFile -Encoding UTF8 -Append

$iterations = [Math]::Max(1, [int][Math]::Ceiling(($Seconds * 1000.0) / $IntervalMs))
for ($i = 0; $i -lt $iterations; $i++) {
  $ts = Get-Date -Format "HH:mm:ss.fff"
  "[$ts] ---- snapshot $($i + 1)/$iterations ----" | Out-File -FilePath $OutputFile -Encoding UTF8 -Append

  try {
    $hitIps = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "$IpPrefix*" }
    if ($hitIps) {
      $hitIps |
        Select-Object InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState |
        Format-Table -AutoSize | Out-String | Out-File -FilePath $OutputFile -Encoding UTF8 -Append
    } else {
      "No IP matches $IpPrefix*" | Out-File -FilePath $OutputFile -Encoding UTF8 -Append
    }
  } catch {
    "IP check error: $($_.Exception.Message)" | Out-File -FilePath $OutputFile -Encoding UTF8 -Append
  }

  try {
    $ztIf = Get-NetAdapter | Where-Object {
      $_.Name -match "ZeroTier|TAP|Wintun|VPN" -or $_.InterfaceDescription -match "ZeroTier|TAP|Wintun|VPN"
    }
    if ($ztIf) {
      $ztIf | Select-Object Name, InterfaceDescription, InterfaceIndex, Status, LinkSpeed |
        Format-Table -AutoSize | Out-String | Out-File -FilePath $OutputFile -Encoding UTF8 -Append
    } else {
      "No ZeroTier/TAP/Wintun/VPN adapter found." | Out-File -FilePath $OutputFile -Encoding UTF8 -Append
    }
  } catch {
    "Adapter check error: $($_.Exception.Message)" | Out-File -FilePath $OutputFile -Encoding UTF8 -Append
  }

  Start-Sleep -Milliseconds $IntervalMs
}

"Watch completed @ $(Get-Date -Format o)" | Out-File -FilePath $OutputFile -Encoding UTF8 -Append
Write-Host "Saved: $OutputFile"
