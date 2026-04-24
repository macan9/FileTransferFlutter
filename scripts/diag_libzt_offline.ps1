[CmdletBinding()]
param(
    [string]$NetworkId = "",
    [switch]$JoinNetwork,
    [int]$PollIntervalSeconds = 1,
    [int]$MaxMonitorMinutes = 2,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$BuildIfMissing,
    [switch]$EnablePktMon = $true,
    [int]$PktMonFileSizeMb = 128
)

$ErrorActionPreference = 'Stop'
$script:ZeroTierCliPath = $null
$script:PktMonPath = $null
$script:MountServiceExePath = $null

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

function Resolve-PktMonPath {
    $command = Get-Command pktmon -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidate = Join-Path $env:WINDIR 'System32\PktMon.exe'
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    return $null
}

function Resolve-MountServiceExePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$Configuration
    )

    $candidates = @(
        (Join-Path $RepoRoot ("build\windows\x64\runner\" + $Configuration + "_diag\zt_mount_service_diag.exe")),
        (Join-Path $RepoRoot ("build\windows\x64\runner\" + $Configuration + "\zt_mount_helper.exe")),
        (Join-Path $RepoRoot ("build\windows\x64\runner\" + $Configuration + "\zt_mount_service.exe"))
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-LibztNodePort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StderrPath
    )

    if (-not (Test-Path -LiteralPath $StderrPath)) {
        return $null
    }

    $matches = Select-String -LiteralPath $StderrPath -Pattern 'port=(\d+)' -AllMatches -ErrorAction SilentlyContinue
    if ($null -eq $matches) {
        return $null
    }

    $lastPort = $null
    foreach ($match in $matches) {
        foreach ($capture in $match.Matches) {
            $lastPort = $capture.Groups[1].Value
        }
    }
    return $lastPort
}

function Append-Snapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,
        [int]$ProcessId = 0,
        [string]$ProcessPath = "",
        [string]$StderrPath = ""
    )

    $currentNodePort = $null
    if (-not [string]::IsNullOrWhiteSpace($StderrPath)) {
        $currentNodePort = Get-LibztNodePort -StderrPath $StderrPath
    }

    $snapshots = @(
        @{
            Name = 'runtime_process.log'
            Title = 'Runtime process identity'
            Command = {
                [PSCustomObject]@{
                    ProcessId = $ProcessId
                    ProcessPath = $ProcessPath
                    NodePort = $(if ($null -eq $currentNodePort) { '' } else { $currentNodePort })
                } | Format-List * | Out-String -Width 4096
            }
        },
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
            Name = 'runtime_udp_by_pid.log'
            Title = 'Get-NetUDPEndpoint for runtime PID'
            Command = {
                if ($ProcessId -le 0) {
                    throw 'runtime pid unavailable'
                }
                Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
                    Where-Object { $_.OwningProcess -eq $ProcessId } |
                    Format-List * | Out-String -Width 4096
            }
        },
        @{
            Name = 'runtime_netstat_by_pid.log'
            Title = 'netstat -ano -p udp filtered by runtime PID'
            Command = {
                if ($ProcessId -le 0) {
                    throw 'runtime pid unavailable'
                }
                netstat -ano -p udp | Select-String -Pattern ("\\s{0,}$ProcessId$")
            }
        },
        @{
            Name = 'runtime_udp_by_port.log'
            Title = 'Get-NetUDPEndpoint for detected node port'
            Command = {
                if ([string]::IsNullOrWhiteSpace($currentNodePort)) {
                    throw 'node port unavailable'
                }
                Get-NetUDPEndpoint -LocalPort ([int]$currentNodePort) |
                    Format-List * | Out-String -Width 4096
            }
        },
        @{
            Name = 'runtime_udp_port_owners.log'
            Title = 'UDP endpoint owners for detected node port'
            Command = {
                if ([string]::IsNullOrWhiteSpace($currentNodePort)) {
                    throw 'node port unavailable'
                }
                $port = [int]$currentNodePort
                $endpoints = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
                    Where-Object { $_.LocalPort -eq $port } |
                    Sort-Object OwningProcess, LocalAddress
                if (-not $endpoints) {
                    "no udp endpoint owner found for port $port"
                    return
                }
                $rows = foreach ($endpoint in $endpoints) {
                    $processInfo = Get-Process -Id $endpoint.OwningProcess -ErrorAction SilentlyContinue
                    [PSCustomObject]@{
                        LocalAddress = $endpoint.LocalAddress
                        LocalPort = $endpoint.LocalPort
                        OwningProcess = $endpoint.OwningProcess
                        ProcessName = $(if ($processInfo) { $processInfo.ProcessName } else { '' })
                        Path = $(if ($processInfo) { $processInfo.Path } else { '' })
                        CreationTime = $(if ($processInfo) { $processInfo.StartTime } else { $null })
                        OffloadState = $endpoint.OffloadState
                    }
                }
                $rows | Format-List * | Out-String -Width 4096
            }
        },
        @{
            Name = 'runtime_udp_port_conflicts.log'
            Title = 'UDP owner conflicts across runtime ports'
            Command = {
                if ($ProcessId -le 0) {
                    throw 'runtime pid unavailable'
                }
                $runtimeEndpoints = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
                    Where-Object { $_.OwningProcess -eq $ProcessId }
                if (-not $runtimeEndpoints) {
                    "runtime pid $ProcessId has no visible udp endpoints"
                    return
                }
                $ports = @($runtimeEndpoints | Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
                $allRows = foreach ($port in $ports) {
                    Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
                        Where-Object { $_.LocalPort -eq $port } |
                        ForEach-Object {
                            $processInfo = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
                            [PSCustomObject]@{
                                LocalPort = $_.LocalPort
                                LocalAddress = $_.LocalAddress
                                OwningProcess = $_.OwningProcess
                                ProcessName = $(if ($processInfo) { $processInfo.ProcessName } else { '' })
                                Path = $(if ($processInfo) { $processInfo.Path } else { '' })
                            }
                        }
                }
                $allRows | Sort-Object LocalPort, OwningProcess, LocalAddress | Format-Table -AutoSize | Out-String -Width 4096
            }
        },
        @{
            Name = 'runtime_process_tasklist.log'
            Title = 'tasklist for runtime pid and udp owners'
            Command = {
                $pids = [System.Collections.Generic.HashSet[int]]::new()
                if ($ProcessId -gt 0) {
                    [void]$pids.Add([int]$ProcessId)
                }
                if (-not [string]::IsNullOrWhiteSpace($currentNodePort)) {
                    Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
                        Where-Object { $_.LocalPort -eq ([int]$currentNodePort) } |
                        ForEach-Object { [void]$pids.Add([int]$_.OwningProcess) }
                }
                $runtimeEndpoints = Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
                    Where-Object { $_.OwningProcess -eq $ProcessId }
                foreach ($endpoint in $runtimeEndpoints) {
                    [void]$pids.Add([int]$endpoint.OwningProcess)
                }
                if ($pids.Count -eq 0) {
                    throw 'no pids available'
                }
                $lines = foreach ($pid in ($pids | Sort-Object)) {
                    "===== PID $pid ====="
                    tasklist /FI "PID eq $pid" /V
                    ""
                }
                $lines -join [Environment]::NewLine
            }
        },
        @{
            Name = 'runtime_netstat_abno_udp.log'
            Title = 'netstat -abno -p udp'
            Command = { netstat -abno -p udp }
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

function Start-PktMonCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath,
        [Parameter(Mandatory = $true)]
        [bool]$Enabled,
        [Parameter(Mandatory = $true)]
        [int]$FileSizeMb
    )

    $state = [ordered]@{
        Enabled = $false
        Path = $script:PktMonPath
        EtlPath = Join-Path $LogDirectory 'pktmon_udp_capture.etl'
        TextPath = Join-Path $LogDirectory 'pktmon_udp_capture.txt'
        PcapngPath = Join-Path $LogDirectory 'pktmon_udp_capture.pcapng'
        CountersPath = Join-Path $LogDirectory 'pktmon_counters.log'
        FilterLogPath = Join-Path $LogDirectory 'pktmon_filters.log'
        Error = ''
    }

    if (-not $Enabled) {
        New-LogSection -Path $SummaryPath -Title 'pktmon.disabled' -Content 'EnablePktMon=false'
        return [PSCustomObject]$state
    }

    if ([string]::IsNullOrWhiteSpace($script:PktMonPath)) {
        $state.Error = 'pktmon not found'
        New-LogSection -Path $SummaryPath -Title 'pktmon.unavailable' -Content $state.Error
        return [PSCustomObject]$state
    }

    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if (-not [string]::IsNullOrWhiteSpace($script:MountServiceExePath) -and (Test-Path -LiteralPath $script:MountServiceExePath)) {
            try {
                $helperArgs = @('--pktmon-start', '--log-dir', $LogDirectory, '--file-size-mb', [string]$FileSizeMb)
                $process = Start-Process -FilePath $script:MountServiceExePath -ArgumentList $helperArgs -Verb RunAs -Wait -PassThru -WindowStyle Hidden
                if ($process.ExitCode -eq 0) {
                    $state.Enabled = $true
                    New-LogSection -Path $SummaryPath -Title 'pktmon.started_via_helper' -Content @"
helper=$script:MountServiceExePath
logDirectory=$LogDirectory
fileSizeMb=$FileSizeMb
"@
                    return [PSCustomObject]$state
                }
                $state.Error = "helper_start_failed exit=$($process.ExitCode)"
                New-LogSection -Path $SummaryPath -Title 'pktmon.start_failed' -Content $state.Error
                return [PSCustomObject]$state
            } catch {
                $state.Error = "helper_start_exception: $($_.Exception.Message)"
                New-LogSection -Path $SummaryPath -Title 'pktmon.start_failed' -Content $state.Error
                return [PSCustomObject]$state
            }
        }
    }

    try {
        & $script:PktMonPath filter remove *> $null
        & $script:PktMonPath filter add libzt_udp -t UDP *> $null
        $filterList = (& $script:PktMonPath filter list 2>&1 | Out-String -Width 4096).TrimEnd()
        New-LogSection -Path $state.FilterLogPath -Title 'pktmon filter list' -Content $filterList
        & $script:PktMonPath start --capture --pkt-size 0 --file-name $state.EtlPath --file-size $FileSizeMb *> $null
        $state.Enabled = $true
        New-LogSection -Path $SummaryPath -Title 'pktmon.started' -Content @"
path=$($state.Path)
etlPath=$($state.EtlPath)
textPath=$($state.TextPath)
pcapngPath=$($state.PcapngPath)
fileSizeMb=$FileSizeMb
"@
    } catch {
        $state.Error = $_.Exception.Message
        New-LogSection -Path $SummaryPath -Title 'pktmon.start_failed' -Content $state.Error
    }

    return [PSCustomObject]$state
}

function Append-PktMonCounters {
    param(
        [Parameter(Mandatory = $true)]
        $State,
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath
    )

    if (-not $State.Enabled) {
        return
    }

    $isAdministrator = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ((-not $isAdministrator) -and (-not [string]::IsNullOrWhiteSpace($script:MountServiceExePath)) -and (Test-Path -LiteralPath $script:MountServiceExePath)) {
        return
    }

    try {
        $output = (& $State.Path counters --json 2>&1 | Out-String -Width 4096).TrimEnd()
        if (-not [string]::IsNullOrWhiteSpace($output)) {
            New-LogSection -Path $State.CountersPath -Title 'pktmon counters --json' -Content $output
        }
    } catch {
        New-LogSection -Path $SummaryPath -Title 'pktmon.counters_failed' -Content $_.Exception.Message
    }
}

function Stop-PktMonCapture {
    param(
        [Parameter(Mandatory = $true)]
        $State,
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath
    )

    if (-not $State.Enabled) {
        return
    }

    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if (-not [string]::IsNullOrWhiteSpace($script:MountServiceExePath) -and (Test-Path -LiteralPath $script:MountServiceExePath)) {
            try {
                $helperArgs = @('--pktmon-stop', '--log-dir', (Split-Path -Parent $State.EtlPath))
                $process = Start-Process -FilePath $script:MountServiceExePath -ArgumentList $helperArgs -Verb RunAs -Wait -PassThru -WindowStyle Hidden
                New-LogSection -Path $SummaryPath -Title 'pktmon.stopped_via_helper' -Content "helper=$script:MountServiceExePath exit=$($process.ExitCode)"
                return
            } catch {
                New-LogSection -Path $SummaryPath -Title 'pktmon.stop_failed' -Content ("helper_stop_exception: " + $_.Exception.Message)
                return
            }
        }
    }

    try {
        $stopOutput = (& $State.Path stop 2>&1 | Out-String -Width 4096).TrimEnd()
        New-LogSection -Path $SummaryPath -Title 'pktmon.stopped' -Content $stopOutput
    } catch {
        New-LogSection -Path $SummaryPath -Title 'pktmon.stop_failed' -Content $_.Exception.Message
    }

    foreach ($conversion in @(
        @{
            Title = 'pktmon.etl2txt'
            Target = $State.TextPath
            Script = { & $State.Path etl2txt $State.EtlPath --out $State.TextPath --timestamp --verbose }
        },
        @{
            Title = 'pktmon.etl2pcap'
            Target = $State.PcapngPath
            Script = { & $State.Path etl2pcap $State.EtlPath --out $State.PcapngPath }
        }
    )) {
        try {
            $conversionOutput = (& $conversion.Script 2>&1 | Out-String -Width 4096).TrimEnd()
            New-LogSection -Path $SummaryPath -Title $conversion.Title -Content @"
target=$($conversion.Target)
output=$conversionOutput
"@
        } catch {
            New-LogSection -Path $SummaryPath -Title ($conversion.Title + '.failed') -Content $_.Exception.Message
        }
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
$script:PktMonPath = Resolve-PktMonPath
$script:MountServiceExePath = Resolve-MountServiceExePath -RepoRoot $repoRoot -Configuration $Configuration

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
pktMonPath=$script:PktMonPath
mountServiceExePath=$script:MountServiceExePath
enablePktMon=$EnablePktMon
pktMonFileSizeMb=$PktMonFileSizeMb
"@

$pktmonState = Start-PktMonCapture -LogDirectory $logDirectory -SummaryPath $summaryPath -Enabled $EnablePktMon -FileSizeMb $PktMonFileSizeMb

Push-Location $runnerDirectory
try {
    $process = Start-Process -FilePath $smokeExe `
        -ArgumentList $arguments `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru `
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

Append-Snapshot -LogDirectory $logDirectory -ProcessId $process.Id -ProcessPath $smokeExe -StderrPath $stderrPath
Append-PktMonCounters -State $pktmonState -SummaryPath $summaryPath

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

    Append-Snapshot -LogDirectory $logDirectory -ProcessId $process.Id -ProcessPath $smokeExe -StderrPath $stderrPath
    Append-PktMonCounters -State $pktmonState -SummaryPath $summaryPath
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

Append-Snapshot -LogDirectory $logDirectory -ProcessId $process.Id -ProcessPath $smokeExe -StderrPath $stderrPath
Append-PktMonCounters -State $pktmonState -SummaryPath $summaryPath
Stop-PktMonCapture -State $pktmonState -SummaryPath $summaryPath

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
