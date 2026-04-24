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
    [switch]$EnableNetshTrace = $true,
    [int]$PktMonFileSizeMb = 128,
    [switch]$AnalyzeOnly,
    [string]$LogDirectory = ""
)

$ErrorActionPreference = 'Stop'
$script:PktMonPath = $null
$script:MountServiceExePath = $null

function Test-IsProcessElevated {
    return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
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

function Sync-LibztRuntimeArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath
    )

    $sourceDir = Join-Path $RepoRoot "build\windows\x64\third_party\libzt\lib\$Configuration"
    $targetDir = Join-Path $RepoRoot "build\windows\x64\runner\$Configuration"
    $files = @('zt-shared.dll', 'zt-shared.lib', 'zt-shared.exp')

    foreach ($name in $files) {
        $source = Join-Path $sourceDir $name
        $target = Join-Path $targetDir $name
        if (-not (Test-Path -LiteralPath $source)) {
            continue
        }

        $shouldCopy = $true
        if (Test-Path -LiteralPath $target) {
            $sourceItem = Get-Item -LiteralPath $source
            $targetItem = Get-Item -LiteralPath $target
            $shouldCopy = ($sourceItem.Length -ne $targetItem.Length) -or ($sourceItem.LastWriteTimeUtc -gt $targetItem.LastWriteTimeUtc)
        }

        if ($shouldCopy) {
            Copy-Item -LiteralPath $source -Destination $target -Force
            $copied = Get-Item -LiteralPath $target
            New-LogSection -Path $SummaryPath -Title 'runtime_artifact_synced' -Content "name=$name`nsource=$source`ntarget=$target`nlastWriteTime=$($copied.LastWriteTimeUtc.ToString('o'))`nlength=$($copied.Length)"
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

    $lines = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
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

function Start-PktMonCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath,
        [bool]$Enabled,
        [int]$FileSizeMb
    )

    $state = [ordered]@{
        Enabled = $false
        Path = $script:PktMonPath
        EtlPath = Join-Path $LogDirectory 'pktmon_udp_capture.etl'
        TextPath = Join-Path $LogDirectory 'pktmon_udp_capture.txt'
        PcapngPath = Join-Path $LogDirectory 'pktmon_udp_capture.pcapng'
        FilterLogPath = Join-Path $LogDirectory 'pktmon_filters.log'
        Error = ''
    }

    if (-not $Enabled) {
        New-LogSection -Path $SummaryPath -Title 'pktmon.disabled' -Content 'EnablePktMon=false'
        return [pscustomobject]$state
    }

    if ([string]::IsNullOrWhiteSpace($script:PktMonPath)) {
        $state.Error = 'pktmon not found'
        New-LogSection -Path $SummaryPath -Title 'pktmon.unavailable' -Content $state.Error
        return [pscustomobject]$state
    }

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
                return [pscustomobject]$state
            }
            $state.Error = "helper_start_failed exit=$($process.ExitCode)"
            New-LogSection -Path $SummaryPath -Title 'pktmon.start_failed' -Content $state.Error
            return [pscustomobject]$state
        } catch {
            $state.Error = "helper_start_exception: $($_.Exception.Message)"
            New-LogSection -Path $SummaryPath -Title 'pktmon.start_failed' -Content $state.Error
            return [pscustomobject]$state
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

    return [pscustomobject]$state
}

function Stop-PktMonCapture {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$State,
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath
    )

    if (-not $State.Enabled) {
        return
    }

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

    try {
        $stopOutput = (& $State.Path stop 2>&1 | Out-String -Width 4096).TrimEnd()
        New-LogSection -Path $SummaryPath -Title 'pktmon.stopped' -Content $stopOutput
    } catch {
        New-LogSection -Path $SummaryPath -Title 'pktmon.stop_failed' -Content $_.Exception.Message
    }

    try {
        $txtOutput = (& $State.Path etl2txt $State.EtlPath --out $State.TextPath --timestamp --verbose 2>&1 | Out-String -Width 4096).TrimEnd()
        New-LogSection -Path $SummaryPath -Title 'pktmon.etl2txt' -Content $txtOutput
    } catch {
        New-LogSection -Path $SummaryPath -Title 'pktmon.etl2txt_failed' -Content $_.Exception.Message
    }

    try {
        $pcapOutput = (& $State.Path etl2pcap $State.EtlPath --out $State.PcapngPath 2>&1 | Out-String -Width 4096).TrimEnd()
        New-LogSection -Path $SummaryPath -Title 'pktmon.etl2pcap' -Content $pcapOutput
    } catch {
        New-LogSection -Path $SummaryPath -Title 'pktmon.etl2pcap_failed' -Content $_.Exception.Message
    }
}

