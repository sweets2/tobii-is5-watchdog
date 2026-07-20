<#
    Tobii-Watchdog.ps1  (passive log-state edition)
    -----------------------------------------------
    Keeps the Alienware/Tobii IS5 eye tracker alive WITHOUT ever touching the
    gaze stream. It only READS the EyeX engine's ServerLog.txt to see the state
    machine; when the engine drops to a non-tracking state (WaitingForDevice,
    etc.) and stays there past a threshold, it forces a clean reconnect.

    IMPORTANT: this watchdog never subscribes to gaze. A second gaze subscriber
    breaks this hardware (it resets every ~2-3s). Passive log reading is the only
    safe approach. Silent stalls are inferred passively from the engine's learned
    CPU baseline; the script never opens a second stream.

    STACK-PRESENCE CHECK: the log state alone can be a lie. After a crash or a
    cold boot (e.g. battery died in sleep) the last ServerLog line still says
    'Tracking' from the PREVIOUS session while 'Tobii Service' is stopped and no
    engine process exists. So the state is only trusted while the engine process
    is alive; if the middleware service or engine is missing past the threshold
    (and past a post-boot grace, since 'Tobii Service' is Automatic-Delayed and
    legitimately takes ~2-4 min to start after boot), that is a fault too.

    SILENT-STALL CHECK (Mode B/D): the engine can claim 'Tracking' while doing
    no gaze work at all -- seen live 2026-07-07 after a false recovery: state
    said Tracking but the engine sat at ~0.3% CPU for 22 min (healthy tracking
    with a user in front is ~8-13%) because the device had lost its calibration.
    Detection is still fully passive: state == Tracking AND the console user is
    actively giving input, or the engine recently collapsed from verified healthy
    load while the session remains unlocked, AND CPU stays below its learned
    threshold across multiple samples. Recovery ladder: calibration re-apply ->
    clean stack restart -> one verified port re-enumeration -> classify the
    terminal result as recalibration-needed or manual-sleep-needed.
    Caveat: typing with the tracker blind (lid closed on an external monitor)
    looks identical; the cooldown caps that at one ladder per $StallCooldownMin.

    Recovery escalation (auto): 1 = restart runtime service; 2 = deterministic
    stop/start of middleware, engine, interaction and runtime. Every recovery bounces the interaction
    process once Tracking returns, so the gaze->cursor warp re-binds (restarting the
    runtime service alone breaks that binding = gaze works but the cursor warp is
    dead). If WaitingForDevice persists with the
    tracker HUNG ON USB (descriptor-request-failed / off the bus -- common after a
    hibernate/sleep resume), it re-enumerates the tracker's OWN USB port (safe: only
    its port, and it verifies the device ends ENABLED) -- this recovers a device that
    plain restarts cannot, with NO reboot. If even that cannot bring it back it raises
    a manual-S3-needed flag (tray notification) and stops thrashing. USB recovery is
    limited to one verified re-enumeration per transaction.

    Modes:  -Once  print state & exit   -ForceReconnect  full reconnect & exit
            -OnWake  resume-from-sleep reconnect if not tracking
            -RestartInteraction  bounce Tobii.EyeX.Interaction (fix cursor warp)
#>
[CmdletBinding()]
param(
    [int]$StuckThresholdSec = 20,
    [int]$PollSec          = 5,
    [int]$GraceSec         = 25,
    [int]$BootGraceSec     = 240,
    [string]$LogPath       = 'C:\Scripts\Tobii-Watchdog.log',
    [int]$MaxLogBytes      = 1048576,
    [string]$PauseFlag     = 'C:\Scripts\watchdog.pause',
    [string]$ServerLog     = "",
    [double]$StallCpuPct       = 6.0,
    [double]$HardStallCpuPct   = 1.5,
    [int]$StallIdleMaxSec      = 60,
    [int]$StallCheckEverySec   = 60,
    [int]$QuietStallStrikes    = 3,
    [int]$ClusterWindowMin     = 30,
    [int]$ClusterEscalateCount = 3,
    [int]$StallCooldownMin     = 45,
    [int]$ResumeGapSec         = 90,
    [int]$BurstSec             = 150,
    [int]$BurstStallCheckSec   = 15,
    [string]$RecalFlag         = 'C:\Scripts\tobii-recal-needed.flag',
    [string]$RebootNeededFlag  = 'C:\Scripts\tobii-reboot-needed.flag',
    [string]$RecoveringFlag    = 'C:\Scripts\tobii-recovering.flag',
    [string]$HeartbeatFile     = 'C:\Scripts\tobii-watchdog.heartbeat.json',
    [string]$RecoveryStateFile = 'C:\Scripts\tobii-recovery-state.json',
    [string]$RecoveryRequestFile = 'C:\Scripts\tobii-force-reconnect.request',
    [int]$UsbHangRebootLevel   = 2,
    [switch]$Once,
    [switch]$ForceReconnect,
    [switch]$OnWake,
    [switch]$RestartInteraction
)
$ErrorActionPreference = 'Continue'
# ONLY this state triggers recovery. Everything else -- Tracking, Idle, and all the
# transient/setup states (Initialize, WaitingForConnection, ConnectToEyeTracker,
# PreparingForTracking, Configuring) -- is left ALONE. Critically, calibration puts
# the engine in `Configuring`; treating that as "stuck" once broke a calibration
# mid-run. So we act only on the genuine PRP-drop signature: WaitingForDevice.
$FaultStates   = @('WaitingForDevice')
$HealthyStates = @('Tracking','Idle')   # (kept for -Once display only)
$RecoveryMutexName = 'Global\TobiiRecoveryCoordinator'
$script:RecoveryMutex = $null
$script:RecoveryDepth = 0
$script:RecoveryPhase = 'monitoring'

