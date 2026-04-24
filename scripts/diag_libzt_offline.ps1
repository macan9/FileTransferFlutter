[CmdletBinding()]
param(
    [string]$NetworkId = "",
    [switch]$JoinNetwork,
    [int]$PollIntervalSeconds = 1,
    [int]$MaxMonitorMinutes = 15,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$BuildIfMissing
)

$ErrorActionPreference = 'Stop'
$script:ZeroTierCliPath = $null

function Resolve-ZeroTierCliPath {
    $candidates = @(
        'C:\Program Files\ZeroTier\One\zerotier-cli.bat',
        'C:\Program Files\ZeroTier\One\zerotier-cli.exe',
        'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.bat',
        'C:\Program Files (x86)\ZeroTier\One\zerotier-cli.exe',
        'C:\ProgramData\ZeroTier\One\zerotier-cli.bat',
        'C:\ProgramData\ZeroTier\One\zerotier-cli.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $command = Get-Command zerotier-cli -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    return $null
}

function New-LogSection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    Add-Content -LiteralPath $Path -Value "===== $timestamp $Title ====="
    Add-Content -LiteralPath $Path -Value $Content
    Add-Content -LiteralPath $Path -Value ""
}

function Invoke-SafeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    try {
        return (& $ScriptBlock 2>&1 | Out-String -Width 4096).TrimEnd()
    } catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

function Append-Snapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory
    )

    $snapshots = @(
        @{
            Name = 'route_print.log'
            Title = 'route print'
            Command = { route.exe print }
        },
        @{
            Name = 'net_adapter.log'
            Title = 'Get-NetAdapter'
            Command = { Get-NetAdapter | Format-Table -AutoSize | Out-String -Width 4096 }
        },
        @{
            Name = 'udp_9993.log'
            Title = 'Get-NetUDPEndpoint -LocalPort 9993'
            Command = { Get-NetUDPEndpoint -LocalPort 9993 | Format-List * | Out-String -Width 4096 }
        },
        @{
            Name = 'netstat_udp.log'
            Title = 'netstat -ano -p udp'
            Command = { netstat -ano -p udp }
        },
        @{
            Name = 'firewall_profile.log'
            Title = 'Get-NetFirewallProfile'
            Command = { Get-NetFirewallProfile | Format-List * | Out-String -Width 4096 }
        },
        @{
            Name = 'zerotier_info.log'
            Title = 'zerotier-cli info -j'
            Command = {
                if ([string]::IsNullOrWhiteSpace($script:ZeroTierCliPath)) {
                    throw 'zerotier-cli not found'
                }
                & $script:ZeroTierCliPath info -j
            }
        },
        @{
            Name = 'zerotier_peers.log'
            Title = 'zerotier-cli peers'
            Command = {
                if ([string]::IsNullOrWhiteSpace($script:ZeroTierCliPath)) {
                    throw 'zerotier-cli not found'
                }
                & $script:ZeroTierCliPath peers
            }
        }
    )

    foreach ($snapshot in $snapshots) {
        $output = Invoke-SafeCommand -ScriptBlock $snapshot.Command
        New-LogSection -Path (Join-Path $LogDirectory $snapshot.Name) `
            -Title $snapshot.Title `
            -Content $output
    }
}

function Read-NewLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [ref]$KnownLineCount
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $lines = Get-Content -LiteralPath $Path
    if ($null -eq $lines) {
        return @()
    }

    if ($lines -is [string]) {
        $lines = @($lines)
    }

    if ($KnownLineCount.Value -ge $lines.Count) {
        return @()
    }

    $newLines = $lines[$KnownLineCount.Value..($lines.Count - 1)]
    $KnownLineCount.Value = $lines.Count
    return $newLines
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logDirectory = Join-Path $repoRoot "logs\libzt-node\$timestamp"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$script:ZeroTierCliPath = Resolve-ZeroTierCliPath

$runnerDirectory = Join-Path $repoRoot "build\windows\x64\runner\$Configuration"
$smokeExe = Join-Path $runnerDirectory 'zt_runtime_smoke.exe'