function Start-NetshTraceCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath,
        [bool]$Enabled
    )

    $state = [ordered]@{
        Enabled = $false
        EtlPath = Join-Path $LogDirectory 'winsock_nettrace.etl'
        Error = ''
    }

    if (-not $Enabled) {
        New-LogSection -Path $SummaryPath -Title 'netsh_trace.disabled' -Content 'EnableNetshTrace=false'
        return [pscustomobject]$state
    }

    if (-not (Test-IsProcessElevated)) {
        $state.Error = 'netsh trace requires elevation; skipped to avoid hanging the main diagnosis flow'
        New-LogSection -Path $SummaryPath -Title 'netsh_trace.skipped' -Content $state.Error
        return [pscustomobject]$state
    }

    try {
        netsh trace stop | Out-Null
    } catch {
    }

    try {
        $output = Invoke-SafeCommand {
            netsh trace start capture=no report=no persistent=no correlation=no tracefile=$($state.EtlPath) scenario=NetConnection level=7
        }
        $state.Enabled = $true
        New-LogSection -Path $SummaryPath -Title 'netsh_trace.started' -Content $output
    } catch {
        $state.Error = $_.Exception.Message
        New-LogSection -Path $SummaryPath -Title 'netsh_trace.start_failed' -Content $state.Error
    }

    return [pscustomobject]$state
}

function Stop-NetshTraceCapture {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$State,
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath
    )

    if (-not $State.Enabled) {
        return
    }

    try {
        $output = Invoke-SafeCommand { netsh trace stop }
        New-LogSection -Path $SummaryPath -Title 'netsh_trace.stopped' -Content $output
    } catch {
        New-LogSection -Path $SummaryPath -Title 'netsh_trace.stop_failed' -Content $_.Exception.Message
    }
}

function Get-LibztPortsFromText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Lines
    )

    $ports = New-Object System.Collections.Generic.HashSet[int]
    foreach ($line in $Lines) {
        if ($line -match 'expected_port=(\d+)') {
            [void]$ports.Add([int]$matches[1])
        }
        foreach ($m in [regex]::Matches($line, 'udp_endpoints=[^ ]*')) {
            foreach ($pm in [regex]::Matches($m.Value, ':(\d+)')) {
                [void]$ports.Add([int]$pm.Groups[1].Value)
            }
        }
        foreach ($pm in [regex]::Matches($line, '\bport=(\d+)\b')) {
            [void]$ports.Add([int]$pm.Groups[1].Value)
        }
    }
    return @($ports | Sort-Object)
}

function Get-LayeredUdpDiagnosis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory
    )

    $stderrPath = Join-Path $LogDirectory 'libzt_monitor_stderr.log'
    $summaryPath = Join-Path $LogDirectory 'layered_udp_diagnosis.log'
    $pktmonTextPath = Join-Path $LogDirectory 'pktmon_udp_capture.txt'
    $sessionSummaryPath = Join-Path $LogDirectory 'session_summary.log'

    $stderrLines = @()
    if (Test-Path -LiteralPath $stderrPath) {
        $stderrLines = Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue
    }

    $ports = Get-LibztPortsFromText -Lines $stderrLines
    $portsPattern = if ($ports.Count -gt 0) { ($ports | ForEach-Object { [regex]::Escape([string]$_) }) -join '|' } else { '' }

    $pktmonLines = @()
    if (Test-Path -LiteralPath $pktmonTextPath) {
        $pktmonLines = Get-Content -LiteralPath $pktmonTextPath -ErrorAction SilentlyContinue
    }

    $udpSocketReadyCount = @([regex]::Matches(($stderrLines -join "`n"), 'udp_socket_ready')).Count
    $recvfromOkCount = @([regex]::Matches(($stderrLines -join "`n"), 'recvfrom_result success=1')).Count
    $recvfromErrCount = @([regex]::Matches(($stderrLines -join "`n"), 'recvfrom_result success=0')).Count
    $wirePacketCount = @([regex]::Matches(($stderrLines -join "`n"), 'process_wire_packet')).Count
    $nodeOfflineCount = @([regex]::Matches(($stderrLines -join "`n"), 'node_offline')).Count

    $pktmonInboundCount = 0
    $pktmonDropCount = 0
    $pktmonOutboundCount = 0
    if ($pktmonLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($portsPattern)) {
        $pktmonInboundCount = @([regex]::Matches(($pktmonLines -join "`n"), "(?m)^\s*\S+\s+>\s+\S+\.($portsPattern):\s+UDP")).Count
        $pktmonOutboundCount = @([regex]::Matches(($pktmonLines -join "`n"), "(?m)^\s*\S+\.($portsPattern)\s+>\s+\S+:\s+UDP")).Count
        $pktmonDropCount = @([regex]::Matches(($pktmonLines -join "`n"), "(transport endpoint was not found|Port unreachable|session state error)")).Count
    }

    $inference = ''
    if (($pktmonOutboundCount -gt 0) -and (($pktmonInboundCount -gt 0) -or ($pktmonDropCount -gt 0)) -and ($udpSocketReadyCount -eq 0)) {
        $inference = 'lost_between_windows_transport_and_socket_queue'
    } elseif (($udpSocketReadyCount -gt 0) -and ($recvfromOkCount -eq 0) -and ($recvfromErrCount -gt 0)) {
        $inference = 'socket_became_readable_but_recvfrom_failed'
    } elseif (($recvfromOkCount -gt 0) -and ($wirePacketCount -eq 0)) {
        $inference = 'received_by_phy_but_not_delivered_to_libzt_core'
    } elseif (($wirePacketCount -gt 0) -and ($nodeOfflineCount -gt 0)) {
        $inference = 'received_by_libzt_core_but_transport_state_still_went_offline'
    } elseif (($pktmonOutboundCount -gt 0) -and ($pktmonInboundCount -eq 0) -and ($pktmonDropCount -eq 0)) {
        $inference = 'no_observed_return_traffic_to_host_stack'
    } else {
        $inference = 'insufficient_signal_or_mixed_signals'
    }

    $report = @"