# Every process that can mutate the Tobii stack (main loop, wake task, tray task,
# manual reconnect) shares this mutex. The old main-loop-only mutex allowed those
# paths to overlap and restart services underneath each other.
function Enter-RecoveryCoordinator {
    param([string]$Reason, [int]$TimeoutSec = 2)
    if ($script:RecoveryDepth -gt 0) {
        $script:RecoveryDepth++
        return $true
    }
    try {
        $m = New-Object System.Threading.Mutex($false, $RecoveryMutexName)
        if (-not $m.WaitOne([TimeSpan]::FromSeconds($TimeoutSec))) {
            $m.Dispose()
            Write-Log "Recovery request '$Reason' coalesced: another recovery is already running." 'WARN'
            return $false
        }
        $script:RecoveryMutex = $m
        $script:RecoveryDepth = 1
        Set-RecoveryPhase -Phase 'starting' -Reason $Reason
        return $true
    } catch {
        Write-Log "Could not acquire recovery coordinator: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}
function Exit-RecoveryCoordinator {
    if ($script:RecoveryDepth -le 0) { return }
    $script:RecoveryDepth--
    if ($script:RecoveryDepth -gt 0) { return }
    try { Remove-Item -LiteralPath $RecoveryStateFile -Force -ErrorAction SilentlyContinue } catch {}
    try { $script:RecoveryMutex.ReleaseMutex() } catch {}
    try { $script:RecoveryMutex.Dispose() } catch {}
    $script:RecoveryMutex = $null
    $script:RecoveryPhase = 'monitoring'
    Update-Heartbeat
}
function Set-RecoveryPhase {
    param([string]$Phase, [string]$Reason = '')
    $script:RecoveryPhase = $Phase
    try {
        [ordered]@{ ts=(Get-Date -Format 'o'); pid=$PID; phase=$Phase; reason=$Reason } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $RecoveryStateFile -Encoding UTF8
    } catch {}
    Update-Heartbeat
}
function Update-Heartbeat {
    try {
        [ordered]@{ ts=(Get-Date -Format 'o'); pid=$PID; phase=$script:RecoveryPhase } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $HeartbeatFile -Encoding UTF8
    } catch {}
}

# Never recover while the Tobii calibration/config UI is open (setup in progress).
function Test-ConfigActive {
    [bool](Get-Process -Name 'Tobii.Configuration' -ErrorAction SilentlyContinue)
}
function Stop-StaleDiagnosticClients {
    # These clients can retain a dead EyeX session after an engine restart. Close
    # them only inside a confirmed full reconnect; normal monitoring never does.
    $clients = @(Get-Process -Name 'Tobii.EyeTracking.Portal.WPF','GazeNative8' -ErrorAction SilentlyContinue)
    if ($clients.Count -gt 0) {
        Write-Log ("Closing stale Tobii diagnostic clients: " + (($clients | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ', '))
        $clients | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# Passive stack-presence check (Get-Service/Get-Process only -- never the gaze
# stream). Returns a reason string when the middleware service or the engine
# process is missing, else $null. While the engine is missing, the log state is
# stale and must not be trusted.
function Get-StackDownReason {
    $svc = Get-Service -Name 'Tobii Service' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        return "'Tobii Service' is $($svc.Status)"
    }
    if (-not (Get-Process -Name 'Tobii.EyeX.Engine' -ErrorAction SilentlyContinue)) {
        return 'Tobii.EyeX.Engine process not running'
    }
    return $null
}

# Boot time, fixed for the life of this process (the watchdog starts at logon).
# Used for the post-boot grace: 'Tobii Service' is Automatic (Delayed Start), so
# the stack is legitimately absent for the first minutes after a boot.
$BootTime = $null
try { $BootTime = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
if (-not $BootTime) { $BootTime = (Get-Date).AddDays(-1) }  # unknown -> assume old boot, checks stay active
function Test-InBootGrace {
    ((Get-Date) - $BootTime).TotalSeconds -lt $BootGraceSec
}

# ---- silent-stall detection (passive: process CPU + console idle only) ------
# GetLastInputInfo tells us the console user is actively at the machine; if so,
# the tracker should be seeing eyes and the engine should be burning CPU on
# gaze processing. If Add-Type fails, Get-ConsoleIdleSec returns a huge value
# and stall detection simply stays disabled.
try {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TWLastInput {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint IdleMs() {
        var lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return uint.MaxValue;
        return (uint)Environment.TickCount - lii.dwTime;
    }
}
'@
} catch { }
function Get-ConsoleIdleSec {
    try { return [Math]::Round([TWLastInput]::IdleMs() / 1000) } catch { return 999999 }
}
function Get-EngineCpuPct {
    # Average CPU % of the EyeX engine over a short sample window. Healthy
    # tracking with a user present runs ~8-13%; a stalled/calibration-less
    # engine sits at ~0-0.3%. Returns $null if the engine is absent or
    # restarts mid-sample.
    param([int]$SampleSec = 12)
    $p1 = Get-Process -Name 'Tobii.EyeX.Engine' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p1) { return $null }
    $cpu1 = $p1.CPU
    Start-Sleep -Seconds $SampleSec
    Update-Heartbeat
    $p2 = Get-Process -Id $p1.Id -ErrorAction SilentlyContinue
    if (-not $p2 -or $p2.ProcessName -ne 'Tobii.EyeX.Engine') { return $null }
    return [Math]::Round((($p2.CPU - $cpu1) / $SampleSec) * 100, 1)
}
function Get-DegradedCpuThreshold {
    # Learn this machine's healthy engine load, but keep the decision boundary in
    # a conservative range. The observed frozen 4.1% state must not pass as healthy.
    $baseline = if ($script:HealthyCpuEwma) { $script:HealthyCpuEwma } else { 12.0 }
    return [Math]::Round([Math]::Min($StallCpuPct, [Math]::Max(4.5, $baseline * 0.45)), 1)
}
function Test-SilentStall {
    # Returns 'active' or 'quiet' for a degraded sample, otherwise $null. The
    # quiet path closes the gaze-user catch-22: dead gaze causes input-idle, so
    # conventional input cannot be a mandatory detector gate.
    if (Get-StackDownReason) { return $false }
    if ((Get-TrackerState) -ne 'Tracking') { return $false }
    if ([bool](Get-Process -Name 'LogonUI' -ErrorAction SilentlyContinue)) { return $false }
    $active = ((Get-ConsoleIdleSec) -le $StallIdleMaxSec)
    if (-not $active -and (-not $script:LastVerifiedHealthy -or
        ((Get-Date) - $script:LastVerifiedHealthy).TotalMinutes -gt 10)) {
        return $null
    }
    $cpu = Get-EngineCpuPct -SampleSec 12
    if ($null -eq $cpu) { return $null }
    $script:LastHealthSampleCpu = $cpu
    $threshold = Get-DegradedCpuThreshold
    if ($cpu -ge $threshold) {
        if ($active -and $cpu -ge 8) {
            $baseline = if ($script:HealthyCpuEwma) { $script:HealthyCpuEwma } else { 12.0 }
            $script:HealthyCpuEwma = [Math]::Round((0.8 * $baseline) + (0.2 * $cpu), 1)
            $script:LastVerifiedHealthy = Get-Date
        }
        return $null
    }
    $kind = if ($active) { 'active' } else { 'quiet' }
    $severity = if ($cpu -lt $HardStallCpuPct) { 'dead' } else { 'degraded' }
    Write-Log ("Silent-stall sample: state=Tracking, engine CPU ${cpu}% (<${threshold}%), mode=$kind severity=$severity.") 'WARN'
    # Degradation bookkeeping: single samples (below the 2-consecutive-strikes action
    # threshold) still mark the device as degraded since its last clean re-enumeration.
    # The 07-10 hard wedge was preceded by an HOUR of such samples; they arm the
    # preventive at-lock reconnect (see main loop).
    $script:StallDegradationCount++
    $script:LastStallCpu = $cpu
    return $kind
}
function Get-CalibrationFile {
    Get-ChildItem 'C:\ProgramData\Tobii\Tobii Platform Runtime\*\*\calibration.setpm' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
function Set-RecalNeeded {
    param([string]$Reason)
    if (-not (Test-Path -LiteralPath $RecalFlag)) {
        Write-Log ("Raising recalibration-needed flag: $Reason") 'ERROR'
        try { Set-Content -LiteralPath $RecalFlag -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Reason) } catch { }
    }
}
function Clear-RecalNeeded {
    param([string]$Why = '')
    if (Test-Path -LiteralPath $RecalFlag) {
        Write-Log ("Clearing recalibration-needed flag. $Why")
        try { Remove-Item -LiteralPath $RecalFlag -Force -ErrorAction SilentlyContinue } catch { }
    }
}
function Set-RebootNeeded {
    # Distinct from recal-needed: the tracker fell off the USB bus and even a port
    # re-enumeration could not bring it back = a firmware/hardware wedge that only a
    # owner-initiated S3 power cycle clears. The legacy filename is retained for
    # compatibility, but the UI calls this "manual sleep needed."
    param([string]$Reason)
    if (-not (Test-Path -LiteralPath $RebootNeededFlag)) {
        Write-Log ("Raising MANUAL-SLEEP-needed flag: $Reason") 'ERROR'
        try { Set-Content -LiteralPath $RebootNeededFlag -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Reason) } catch { }
    }
    # Terminal manual-sleep is not active recovery; keep tray/heartbeat truthful.
    Clear-Recovering
}
function Clear-RebootNeeded {
    param([string]$Why = '')
    if (Test-Path -LiteralPath $RebootNeededFlag) {
        Write-Log ("Clearing reboot-needed flag. $Why")
        try { Remove-Item -LiteralPath $RebootNeededFlag -Force -ErrorAction SilentlyContinue } catch { }
    }
}
function Set-Recovering {
    # Visibility flag for the tray: a fault was detected and the recovery ladder is
    # running. The tray shows 'auto-recovering' + a balloon so the user KNOWS the
    # watchdog caught it (an outage with no feedback looks identical to a dead watchdog).
    if (-not (Test-Path -LiteralPath $RecoveringFlag)) {
        try { Set-Content -LiteralPath $RecoveringFlag -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') } catch { }
    }
}
function Clear-Recovering {
    if (Test-Path -LiteralPath $RecoveringFlag) {
        try { Remove-Item -LiteralPath $RecoveringFlag -Force -ErrorAction SilentlyContinue } catch { }
    }
}
function Invoke-CalReapply {
    # Mode-D primary fix: re-push the tracker's STORED calibration blob to the live
    # engine (Tobii-CalReapply.exe, safe engine-IPC path -- NEVER a gaze stream).
    # After a hibernate-resume the engine is 'Tracking' but no calibration is bound
    # to the device (0% CPU, IR LEDs dark); re-applying the stored calibration.setpm
    # rebinds it in ~1s with no restart and no recalibration dots. Returns $true if
    # the push reported ResultCode Ok (exit 0).
    $exe = 'C:\Scripts\Tobii-CalReapply.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Log 'Tobii-CalReapply.exe not present; cannot re-apply calibration.' 'WARN'
        return $false
    }
    Write-Log 'Re-applying stored calibration to the live device (no restart, no dots)...'
    try {
        $out = & $exe 2>&1
        $code = $LASTEXITCODE
        foreach ($l in $out) { Write-Log ("  calreapply: $l") }
        Write-Log ("Calibration re-apply " + $(if ($code -eq 0) { 'reported Ok.' } else { "failed (exit $code)." }))
        return ($code -eq 0)
    } catch {
        Write-Log ("Calibration re-apply error: " + $_.Exception.Message) 'ERROR'
        return $false
    }
}
function Test-GazeWorking {
    # Verify real gaze work resumed (engine CPU at tracking level while the user is
    # present). It does NOT require a fresh 'Tracking' line -- a bare re-apply
    # produces no state transition (the engine was already
    # 'Tracking'); it just starts doing gaze work again.
    if (Get-StackDownReason) { return 'unhealthy' }
    Start-Sleep -Seconds 4
    $sawActiveUser = $false
    for ($i = 0; $i -lt 4; $i++) {
        if ((Get-ConsoleIdleSec) -le $StallIdleMaxSec) {
            $sawActiveUser = $true
            $cpu = Get-EngineCpuPct -SampleSec 10
            if ($null -ne $cpu) {
                Write-Log ("Gaze-recovery verify: engine CPU ${cpu}%.")
                return $(if ($cpu -ge (Get-DegradedCpuThreshold)) { 'healthy' } else { 'unhealthy' })
            }
        }
        Start-Sleep -Seconds 8
    }
    if ($sawActiveUser) { return 'unhealthy' }
    Write-Log 'Gaze-recovery verify: user idle; result remains unverified.' 'WARN'
    return 'unknown'
}
function Invoke-StallRecovery {
    # Ladder for the 'Tracking-but-dead' stall (Mode B/D). Order changed now that we
    # can re-bind calibration directly: try the cheap, non-disruptive calibration
    # re-apply FIRST, and again after each disruptive step (a restart brings the
    # engine back up uncalibrated -- the same Mode-D state -- so it must be followed
    # by a re-apply). Each step is verified by actual engine CPU, not the state line.
    # -IgnoreCooldown: a fresh wake/boot is a legitimate event (not restart-thrashing),
    # so the anti-thrash cooldown is skipped for the first post-transition recovery.
    param([switch]$IgnoreCooldown)
    if (-not (Enter-RecoveryCoordinator -Reason 'silent-stall')) { return }
    try {
    $inCooldown = (-not $IgnoreCooldown) -and $script:LastStallRecovery -and (((Get-Date) - $script:LastStallRecovery).TotalMinutes -lt $StallCooldownMin)
    if ($inCooldown) {
        # Inside the restart cooldown (anti-thrash). A calibration re-apply is free
        # (no restart) -- try it first.
        Write-Log 'Silent stall within restart cooldown; trying calibration re-apply first.' 'WARN'
        Set-RecoveryPhase -Phase 'calibration-reapply' -Reason 'cooldown stall'
        if (Invoke-CalReapply) {
            # Calibration can restore engine work while the existing interaction
            # process remains bound to the dead pre-recovery PTP session.
            Restart-InteractionProcess
            $verify = Test-GazeWorking
            if ($verify -eq 'healthy') {
                Write-Log 'Stall cleared by calibration re-apply (cooldown path).'
                Clear-RecalNeeded 'calibration re-applied'
                return
            } elseif ($verify -eq 'unknown') {
                Write-Log 'Calibration re-apply completed; recovery pending user-present verification.' 'WARN'
                return
            }
        }
        # Re-apply was not enough. Allow ONE reconnect per cooldown window before
        # giving up -- a fresh re-stall (e.g. a second hibernate wake soon after the
        # first) can need the imaging session rebuilt, and flagging for recalibration
        # without trying that is premature.
        if (-not $script:CooldownReconnectDone) {
            $script:CooldownReconnectDone = $true
            Write-Log 'Re-apply insufficient in cooldown; one reconnect before flagging.' 'WARN'
            if (Invoke-Recovery -Level 2) { Invoke-CalReapply | Out-Null }
            $verify = Test-GazeWorking
            if ($verify -eq 'healthy') {
                Write-Log 'Stall cleared by cooldown reconnect + re-apply.'
                Clear-RecalNeeded 'engine tracking again'
                return
            } elseif ($verify -eq 'unknown') {
                Write-Log 'Cooldown reconnect completed; recovery pending user-present verification.' 'WARN'
                return
            }
        }
        Set-RebootNeeded 'tracker remains electrically present but its imaging session stayed degraded; manual sleep/wake required'
        return
    }
    $script:LastStallRecovery = Get-Date
    $script:CooldownReconnectDone = $false
    Set-Recovering
    Write-Log 'SILENT STALL confirmed: engine claims Tracking at idle CPU while user is active. Starting recovery.' 'ERROR'

    # Step 0 -- primary Mode-D fix: re-apply stored calibration (fast, no restart).
    Set-RecoveryPhase -Phase 'calibration-reapply' -Reason 'silent stall'
    $calOk = Invoke-CalReapply
    if ($calOk) {
        # Treat calibration-only recovery like every other successful level:
        # rebind cursor control before declaring the tracker healthy.
        Restart-InteractionProcess
        $verify = Test-GazeWorking
        if ($verify -eq 'healthy') {
            Write-Log 'Stall cleared by calibration re-apply (no restart needed).'
            Clear-RecalNeeded 'calibration re-applied'
            return
        } elseif ($verify -eq 'unknown') {
            Write-Log 'Calibration re-apply completed; recovery pending user-present verification.' 'WARN'
            return
        }
    }

    # Step 1 -- stack restart, wait for a fresh Tracking, then re-apply calibration.
    Write-Log 'Re-apply alone did not clear it; escalating to stack restart.' 'WARN'
    if (Invoke-Recovery -Level 2) { $calOk = (Invoke-CalReapply) -or $calOk }
    $verify = Test-GazeWorking
    if ($verify -eq 'healthy') {
        Write-Log 'Stall cleared by stack restart + calibration re-apply.'
        Clear-RecalNeeded 'engine tracking again'
        return
    } elseif ($verify -eq 'unknown') {
        Write-Log 'Stack restart completed; recovery pending user-present verification.' 'WARN'
        return
    }

    # Step 2 -- one port re-enumeration + clean stack restart, then calibration.
    Write-Log 'Stall survived stack restart; escalating to full reconnect.' 'WARN'
    if (Invoke-FullReconnect) { $calOk = (Invoke-CalReapply) -or $calOk }
    $verify = Test-GazeWorking
    if ($verify -eq 'healthy') {
        Write-Log 'Stall cleared by full reconnect + calibration re-apply.'
        Clear-RecalNeeded 'engine tracking again'
        return
    } elseif ($verify -eq 'unknown') {
        Write-Log 'Full reconnect completed; recovery pending user-present verification.' 'WARN'
        return
    }

    # A successful calibration push followed by persistently dead imaging is not a
    # calibration problem. The observed 4-5% half-alive state needs a rail reset.
    if ($calOk) {
        Write-Log 'Stall survived the software ladder despite successful calibration; manual sleep/wake required.' 'ERROR'
        Set-RebootNeeded 'software ladder exhausted while calibration was accepted; manual sleep/wake required'
    } else {
        Write-Log 'Calibration could not be applied after the recovery ladder.' 'ERROR'
        Set-RecalNeeded 'no usable stored calibration could be applied'
    }
    } finally {
        Clear-Recovering
        Exit-RecoveryCoordinator
    }
}

# ---- logging ---------------------------------------------------------------
function Rotate-Log {
    try {
        if (Test-Path -LiteralPath $LogPath) {
            $item = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
            if ($item -and $item.Length -ge $MaxLogBytes) {
                $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
                $archive = Join-Path (Split-Path $LogPath -Parent) `
                           (([IO.Path]::GetFileNameWithoutExtension($LogPath)) + "-$stamp.log")
                Move-Item -LiteralPath $LogPath -Destination $archive -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    try {
        $dir = Split-Path $LogPath -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $LogPath -Value $line -ErrorAction SilentlyContinue
    } catch { }
    Write-Host $line
}

# ---- read engine state from the log (passive; never touches the device) ----
function Get-ServerLogPath {
    if ($ServerLog) { return $ServerLog }
    $mine = Join-Path $env:LOCALAPPDATA 'Tobii\Tobii Interaction\ServerLog.txt'
    if (Test-Path $mine) { return $mine }
    $c = Get-ChildItem 'C:\Users\*\AppData\Local\Tobii\Tobii Interaction\ServerLog.txt' -EA SilentlyContinue |
         Sort-Object LastWriteTime -Descending
    if ($c) { return $c[0].FullName }
    return $null
}
function Get-TrackerState {
    $path = Get-ServerLogPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $m = Select-String -LiteralPath $path -Pattern 'Now in state (\w+)' -EA Stop | Select-Object -Last 1
            if ($m) { return $m.Matches[0].Groups[1].Value }
            return $null
        } catch { Start-Sleep -Milliseconds 300 }
    }
    return $null
}
function Get-TrackerStateStamped {
    # Like Get-TrackerState, but also returns WHEN that state line was written
    # (parsed from the log-header line above it), so callers can reject a stale
    # 'Tracking' left over from before a restart.
    $path = Get-ServerLogPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $m = Select-String -LiteralPath $path -Pattern 'Now in state (\w+)' -Context 1,0 -EA Stop |
             Select-Object -Last 1
        if (-not $m) { return $null }
        $ts = $null
        $hdr = $m.Context.PreContext[0]
        if ($hdr -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
            $ts = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
        }
        return [PSCustomObject]@{ State = $m.Matches[0].Groups[1].Value; Time = $ts }
    } catch { return $null }
}

# ---- recovery actions ------------------------------------------------------
function Get-RuntimeServices {
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^TobiiIS' -or $_.DisplayName -eq 'Tobii Runtime Service' }
}
function Restart-RuntimeService {
    foreach ($s in Get-RuntimeServices) {
        try { Write-Log "Restarting runtime service '$($s.Name)'..."
              Restart-Service -Name $s.Name -Force -ErrorAction Stop
              Write-Log "Restarted '$($s.Name)'." }
        catch { Write-Log "Failed to restart '$($s.Name)': $($_.Exception.Message)" 'ERROR' }
    }
}
function Restart-EyeXEngine {
    $p = Get-Process -Name 'Tobii.EyeX.Engine','Tobii.EyeX.Interaction' -ErrorAction SilentlyContinue
    if ($p) {
        Write-Log ("Killing EyeX engine/interaction: " + (($p | ForEach-Object { $_.Id }) -join ','))
        $p | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}
function Restart-InteractionProcess {
    # Mode E fix ("gaze fine, cursor warp dead"): Tobii.EyeX.Interaction can come
    # up with a dead PTP (touchpad-filter) session -- gaze works everywhere, but
    # warp does nothing while the process still logs 'Flush sent', so there is NO
    # log signature to auto-detect. Restarting it against an engine that is
    # already Tracking re-binds the session. Tobii.Service does not respawn a
    # killed interaction process, hence the manual-start fallback.
    $exe = 'C:\Program Files (x86)\Tobii\Tobii EyeX Interaction\Tobii.EyeX.Interaction.exe'
    $p = Get-Process -Name 'Tobii.EyeX.Interaction' -ErrorAction SilentlyContinue
    if ($p) {
        Write-Log ("Restarting Tobii.EyeX.Interaction (pid " + (($p | ForEach-Object { $_.Id }) -join ',') + ") to reset the PTP session.")
        $p | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        if (Get-Process -Name 'Tobii.EyeX.Interaction' -ErrorAction SilentlyContinue) {
            Write-Log 'Tobii.EyeX.Interaction respawned on its own.'
            return
        }
    }
    if (Test-Path -LiteralPath $exe) {
        Write-Log 'No auto-respawn after 10s; starting Tobii.EyeX.Interaction directly.'
        Start-Process -FilePath $exe
    } else {
        Write-Log "Interaction exe not found at '$exe'; cannot restart it." 'WARN'
    }
}
function Wait-ForTracking {
    # Waits until the engine reports a FRESH 'Tracking' (state line written after
    # $Since), so a stale pre-restart line can't satisfy it.
    # FAIL-FAST: if the restarted engine parks in a FRESH 'WaitingForDevice' for
    # 15s+ (after a 20s settle), the device is not coming back at this ladder level;
    # sitting out the full timeout only delays escalation (this alone cost ~75s of
    # the 17:24 level-2 outage). Transient WaitingForDevice during engine startup
    # is tolerated by the 15s-continuous requirement.
    param([int]$TimeoutSec = 90, [datetime]$Since = (Get-Date))
    $t0 = Get-Date
    $wfdSince = $null
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        Update-Heartbeat
        if (-not (Get-StackDownReason)) {
            $s = Get-TrackerStateStamped
            if ($s -and $s.Time -and $s.Time -gt $Since) {
                if ($s.State -eq 'Tracking') { return $true }
                if ($s.State -eq 'WaitingForDevice') {
                    if ($null -eq $wfdSince) { $wfdSince = Get-Date }
                    elseif ((((Get-Date) - $wfdSince).TotalSeconds -ge 15) -and (((Get-Date) - $t0).TotalSeconds -ge 20)) {
                        Write-Log 'Engine restarted but parked in WaitingForDevice; failing fast to escalate.' 'WARN'
                        return $false
                    }
                } else { $wfdSince = $null }
            }
        }
        Start-Sleep -Seconds 3
    }
    return $false
}
function Test-TrackerUsbHung {
    # True when the tracker is NOT cleanly on the bus: no VID_2104 node is OK+present.
    # In this state the engine sits in WaitingForDevice forever and service restarts
    # are useless -- the fix is to re-enumerate the tracker's USB port. (A normal PRP
    # drop keeps the device OK/present, so this returns $false there = plain restart.)
    foreach ($t in @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_2104&PID_030C' })) {
        $p = (Get-PnpDeviceProperty -InstanceId $t.InstanceId -KeyName 'DEVPKEY_Device_IsPresent' -ErrorAction SilentlyContinue).Data
        if ($t.Status -eq 'OK' -and $p) { return $false }
    }
    return $true
}
function Get-TrackerUsbState {
    # Tri-state wrapper: never equate a failed PnP query with an absent tracker.
    try {
        $nodes = @(Get-PnpDevice -ErrorAction Stop | Where-Object { $_.InstanceId -match 'VID_2104&PID_030C' })
        foreach ($t in $nodes) {
            $p = (Get-PnpDeviceProperty -InstanceId $t.InstanceId -KeyName 'DEVPKEY_Device_IsPresent' -ErrorAction Stop).Data
            if ($t.Status -eq 'OK' -and $p) { return 'present' }
        }
        if ($nodes.Count -gt 0) { return 'faulted' }
        return 'absent'
    } catch {
        Write-Log "PnP presence query failed: $($_.Exception.Message)" 'WARN'
        return 'unknown'
    }
}
function Get-TrackerPortInfo {
    # Preserve the physical tracker-port identity even when the EyeChip node is
    # stale/not-present. The serial-number instance suffix is not a port locator.
    $ports = @()
    foreach ($t in @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_2104&PID_030C' })) {
        $parent = (Get-PnpDeviceProperty -InstanceId $t.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
        $location = (Get-PnpDeviceProperty -InstanceId $t.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data
        if ($parent -and $location) {
            $ports += [pscustomobject]@{ Parent = "$parent"; Location = "$location" }
        }
    }
    return @($ports | Sort-Object Parent,Location -Unique)
}
function Get-TrackerDescriptorFailedNodes {
    param([object[]]$TrackerPorts = @(Get-TrackerPortInfo))
    if (-not $TrackerPorts -or $TrackerPorts.Count -eq 0) { return @() }
    $resultNodes = @()
    foreach ($d in @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_0000&PID_0002' })) {
        $present = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_IsPresent' -ErrorAction SilentlyContinue).Data
        if (-not $present) { continue }
        $parent = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
        $location = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction SilentlyContinue).Data
        foreach ($port in $TrackerPorts) {
            if ($port.Parent -eq "$parent" -and $port.Location -eq "$location") {
                $resultNodes += $d
                break
            }
        }
    }
    return @($resultNodes | Sort-Object InstanceId -Unique)
}
function Get-TobiiSoftwareDeviceFault {
    # Middleware/HID can disappear while EyeChip itself remains USB-OK. Treat a
    # faulted Tobii Device or missing/faulted tracker HID as authoritative instead
    # of waiting for EyeX's delayed state transition or CPU-stall samples.
    try {
        foreach ($d in @(Get-PnpDevice -FriendlyName 'Tobii Device' -PresentOnly -ErrorAction Stop)) {
            $problem = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
            if ($d.Status -ne 'OK' -or ($null -ne $problem -and [int]$problem -ne 0)) {
                return "Tobii Device status=$($d.Status) code=$(if($null -ne $problem){$problem}else{'unknown'})"
            }
        }
        $trackerHids = @(Get-PnpDevice -FriendlyName 'Tobii Eye Tracker HID' -PresentOnly -ErrorAction Stop)
        foreach ($d in $trackerHids) {
            $problem = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
            if ($d.Status -ne 'OK' -or ($null -ne $problem -and [int]$problem -ne 0)) {
                return "Tobii Eye Tracker HID status=$($d.Status) code=$(if($null -ne $problem){$problem}else{'unknown'})"
            }
        }
        if ($trackerHids.Count -eq 0 -and -not (Test-InBootGrace)) {
            return 'Tobii Eye Tracker HID absent'
        }
    } catch {}
    return $null
}
function Reset-TrackerUsbNode {
    # Bounded two-pass recovery. Restart whichever tracker representation is live,
    # rescan, then restart a descriptor-failed stand-in if that first restart
    # CREATED it. This late transition was observed live on 2026-07-18.
    $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    $trackerNodes = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_2104&PID_030C' })
    $trackerPorts = @(Get-TrackerPortInfo)
    $failed = @(Get-TrackerDescriptorFailedNodes -TrackerPorts $trackerPorts)
    $nodes = if ($failed.Count -gt 0) { @($failed) } else { @($trackerNodes) }
    if (-not $nodes) { Write-Log 'Tracker USB node not found to port-cycle.' 'WARN'; return $false }

    $restartedIds = @()
    foreach ($d in $nodes) {
        Update-Heartbeat
        Write-Log ("Re-enumerating tracker port node ($($d.Status)): $($d.InstanceId)")
        try { & $pnputil /restart-device "$($d.InstanceId)" 2>&1 | Out-Null } catch {}
        $restartedIds += $d.InstanceId
        Start-Sleep -Seconds 3
    }
    try { & $pnputil /scan-devices 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 4

    # EyeChip can turn into Code 43 only after the first restart. Give that newly
    # reachable node exactly one restart, then stop; never loop or touch the hub.
    if ((Get-TrackerUsbState) -ne 'present') {
        $lateFailed = @(Get-TrackerDescriptorFailedNodes -TrackerPorts $trackerPorts | Where-Object { $restartedIds -notcontains $_.InstanceId })
        if ($lateFailed.Count -gt 0) {
            Write-Log 'First USB pass produced a descriptor-failed tracker node; running bounded second pass.' 'WARN'
            foreach ($d in $lateFailed) {
                Update-Heartbeat
                Write-Log ("Restarting late descriptor-failed node: $($d.InstanceId)")
                try { & $pnputil /restart-device "$($d.InstanceId)" 2>&1 | Out-Null } catch {}
                Start-Sleep -Seconds 3
            }
            try { & $pnputil /scan-devices 2>&1 | Out-Null } catch {}
            Start-Sleep -Seconds 5
        }
    }

    $ok = $false
    foreach ($t in @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_2104&PID_030C' })) {
        $present = (Get-PnpDeviceProperty -InstanceId $t.InstanceId -KeyName 'DEVPKEY_Device_IsPresent' -ErrorAction SilentlyContinue).Data
        if ($t.Status -eq 'OK' -and $present) { $ok = $true }
        elseif ($present -and $t.Status -ne 'OK') {
            try { & $pnputil /enable-device "$($t.InstanceId)" 2>&1 | Out-Null } catch {}
            Start-Sleep -Seconds 1
            $now = Get-PnpDevice -InstanceId $t.InstanceId -ErrorAction SilentlyContinue
            $nowPresent = (Get-PnpDeviceProperty -InstanceId $t.InstanceId -KeyName 'DEVPKEY_Device_IsPresent' -ErrorAction SilentlyContinue).Data
            if ($now -and $now.Status -eq 'OK' -and $nowPresent) { $ok = $true }
        }
    }
    Write-Log ("Tracker port re-enumeration: " + $(if ($ok) { 'device back OK/present.' } else { 'device still not enumerating.' }))
    return $ok
}
function Invoke-CleanStackRestart {
    # Deterministic teardown prevents Tobii.Service from respawning the engine in
    # the middle of recovery. Interaction starts only after fresh Tracking.
    Set-RecoveryPhase -Phase 'clean-stack-restart'
    $t0 = Get-Date
    try { Stop-Service -Name 'Tobii Service' -Force -ErrorAction SilentlyContinue } catch {}
    Restart-EyeXEngine
    foreach ($s in Get-RuntimeServices) {
        try { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Seconds 2
    foreach ($s in Get-RuntimeServices) {
        try {
            Write-Log "Starting runtime service '$($s.Name)'..."
            Start-Service -Name $s.Name -ErrorAction Stop
        } catch { Write-Log "Failed to start '$($s.Name)': $($_.Exception.Message)" 'ERROR' }
    }
    Start-Sleep -Seconds 2
    try {
        Write-Log "Starting 'Tobii Service'..."
        Start-Service -Name 'Tobii Service' -ErrorAction Stop
    } catch { Write-Log "Failed to start 'Tobii Service': $($_.Exception.Message)" 'ERROR' }
    if (Wait-ForTracking -TimeoutSec 90 -Since $t0) {
        Restart-InteractionProcess
        return $true
    }
    Write-Log 'Clean stack restart did not reach fresh Tracking.' 'WARN'
    return $false
}
function Invoke-Recovery {
    # Bounded automatic recovery: one lightweight runtime restart, then callers
    # escalate to the deterministic clean-stack transaction.
    param([int]$Level)
    if (-not (Enter-RecoveryCoordinator -Reason "recovery-level-$Level")) { return $false }
    try {
        $t0 = Get-Date
        if ($Level -le 1) {
            Set-RecoveryPhase -Phase 'runtime-restart'
            Restart-RuntimeService
            if (Wait-ForTracking -TimeoutSec 90 -Since $t0) {
                Restart-InteractionProcess
                return $true
            }
            return $false
        }
        return (Invoke-CleanStackRestart)
    } finally { Exit-RecoveryCoordinator }
}
function Invoke-FullReconnect {
    # Complete recovery transaction: restore the USB node, rebuild the stack,
    # reapply stored calibration, discard stale diagnostic sessions, and rebind
    # Interaction. Verification remains passive (engine load), never a gaze stream.
    if (-not (Enter-RecoveryCoordinator -Reason 'full-reconnect')) { return $false }
    try {
        Write-Log 'Full reconnect: tracker port + clean stack + calibration + Interaction rebind.'
        Stop-StaleDiagnosticClients
        Set-RecoveryPhase -Phase 'port-reenumeration'
        $usbOk = Reset-TrackerUsbNode
        if (-not $usbOk -and (Get-TrackerUsbState) -ne 'present') {
            Write-Log 'Full reconnect could not restore USB presence.' 'WARN'
            return $false
        }
        $ok = Invoke-CleanStackRestart
        if (-not $ok) { return $false }

        Set-RecoveryPhase -Phase 'calibration-reapply'
        $calOk = Invoke-CalReapply
        Restart-InteractionProcess
        if (-not $calOk) {
            Write-Log 'Full reconnect restored the stack but calibration re-apply failed.' 'WARN'
        }

        if ((Get-ConsoleIdleSec) -le $StallIdleMaxSec) {
            $verify = Test-GazeWorking
            if ($verify -eq 'unhealthy') {
                Write-Log 'Full reconnect completed, but engine load still indicates stalled gaze processing.' 'WARN'
                return $false
            }
        }
        $script:StallDegradationCount = 0
        return $true
    } finally { Exit-RecoveryCoordinator }
}
# ---- one-shot modes --------------------------------------------------------
if ($Once) {
    $s = Get-TrackerState
    $down = Get-StackDownReason
    $usbState = Get-TrackerUsbState
    $softwareFault = Get-TobiiSoftwareDeviceFault
    Write-Log ("Stack=$(if($down){'DOWN: '+$down}else{'up'})  bootGrace=$(Test-InBootGrace)")
    Write-Log ("USB=$usbState  softwareDevice=$(if($softwareFault){'FAULT: '+$softwareFault}else{'OK'})")
    if (-not $s) { Write-Log "Could not read tracker state." 'WARN'; exit 1 }
    Write-Log ("State=$s  healthy=$([bool]($HealthyStates -contains $s))  trusted=$(-not $down)")
    $cpu = Get-EngineCpuPct -SampleSec 5
    Write-Log ("EngineCPU=$(if($null -ne $cpu){"${cpu}%"}else{'n/a'})  consoleIdle=$(Get-ConsoleIdleSec)s  recalFlag=$([bool](Test-Path -LiteralPath $RecalFlag))")
    exit $(if (($usbState -in @('absent','faulted')) -or $softwareFault) { 2 } else { 0 })
}
if ($ForceReconnect) {
    Write-Log 'Manual -ForceReconnect requested.'
    if (Enter-RecoveryCoordinator -Reason 'manual-full-reconnect') {
        try { Invoke-FullReconnect | Out-Null } finally { Exit-RecoveryCoordinator }
    } else {
        try { Set-Content -LiteralPath $RecoveryRequestFile -Value (Get-Date -Format 'o') -Encoding UTF8 } catch {}
        Write-Log 'Manual full reconnect queued behind the active recovery.' 'WARN'
    }
    Write-Log 'Done.'
    exit 0
}
if ($RestartInteraction) {
    Write-Log 'Manual -RestartInteraction requested (fix cursor warp).'
    if (Enter-RecoveryCoordinator -Reason 'manual-fix-warp') {
        try { Restart-InteractionProcess } finally { Exit-RecoveryCoordinator }
    }
    Write-Log 'Done.'
    exit 0
}
if ($OnWake) {
    Write-Log 'Resume from sleep; checking state.'
    if (-not (Enter-RecoveryCoordinator -Reason 'wake-check')) { exit 0 }
    try {
    Start-Sleep -Seconds 6
    $s = Get-TrackerState
    $down = Get-StackDownReason
    $usbState = Get-TrackerUsbState
    $softwareFault = Get-TobiiSoftwareDeviceFault
    if (Test-ConfigActive) {
        Write-Log 'Resume: calibration/config UI active; no action.'
    } elseif ($usbState -in @('absent','faulted')) {
        Write-Log ("Resume: EyeChip USB $usbState; running full reconnect immediately.") 'WARN'
        if (Invoke-FullReconnect) {
            Clear-RebootNeeded 'wake full reconnect restored USB and tracking'
        } else {
            Set-RebootNeeded 'wake full reconnect could not restore EyeChip USB presence'
        }
    } elseif ($softwareFault) {
        Write-Log ("Resume: $softwareFault; rebuilding the stack.") 'WARN'; Invoke-Recovery -Level 2
    } elseif ($down -and -not (Test-InBootGrace)) {
        Write-Log ("Resume: stack down ($down); reconnecting.") 'WARN'; Invoke-Recovery -Level 2
    } elseif (-not $down -and ($FaultStates -contains $s)) {
        Write-Log ("Resume: state '$s'; reconnecting.") 'WARN'; Invoke-Recovery -Level 2
    } elseif (-not $down -and ($s -eq 'Tracking' -or $s -eq 'Idle')) {
        # Mode D: the classic hibernate-resume failure -- engine comes up 'Tracking'
        # but with no calibration bound to the device (0% CPU, IR LEDs dark). If the
        # user is present and the engine is doing no gaze work, re-apply the stored
        # calibration immediately (fast, no restart, no dots) so gaze is back the
        # moment they sit down instead of waiting for the periodic stall check.
        $cpu = Get-EngineCpuPct -SampleSec 8
        if ($null -ne $cpu -and $cpu -lt $StallCpuPct -and (Get-ConsoleIdleSec) -le $StallIdleMaxSec) {
            Write-Log ("Resume: engine up but only ${cpu}% CPU (no calibration bound); re-applying stored calibration.") 'WARN'
            if (Invoke-CalReapply) {
                $verify = Test-GazeWorking
                if ($verify -eq 'healthy') {
                    Clear-RecalNeeded 'calibration re-applied on wake'
                } elseif ($verify -eq 'unknown') {
                    Write-Log 'Wake calibration completed; pending user-present verification.' 'WARN'
                } else {
                    Write-Log 'Resume: re-apply did not restore healthy engine load; escalating.' 'WARN'
                    Invoke-StallRecovery
                }
            } else {
                # Harder hibernate wake: the resume also tore down the engine's imaging
                # session (IR LEDs fully off), so a bare re-apply cannot restore gaze --
                # it needs a stack reconnect FIRST, then the calibration re-apply. Rather
                # than wait for the periodic stall check to escalate, run the full
                # recovery ladder now (restart -> wait Tracking -> re-apply -> full
                # reconnect -> re-apply) so gaze self-heals on wake instead of staying dead.
                Write-Log 'Resume: re-apply alone did not restore gaze; escalating to reconnect + re-apply now.' 'WARN'
                Invoke-StallRecovery
            }
        } else {
            Write-Log ("Resume: state '$s', engine CPU $(if($null -ne $cpu){"${cpu}%"}else{'n/a'}); no action.")
        }
    } else { Write-Log "Resume: state '$(if($s){$s}else{'unknown'})'; no action." }
    } finally { Exit-RecoveryCoordinator }
    exit 0
}

# ---- single-instance guard -------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\TobiiWatchdogSingleton', [ref]$createdNew)
if (-not $createdNew) { Write-Log 'Another watchdog instance is already running; exiting.'; exit 0 }

# ---- main loop -------------------------------------------------------------
Rotate-Log
Write-Log "Tobii watchdog (log-state + stack-presence + silent-stall) started. threshold=${StuckThresholdSec}s poll=${PollSec}s grace=${GraceSec}s bootgrace=${BootGraceSec}s stall<${StallCpuPct}%cpu/${StallCheckEverySec}s cooldown=${StallCooldownMin}m burst=${BurstStallCheckSec}s/${BurstSec}s resumegap=${ResumeGapSec}s log=$LogPath"
$level = 0; $unhealthySince = $null; $iter = 0; $paused = $false
$stallStrikes = 0; $lastStallCheck = Get-Date; $script:LastStallRecovery = $null
$script:CooldownReconnectDone = $false; $script:JustResumed = $false
$script:WasLocked = [bool](Get-Process -Name 'LogonUI' -ErrorAction SilentlyContinue)
$script:StallDegradationCount = 0
$script:HealthyCpuEwma = 12.0
$script:LastVerifiedHealthy = $null
$script:LastStallCpu = $null
$script:LastHealthSampleCpu = $null
$script:DescriptorTerminalRetryDone = $false
$script:RecentFaults = @()
$script:InteractionRebindPending = $true
$script:InteractionRebindReason = 'watchdog startup'
Clear-Recovering   # never start with a stale recovering flag from a previous run
Update-Heartbeat
# Resume/transition detection: the loop polls every few seconds, so if wall-clock
# jumps far more than that between iterations, the machine was suspended (sleep or
# hibernate) or just came up -- detected WITHOUT relying on Windows' flaky resume
# events. On any such transition (and at startup = post-boot/crash) run an aggressive
# recheck window so a post-wake Mode-D stall is caught in ~15s, not up to a minute.
$lastLoopMark = Get-Date
$burstUntil   = (Get-Date).AddSeconds($BurstSec)
while ($true) {
    try {
        Update-Heartbeat
        if ((++$iter % 60) -eq 0) { Rotate-Log }

        if ((Test-Path -LiteralPath $RecoveryRequestFile) -and -not (Test-ConfigActive)) {
            try { Remove-Item -LiteralPath $RecoveryRequestFile -Force -ErrorAction SilentlyContinue } catch {}
            Write-Log 'Running queued manual full reconnect.' 'WARN'
            Invoke-FullReconnect | Out-Null
            $lastLoopMark = Get-Date
        }

        if (Test-Path $PauseFlag) {
            if (-not $paused) { Write-Log "Paused (tray)."; $paused = $true; $level = 0; $unhealthySince = $null }
            Start-Sleep -Seconds 2
            $lastLoopMark = Get-Date  # keep clock-gap mark fresh so a long pause is not read as a machine resume
            continue
        } elseif ($paused) { Write-Log "Resumed (tray)."; $paused = $false; $lastLoopMark = Get-Date }

        # Clock-gap resume detection: a jump much larger than the poll interval means
        # the box was suspended and just resumed (any of sleep/hibernate/off). Kick off
        # the aggressive recheck window and force an immediate stall check. $lastLoopMark
        # is re-stamped after any (long) recovery below so those don't false-trigger it.
        $nowMark = Get-Date
        $gap = ($nowMark - $lastLoopMark).TotalSeconds
        $lastLoopMark = $nowMark
        if ($gap -gt $ResumeGapSec) {
            Write-Log ("Resume/transition detected (gap $([int]$gap)s); aggressive recheck for ${BurstSec}s.") 'WARN'
            $burstUntil = $nowMark.AddSeconds($BurstSec)
            $lastStallCheck = [DateTime]::MinValue
            $stallStrikes = 0
            $script:JustResumed = $true
            $script:InteractionRebindPending = $true
            $script:InteractionRebindReason = 'resume/transition'
        }

        # Session-unlock detection: a lock/unlock produces NO clock gap and NO Windows
        # power event, yet unlock is when the Tobii runtime re-activates the idled
        # tracker -- the transition the IS5 firmware wedges on (proven 2026-07-10:
        # 71 min locked -> unlock -> descriptor-hang 28s later). The lock screen is
        # visible as the LogonUI process; on the locked->unlocked edge run the same
        # aggressive burst as a resume. While locked, do nothing extra: the engine
        # legitimately idles and the stall detector already requires user activity.
        $lockedNow = [bool](Get-Process -Name 'LogonUI' -ErrorAction SilentlyContinue)
        if ($script:WasLocked -and -not $lockedNow) {
            Write-Log ("Session unlock detected; aggressive recheck for ${BurstSec}s.") 'WARN'
            $burstUntil = (Get-Date).AddSeconds($BurstSec)
            $lastStallCheck = [DateTime]::MinValue
            $stallStrikes = 0
            $script:JustResumed = $true
            $script:InteractionRebindPending = $true
            $script:InteractionRebindReason = 'session unlock'
        } elseif ($lockedNow -and -not $script:WasLocked) {
            # PREVENTIVE maintenance on the unlocked->locked edge. The 07-10 hard wedge
            # was armed by an hour of degradation samples and fired when the runtime's
            # idle->reactivate transition hit the sick device at unlock. A device that
            # showed degradation gets a full CLEAN reconnect now, while the user is
            # away (zero disruption): it then sits freshly re-enumerated through the
            # lock instead of idling in a fragile state. Healthy devices are left
            # alone -- no churn. Skipped when the tracker is already off the bus
            # (fault ladder owns that) or a reboot is pending.
            if (($script:StallDegradationCount -ge 2) -and
                -not (Test-Path -LiteralPath $RebootNeededFlag) -and
                -not (Get-StackDownReason) -and
                -not (Test-TrackerUsbHung)) {
                Write-Log ("Session lock with $($script:StallDegradationCount) degradation samples since last clean reset; preventive full reconnect while user is away.") 'WARN'
                if (Invoke-FullReconnect) { Invoke-CalReapply | Out-Null }
                $lastLoopMark = Get-Date  # long op; do not false-trigger the resume-gap check
            }
        }
        $script:WasLocked = $lockedNow

        $s = Get-TrackerState
        $stackDown = Get-StackDownReason
        $usbState = Get-TrackerUsbState
        $softwareDeviceFault = Get-TobiiSoftwareDeviceFault

        # PnP state is authoritative even when the EyeX log is stale or reports
        # no state. Catch both EyeChip USB failure and live SWD/HID Code 10.
        $fault = $null
        if ($usbState -in @('absent','faulted')) {
            $fault = "EyeChip USB $usbState"
        } elseif ($softwareDeviceFault) {
            $fault = $softwareDeviceFault
        } elseif ($stackDown) {
            if (-not (Test-InBootGrace)) { $fault = $stackDown }
        } elseif ($FaultStates -contains $s) {
            $fault = "state '$s'"
        }

        # Transient/setup/null states are not faults, but they are not positive
        # recovery proof either. Never reset an active ladder merely because the
        # engine moved from WaitingForDevice to Initialize/Configuring/unknown.
        if (-not $fault -and ($stackDown -or -not ($HealthyStates -contains $s))) {
            Update-Heartbeat
            Start-Sleep -Seconds $PollSec
            continue
        }

        if (-not $fault) {
            if ($level -gt 0) { Write-Log "Recovered: state is now '$(if($s){$s}else{'unknown'})'." }
            $level = 0; $unhealthySince = $null
            $script:DescriptorTerminalRetryDone = $false
            Clear-Recovering

            # A wedged PTP session is indistinguishable from a healthy one in
            # Tobii's logs. Prevent it at the transitions that create it, but wait
            # until the engine is live so Interaction binds to fresh Tracking.
            if ($script:InteractionRebindPending -and $s -eq 'Tracking' -and
                -not $lockedNow -and -not (Test-ConfigActive)) {
                if (Enter-RecoveryCoordinator -Reason 'transition-interaction-rebind') {
                    try {
                        Write-Log "Quiet interaction rebind after $($script:InteractionRebindReason)."
                        Restart-InteractionProcess
                        if (Get-Process -Name 'Tobii.EyeX.Interaction' -ErrorAction SilentlyContinue) {
                            $script:InteractionRebindPending = $false
                            $script:InteractionRebindReason = $null
                        }
                    } finally { Exit-RecoveryCoordinator }
                    $lastLoopMark = Get-Date
                }
            }

            # If the recal flag is up and the calibration file has been rewritten
            # since, the user recalibrated -- clear the flag.
            if (Test-Path -LiteralPath $RecalFlag) {
                $flagItem = Get-Item -LiteralPath $RecalFlag -ErrorAction SilentlyContinue
                $calFile  = Get-CalibrationFile
                if ($flagItem -and $calFile -and $calFile.LastWriteTime -gt $flagItem.LastWriteTime) {
                    Clear-RecalNeeded 'calibration file rewritten (user recalibrated)'
                    $script:LastStallRecovery = $null; $stallStrikes = 0
                }
            }

            # Periodic silent-stall check (Mode B/D): 'Tracking' can be a lie.
            # Steady state: two positive samples ~a minute apart before acting.
            # In the post-transition burst window: check every ${BurstStallCheckSec}s
            # and act on the FIRST confirmed stall, so a post-wake dead tracker heals
            # in ~15s instead of up to two minutes. Never while the calibration UI is open.
            $inBurst      = (Get-Date) -lt $burstUntil
            $checkEvery   = if ($inBurst) { $BurstStallCheckSec } else { $StallCheckEverySec }
            if ($s -eq 'Tracking' -and -not (Test-ConfigActive) -and
                ((Get-Date) - $lastStallCheck).TotalSeconds -ge $checkEvery) {
                $lastStallCheck = Get-Date
                $stallKind = Test-SilentStall
                if ($stallKind) {
                    $stallStrikes++
                    $strikesToAct = if ($stallKind -eq 'quiet') { $QuietStallStrikes } elseif ($inBurst) { 1 } else { 2 }
                    if ($stallStrikes -ge $strikesToAct) {
                        $stallStrikes = 0
                        # The first recovery right after a wake bypasses the anti-thrash
                        # cooldown (a fresh wake is legitimate, not thrashing); later
                        # recoveries fall back to the normal cooldown + one-reconnect rule.
                        if ($script:JustResumed) {
                            $script:JustResumed = $false
                            Invoke-StallRecovery -IgnoreCooldown
                        } else {
                            Invoke-StallRecovery
                        }
                        $lastStallCheck = Get-Date
                        $lastLoopMark = Get-Date
                    }
                } else {
                    $stallStrikes = 0
                    if ($script:LastHealthSampleCpu -ge (Get-DegradedCpuThreshold) -and
                        (Get-TrackerUsbState) -eq 'present') {
                        Clear-RebootNeeded 'USB present and engine load verified healthy'
                    }
                }
            }

            if (-not $inBurst) { $script:JustResumed = $false }

            Start-Sleep -Seconds $PollSec
            continue
        }

        # Never intervene while the user is calibrating / in the config UI.
        if (Test-ConfigActive) {
            $unhealthySince = $null
            Start-Sleep -Seconds $PollSec
            continue
        }

        # A power-cycle-needed state is terminal and bounded. If a matching Code 43
        # node is still reachable, permit exactly one final two-pass software retry;
        # otherwise wait quietly for owner-initiated sleep/wake.
        if (Test-Path -LiteralPath $RebootNeededFlag) {
            $usbState = Get-TrackerUsbState
            if ($usbState -eq 'present') {
                Clear-RebootNeeded 'tracker returned after owner power cycle'
                $script:DescriptorTerminalRetryDone = $false
                $level = 0; $unhealthySince = Get-Date
            } elseif (-not $script:DescriptorTerminalRetryDone -and @(Get-TrackerDescriptorFailedNodes).Count -gt 0) {
                $script:DescriptorTerminalRetryDone = $true
                Write-Log 'Manual-sleep flag set, but matching descriptor node is reachable; allowing one final bounded USB retry.' 'WARN'
                Clear-RebootNeeded 'reachable descriptor node gets one final retry'
                $level = 2
                $unhealthySince = (Get-Date).AddSeconds(-$StuckThresholdSec)
            } else {
                $script:RecoveryPhase = 'needs-manual-sleep'
                Update-Heartbeat
                Start-Sleep -Seconds 15
                $lastLoopMark = Get-Date
                continue
            }
        }

        if ($null -eq $unhealthySince) {
            $unhealthySince = Get-Date
            $cutoff = (Get-Date).AddMinutes(-$ClusterWindowMin)
            $script:RecentFaults = @($script:RecentFaults | Where-Object { $_ -gt $cutoff }) + (Get-Date)
            $script:StallDegradationCount += 2
            if ($script:RecentFaults.Count -ge $ClusterEscalateCount -and $level -eq 0) {
                # Repeating a lightweight runtime restart that just failed twice is
                # wasted outage time. Jump directly to the clean stack transaction.
                $level = 1
                Write-Log "$($script:RecentFaults.Count) faults inside ${ClusterWindowMin}m; skipping the lightweight rung." 'WARN'
            }
        }
        # During an active recovery episode (level > 0) the fault has already been
        # continuously confirmed; re-confirming for the full threshold between ladder
        # rungs just delays escalation. 10s is enough to debounce between rungs.
        $effThreshold = if ($level -gt 0) { 10 } else { $StuckThresholdSec }
        if (((Get-Date) - $unhealthySince).TotalSeconds -lt $effThreshold) {
            Start-Sleep -Seconds $PollSec
            continue
        }

        $level = [Math]::Min($level + 1, 3)
        Write-Log ("Tracker fault ($fault) -> recovery level $level.") 'WARN'
        Set-Recovering
        if (($usbState -in @('absent','faulted')) -or ($level -ge 3)) {
            # WaitingForDevice with the tracker NOT cleanly on the bus (descriptor
            # hang / fell off), or plain restarts have not cleared it. Re-enumerate
            # the tracker's OWN USB port (safe: only its port, verifies it ends
            # enabled). If that can't bring it back, it is a true firmware/hardware
            # wedge that needs an owner-initiated S3 power cycle -- flag it and
            # enter a bounded terminal state instead of continuing to thrash.
            if (Test-Path -LiteralPath $RebootNeededFlag) {
                Write-Log 'Tracker off USB; reboot-needed already flagged -- waiting (no more port cycles).' 'WARN'
            } else {
                Write-Log 'Tracker hung on USB; re-enumerating its port.' 'WARN'
                if (Enter-RecoveryCoordinator -Reason 'usb-hang-recovery') {
                  try {
                  Set-RecoveryPhase -Phase 'port-reenumeration' -Reason 'USB hang'
                  if (Reset-TrackerUsbNode) {
                    Invoke-CleanStackRestart | Out-Null
                    Clear-RebootNeeded 'tracker port re-enumerated'
                  } elseif ($level -ge $UsbHangRebootLevel) {
                    Set-RebootNeeded 'tracker fell off USB and port re-enumeration could not recover it; owner-initiated sleep/wake required'
                  }
                  } finally { Exit-RecoveryCoordinator }
                }
            }
        # Code 10 and stack-down faults need both middleware services restarted.
        } elseif ($softwareDeviceFault -or $stackDown) {
            Invoke-Recovery -Level 2
        } else {
            Invoke-Recovery -Level $level
        }
        Start-Sleep -Seconds ($GraceSec + [Math]::Min(($level - 1) * 30, 120))
        $unhealthySince = Get-Date
        $lastLoopMark = Get-Date  # exclude the long recovery from the next clock-gap check
    } catch {
        Write-Log "Loop error: $($_.Exception.Message)" 'ERROR'
        Start-Sleep -Seconds $PollSec
    }
}