if (-not (Test-Path -LiteralPath $smokeExe)) {
    if (-not $BuildIfMissing) {
        throw "Missing $smokeExe. Run flutter build windows --debug first, or rerun with -BuildIfMissing."
    }

    Push-Location $repoRoot
    try {
        if ($Configuration -eq 'Release') {
            flutter build windows --release
        } else {
            flutter build windows --debug
        }
    } finally {
        Pop-Location
    }
}

$stdoutPath = Join-Path $logDirectory 'libzt_monitor_stdout.log'
$stderrPath = Join-Path $logDirectory 'libzt_monitor_stderr.log'
$summaryPath = Join-Path $logDirectory 'session_summary.log'

$arguments = @('--monitor-until-offline', '--poll-interval-ms', ([string]($PollIntervalSeconds * 1000)))
if ($MaxMonitorMinutes -gt 0) {
    $arguments += @('--max-monitor-seconds', ([string]($MaxMonitorMinutes * 60)))
}
if (-not [string]::IsNullOrWhiteSpace($NetworkId)) {
    if ($JoinNetwork) {
        $arguments += @('--join-network', $NetworkId)
    }
    $arguments += @('--probe-network', $NetworkId)
}

New-LogSection -Path $summaryPath -Title 'session.start' -Content @"
repoRoot=$repoRoot
logDirectory=$logDirectory
smokeExe=$smokeExe
arguments=$($arguments -join ' ')
configuration=$Configuration
joinNetwork=$JoinNetwork
networkId=$NetworkId
pollIntervalSeconds=$PollIntervalSeconds
maxMonitorMinutes=$MaxMonitorMinutes
zerotierCliPath=$script:ZeroTierCliPath
"@

Push-Location $runnerDirectory
try {
    $process = Start-Process -FilePath $smokeExe `
        -ArgumentList $arguments `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru `
        -NoNewWindow `
        -WorkingDirectory $runnerDirectory
} finally {
    Pop-Location
}

$stdoutLineCount = 0
$stderrLineCount = 0
$sample = 0
$startedAt = Get-Date

Write-Host "logDirectory=$logDirectory"
Write-Host "started libzt monitor pid=$($process.Id)"

Append-Snapshot -LogDirectory $logDirectory

while (-not $process.HasExited) {
    $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
    $nowUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $statusLine = "[diag] ts=$nowUtc sample=$sample elapsedSeconds=$elapsed pid=$($process.Id) state=running"
    Write-Host $statusLine
    Add-Content -LiteralPath $summaryPath -Value $statusLine

    foreach ($line in (Read-NewLines -Path $stdoutPath -KnownLineCount ([ref]$stdoutLineCount))) {
        Write-Host $line
    }
    foreach ($line in (Read-NewLines -Path $stderrPath -KnownLineCount ([ref]$stderrLineCount))) {
        Write-Host "[stderr] $line"
    }

    Append-Snapshot -LogDirectory $logDirectory
    Start-Sleep -Seconds $PollIntervalSeconds
    $sample++
}

$process.WaitForExit()

foreach ($line in (Read-NewLines -Path $stdoutPath -KnownLineCount ([ref]$stdoutLineCount))) {
    Write-Host $line
}
foreach ($line in (Read-NewLines -Path $stderrPath -KnownLineCount ([ref]$stderrLineCount))) {
    Write-Host "[stderr] $line"
}

Append-Snapshot -LogDirectory $logDirectory

$exitCode = 'unknown'
try {
    $process.Refresh()
    $exitCode = [string]$process.ExitCode
} catch {
    $exitCode = "unavailable:$($_.Exception.Message)"
}

$exitSummary = "[diag] ts=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) processExited=true exitCode=$exitCode"
Write-Host $exitSummary
Add-Content -LiteralPath $summaryPath -Value $exitSummary

Write-Host "stdout=$stdoutPath"
Write-Host "stderr=$stderrPath"
