<#
    Supervises the watchdog and passive telemetry processes themselves.
    It never touches the Tobii device, services, gaze stream, or PC power state.
#>
[CmdletBinding()]
param(
    [int]$StaleSec = 180,
    [int]$RecoveryLeaseSec = 600,
    [string]$WatchdogHeartbeat = 'C:\Scripts\tobii-watchdog.heartbeat.json',
    [string]$MonitorHeartbeat = 'C:\Scripts\tobii-monitor.heartbeat.json',
    [string]$RecoveryState = 'C:\Scripts\tobii-recovery-state.json',
    [string]$LogPath = 'C:\Scripts\Tobii-Sentinel.log'
)

function Write-SentinelLog([string]$Message) {
    try { Add-Content -LiteralPath $LogPath -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Message) } catch {}
}
function Get-HeartbeatAge([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [double]::PositiveInfinity }
    try { return ((Get-Date) - (Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTime).TotalSeconds }
    catch { return [double]::PositiveInfinity }
}
function Test-RecoveryLeaseFresh {
    if (-not (Test-Path -LiteralPath $RecoveryState)) { return $false }
    try { return (((Get-Date) - (Get-Item -LiteralPath $RecoveryState).LastWriteTime).TotalSeconds -lt $RecoveryLeaseSec) }
    catch { return $false }
}
function Restart-TaskIfStale([string]$TaskName, [string]$Heartbeat, [switch]$HonorRecoveryLease) {
    $age = Get-HeartbeatAge $Heartbeat
    if ($age -le $StaleSec) { return }
    if ($HonorRecoveryLease -and (Test-RecoveryLeaseFresh)) {
        Write-SentinelLog "$TaskName heartbeat stale, but a fresh recovery lease exists; leaving it alone."
        return
    }
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $ageText = if ([double]::IsPositiveInfinity($age)) { 'missing' } else { "$([int]$age)s" }
        Write-SentinelLog "Restarted $TaskName (heartbeat age: $ageText)."
    } catch {
        Write-SentinelLog "Could not restart ${TaskName}: $($_.Exception.Message)"
    }
}

Restart-TaskIfStale -TaskName 'TobiiWatchdog' -Heartbeat $WatchdogHeartbeat -HonorRecoveryLease
Restart-TaskIfStale -TaskName 'TobiiMonitor' -Heartbeat $MonitorHeartbeat