logDirectory=$LogDirectory
stderrPath=$stderrPath
pktmonTextPath=$pktmonTextPath
sessionSummaryPath=$sessionSummaryPath
ports=$($ports -join ',')
udp_socket_ready_count=$udpSocketReadyCount
recvfrom_success_count=$recvfromOkCount
recvfrom_error_count=$recvfromErrCount
process_wire_packet_count=$wirePacketCount
node_offline_count=$nodeOfflineCount
pktmon_outbound_count=$pktmonOutboundCount
pktmon_inbound_count=$pktmonInboundCount
pktmon_drop_count=$pktmonDropCount
inference=$inference
"@

    if (Test-Path -LiteralPath $summaryPath) {
        Remove-Item -LiteralPath $summaryPath -Force
    }
    New-LogSection -Path $summaryPath -Title 'layered_udp_diagnosis' -Content $report

    if (Test-Path -LiteralPath $stderrPath) {
        $keyHits = Select-String -LiteralPath $stderrPath -Pattern 'udp_connreset_result|udp_bind_result|udp_socket_ready|recvfrom_result|process_wire_packet|node_offline|node_online' -ErrorAction SilentlyContinue |
            Select-Object -First 200 |
            ForEach-Object { $_.Line }
        if ($keyHits) {
            New-LogSection -Path $summaryPath -Title 'stderr.key_hits' -Content (($keyHits -join "`r`n"))
        }
    }

    if ((Test-Path -LiteralPath $pktmonTextPath) -and (-not [string]::IsNullOrWhiteSpace($portsPattern))) {
        $pktmonPatterns = $ports | ForEach-Object { '\.{0}(:| )' -f $_ }
        $pktmonHits = Select-String -LiteralPath $pktmonTextPath -Pattern $pktmonPatterns -ErrorAction SilentlyContinue |
            Select-Object -First 200 |
            ForEach-Object { $_.Line }
        if ($pktmonHits) {
            New-LogSection -Path $summaryPath -Title 'pktmon.key_hits' -Content (($pktmonHits -join "`r`n"))
        }
    }

    Write-Host "layeredDiagnosis=$summaryPath"
    Write-Host "inference=$inference"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:PktMonPath = Resolve-PktMonPath
$script:MountServiceExePath = Resolve-MountServiceExePath -RepoRoot $repoRoot -Configuration $Configuration

if ($AnalyzeOnly) {
    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        throw 'AnalyzeOnly requires -LogDirectory.'
    }
    Get-LayeredUdpDiagnosis -LogDirectory $LogDirectory
    exit 0
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runLogDirectory = Join-Path $repoRoot "logs\libzt-udp-layers\$timestamp"
New-Item -ItemType Directory -Path $runLogDirectory -Force | Out-Null

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

$stdoutPath = Join-Path $runLogDirectory 'libzt_monitor_stdout.log'
$stderrPath = Join-Path $runLogDirectory 'libzt_monitor_stderr.log'
$summaryPath = Join-Path $runLogDirectory 'session_summary.log'

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
logDirectory=$runLogDirectory
smokeExe=$smokeExe
arguments=$($arguments -join ' ')
configuration=$Configuration
joinNetwork=$JoinNetwork
networkId=$NetworkId
pollIntervalSeconds=$PollIntervalSeconds
maxMonitorMinutes=$MaxMonitorMinutes
enablePktMon=$EnablePktMon
enableNetshTrace=$EnableNetshTrace
pktMonPath=$script:PktMonPath
mountServiceExePath=$script:MountServiceExePath
"@

Sync-LibztRuntimeArtifacts -RepoRoot $repoRoot -Configuration $Configuration -SummaryPath $summaryPath

$pktmonState = Start-PktMonCapture -LogDirectory $runLogDirectory -SummaryPath $summaryPath -Enabled $EnablePktMon -FileSizeMb $PktMonFileSizeMb
$netshState = Start-NetshTraceCapture -LogDirectory $runLogDirectory -SummaryPath $summaryPath -Enabled $EnableNetshTrace

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

Write-Host "logDirectory=$runLogDirectory"
Write-Host "started libzt monitor pid=$($process.Id)"

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

Stop-PktMonCapture -State $pktmonState -SummaryPath $summaryPath
Stop-NetshTraceCapture -State $netshState -SummaryPath $summaryPath

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

Get-LayeredUdpDiagnosis -LogDirectory $runLogDirectory

Write-Host "stdout=$stdoutPath"
Write-Host "stderr=$stderrPath"
