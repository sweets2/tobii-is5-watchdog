<#
    Tobii-Watchdog.ps1  (passive log-state edition)
    -----------------------------------------------
    Keeps the Alienware/Tobii IS5 eye tracker alive WITHOUT ever touching the
    gaze stream. It only READS the EyeX engine's ServerLog.txt to see the state
    machine; when the engine drops to a non-tracking state (WaitingForDevice,
    etc.) and stays there past a threshold, it forces a clean reconnect.

    IMPORTANT: this watchdog never subscribes to gaze. A second gaze subscriber
    breaks this hardware (it resets every ~2-3s). Passive log reading is the only
    safe approach, so it catches the connection-drop outages but NOT the rarer
    "streaming but frozen/invalid" stall -- use the tray's "Reconnect now" button
    for that.

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
    actively giving input (so the tracker SHOULD be seeing eyes) AND engine CPU
    stays at idle level across a sample window, twice in a row. Recovery ladder:
    stack restart -> full reconnect (USB power-cycle) -> give up and raise the
    'recalibration needed' flag, which the tray turns into a notification.
    Caveat: typing with the tracker blind (lid closed on an external monitor)
    looks identical; the cooldown caps that at one ladder per $StallCooldownMin.

    Recovery escalation (auto): 1 = restart runtime service; 2+ = kill+respawn
    EyeX engine, restart runtime + service. EVERY level then bounces the interaction
    process once Tracking returns, so the gaze->cursor warp re-binds (restarting the
    runtime service alone breaks that binding = gaze works but the cursor warp is
    dead). If WaitingForDevice persists with the
    tracker HUNG ON USB (descriptor-request-failed / off the bus -- common after a
    hibernate/sleep resume), it re-enumerates the tracker's OWN USB port (safe: only
    its port, and it verifies the device ends ENABLED) -- this recovers a device that
    plain restarts cannot, with NO reboot. If even that cannot bring it back it raises
    a REBOOT-needed flag (tray notification) and stops thrashing. (A blanket USB
    power-cycle stays OUT of auto -- it once left the device DISABLED -- and remains
    manual-only via -ForceReconnect / the full-reconnect path.)

    Modes:  -Once  print state & exit   -ForceReconnect  full reconnect & exit
            -OnWake  resume-from-sleep reconnect if not tracking
            -RestartInteraction  bounce Tobii.EyeX.Interaction (fix cursor warp)
#>
[CmdletBinding()]
param(
    [int]$StuckThresholdSec = 30,
    [int]$PollSec          = 5,
    [int]$GraceSec         = 45,
    [int]$BootGraceSec     = 240,
    [string]$LogPath       = 'C:\Scripts\Tobii-Watchdog.log',
    [int]$MaxLogBytes      = 1048576,
    [string]$PauseFlag     = 'C:\Scripts\watchdog.pause',
    [string]$ServerLog     = "",
    [double]$StallCpuPct       = 1.5,
    [int]$StallIdleMaxSec      = 60,
    [int]$StallCheckEverySec   = 60,
    [int]$StallCooldownMin     = 45,
    [int]$ResumeGapSec         = 90,
    [int]$BurstSec             = 150,
    [int]$BurstStallCheckSec   = 15,
    [string]$RecalFlag         = 'C:\Scripts\tobii-recal-needed.flag',
    [string]$RebootNeededFlag  = 'C:\Scripts\tobii-reboot-needed.flag',
    [string]$RecoveringFlag    = 'C:\Scripts\tobii-recovering.flag',
    [int]$UsbHangRebootLevel   = 5,
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

# Never recover while the Tobii calibration/config UI is open (setup in progress).
function Test-ConfigActive {
    [bool](Get-Process -Name 'Tobii.Configuration' -ErrorAction SilentlyContinue)
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
    $p2 = Get-Process -Id $p1.Id -ErrorAction SilentlyContinue
    if (-not $p2 -or $p2.ProcessName -ne 'Tobii.EyeX.Engine') { return $null }
    return [Math]::Round((($p2.CPU - $cpu1) / $SampleSec) * 100, 1)
}
function Test-SilentStall {
    # True only when ALL hold: stack up, engine claims Tracking, the user was
    # giving input just now (tracker should see them), and engine CPU sampled
    # at idle level. Cheap gates run first; the CPU sample blocks ~12s.
    if (Get-StackDownReason) { return $false }
    if ((Get-ConsoleIdleSec) -gt $StallIdleMaxSec) { return $false }
    if ((Get-TrackerState) -ne 'Tracking') { return $false }
    $cpu = Get-EngineCpuPct -SampleSec 12
    if ($null -eq $cpu -or $cpu -ge $StallCpuPct) { return $false }
    # user must still have been around during the sample window
    if ((Get-ConsoleIdleSec) -gt ($StallIdleMaxSec + 15)) { return $false }
    Write-Log ("Silent-stall sample: state=Tracking, engine CPU ${cpu}%, user active.") 'WARN'
    # Degradation bookkeeping: single samples (below the 2-consecutive-strikes action
    # threshold) still mark the device as degraded since its last clean re-enumeration.
    # The 07-10 hard wedge was preceded by an HOUR of such samples; they arm the
    # preventive at-lock reconnect (see main loop).
    $script:StallDegradationCount++
    return $true
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
    # reboot clears. The tray shows this as a separate "reboot needed" notification.
    param([string]$Reason)
    if (-not (Test-Path -LiteralPath $RebootNeededFlag)) {
        Write-Log ("Raising REBOOT-needed flag: $Reason") 'ERROR'
        try { Set-Content -LiteralPath $RebootNeededFlag -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Reason) } catch { }
    }
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
function Test-StallCleared {
    # After a recovery step: wait for a fresh Tracking, then confirm the engine
    # is actually working (CPU at tracking level while the user is present).
    param([datetime]$Since)
    if (-not (Wait-ForTracking -TimeoutSec 90 -Since $Since)) { return $false }
    Start-Sleep -Seconds 5
    for ($i = 0; $i -lt 6; $i++) {
        if ((Get-ConsoleIdleSec) -le $StallIdleMaxSec) {
            $cpu = Get-EngineCpuPct -SampleSec 10
            if ($null -ne $cpu) {
                Write-Log ("Stall-recovery verify: engine CPU ${cpu}%.")
                return ($cpu -ge $StallCpuPct)
            }
        }
        Start-Sleep -Seconds 10
    }
    # User stepped away mid-verification; assume cleared -- the periodic stall
    # check will fire again if it is not.
    Write-Log 'Stall-recovery verify: user idle, cannot confirm; assuming cleared.'
    return $true
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
    # present). Unlike Test-StallCleared this does NOT wait for a fresh 'Tracking'
    # line -- a bare re-apply produces no state transition (the engine was already
    # 'Tracking'); it just starts doing gaze work again.
    Start-Sleep -Seconds 4
    for ($i = 0; $i -lt 4; $i++) {
        if ((Get-ConsoleIdleSec) -le $StallIdleMaxSec) {
            $cpu = Get-EngineCpuPct -SampleSec 10
            if ($null -ne $cpu) {
                Write-Log ("Gaze-recovery verify: engine CPU ${cpu}%.")
                return ($cpu -ge $StallCpuPct)
            }
        }
        Start-Sleep -Seconds 8
    }
    Write-Log 'Gaze-recovery verify: user idle, cannot confirm; assuming cleared.'
    return $true
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
    $inCooldown = (-not $IgnoreCooldown) -and $script:LastStallRecovery -and (((Get-Date) - $script:LastStallRecovery).TotalMinutes -lt $StallCooldownMin)
    if ($inCooldown) {
        # Inside the restart cooldown (anti-thrash). A calibration re-apply is free
        # (no restart) -- try it first.
        Write-Log 'Silent stall within restart cooldown; trying calibration re-apply first.' 'WARN'
        if ((Invoke-CalReapply) -and (Test-GazeWorking)) {
            Write-Log 'Stall cleared by calibration re-apply (cooldown path).'
            Clear-RecalNeeded 'calibration re-applied'
            return
        }
        # Re-apply was not enough. Allow ONE reconnect per cooldown window before
        # giving up -- a fresh re-stall (e.g. a second hibernate wake soon after the
        # first) can need the imaging session rebuilt, and flagging for recalibration
        # without trying that is premature.
        if (-not $script:CooldownReconnectDone) {
            $script:CooldownReconnectDone = $true
            Write-Log 'Re-apply insufficient in cooldown; one reconnect before flagging.' 'WARN'
            $tc = Get-Date
            Invoke-Recovery -Level 2
            if (Wait-ForTracking -TimeoutSec 90 -Since $tc) { Invoke-CalReapply | Out-Null }
            if (Test-GazeWorking) {
                Write-Log 'Stall cleared by cooldown reconnect + re-apply.'
                Clear-RecalNeeded 'engine tracking again'
                return
            }
        }
        Set-RecalNeeded 'stall persisted; re-apply + one cooldown reconnect did not restore gaze'
        return
    }
    $script:LastStallRecovery = Get-Date
    $script:CooldownReconnectDone = $false
    Set-Recovering
    Write-Log 'SILENT STALL confirmed: engine claims Tracking at idle CPU while user is active. Starting recovery.' 'ERROR'

    # Step 0 -- primary Mode-D fix: re-apply stored calibration (fast, no restart).
    if ((Invoke-CalReapply) -and (Test-GazeWorking)) {
        Write-Log 'Stall cleared by calibration re-apply (no restart needed).'
        Clear-RecalNeeded 'calibration re-applied'
        return
    }

    # Step 1 -- stack restart, wait for a fresh Tracking, then re-apply calibration.
    Write-Log 'Re-apply alone did not clear it; escalating to stack restart.' 'WARN'
    $t0 = Get-Date
    Invoke-Recovery -Level 2
    if (Wait-ForTracking -TimeoutSec 90 -Since $t0) { Invoke-CalReapply | Out-Null }
    if (Test-GazeWorking) {
        Write-Log 'Stall cleared by stack restart + calibration re-apply.'
        Clear-RecalNeeded 'engine tracking again'
        return
    }

    # Step 2 -- full reconnect (USB power-cycle), wait, then re-apply calibration.
    Write-Log 'Stall survived stack restart; escalating to full reconnect (USB power-cycle).' 'WARN'
    $t1 = Get-Date
    Invoke-FullReconnect
    if (Wait-ForTracking -TimeoutSec 90 -Since $t1) { Invoke-CalReapply | Out-Null }
    if (Test-GazeWorking) {
        Write-Log 'Stall cleared by full reconnect + calibration re-apply.'
        Clear-RecalNeeded 'engine tracking again'
        return
    }

    # Exhausted: even re-applying the stored calibration did not bring gaze back --
    # genuine loss (e.g. no stored calibration exists). Ask the user to recalibrate.
    Write-Log 'Stall survived re-apply + full ladder; genuine calibration loss (recalibration needed).' 'ERROR'
    Set-RecalNeeded 'auto-recovery + calibration re-apply exhausted'
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
function Restart-MiddlewareService {
    try { Write-Log "Restarting 'Tobii Service'..."
          Restart-Service -Name 'Tobii Service' -Force -ErrorAction Stop
          Write-Log "Restarted 'Tobii Service'." }
    catch { Write-Log "Failed to restart 'Tobii Service': $($_.Exception.Message)" 'ERROR' }
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
    param([int]$TimeoutSec = 90, [datetime]$Since = (Get-Date))
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
        if (-not (Get-StackDownReason)) {
            $s = Get-TrackerStateStamped
            if ($s -and $s.State -eq 'Tracking' -and $s.Time -and $s.Time -gt $Since) { return $true }
        }
        Start-Sleep -Seconds 3
    }
    return $false
}
function Reset-UsbDevice {
    # Manual-only (aggressive). Verifies the device ends ENABLED (a bare
    # restart-device can leave it in problem code 22 = disabled).
    $dev = Get-PnpDevice -ErrorAction SilentlyContinue |
             Where-Object { $_.InstanceId -match 'VID_2104' -and $_.Class -eq 'USBDevice' }
    if (-not $dev) { Write-Log 'Tobii USB node (VID_2104) not found for power-cycle.' 'WARN'; return }
    $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    foreach ($d in $dev) {
        Write-Log "Power-cycling USB device '$($d.FriendlyName)' via pnputil..."
        try { & $pnputil /restart-device "$($d.InstanceId)" 2>&1 | Out-Null } catch {}
        Start-Sleep -Seconds 2
        $now = Get-PnpDevice -InstanceId $d.InstanceId -ErrorAction SilentlyContinue
        if ($now -and $now.Status -ne 'OK') {
            Write-Log "USB device status '$($now.Status)' after reset; forcing enable." 'WARN'
            try { & $pnputil /enable-device "$($d.InstanceId)" 2>&1 | Out-Null } catch {}
            try { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        }
    }
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
function Reset-TrackerUsbNode {
    # SAFE, auto-runnable recovery for a tracker hung mid-enumeration. When the IS5
    # firmware wedges (e.g. after a hibernate/sleep resume) it can drop its real
    # identity (VID_2104&PID_030C) and re-appear as a generic "Device Descriptor
    # Request Failed" node (VID_0000&PID_0002) on the SAME hub port -- so Reset-
    # UsbDevice (which matches VID_2104) never finds it and the service-restart
    # ladder thrashes forever. This cycles BOTH the real tracker node(s) AND any
    # descriptor-failed stand-in ON THE TRACKER'S OWN PORT (the connection locator is
    # read from the tracker's node at runtime -- never hardcoded), then rescans. It
    # touches ONLY the tracker's port, never the parent hub or the keyboard, and
    # verifies the device ends ENABLED -- so it is safe to run automatically (unlike
    # the blanket USB power-cycle we keep out of auto). Returns $true if a VID_2104
    # node comes back OK + present. (Verified live 2026-07-09: recovered a device
    # that was fully off the bus, no reboot.)
    $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    $trackerNodes = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_2104&PID_030C' })
    # the USB connection locator (e.g. '5&1a2b3c&0&9') pins the exact hub port
    $loc = $null
    foreach ($t in $trackerNodes) {
        $seg = ($t.InstanceId -split '\\')[-1]
        if ($seg -match '&\d+&\d+$') { $loc = $seg; break }
    }
    $failed = @()
    if ($loc) {
        $failed = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
            $_.InstanceId -match 'VID_0000&PID_0002' -and (($_.InstanceId -split '\\')[-1] -eq $loc) })
    }
    $nodes = @(($trackerNodes + $failed) | Sort-Object -Property InstanceId -Unique)
    if (-not $nodes) { Write-Log 'Tracker USB node not found to port-cycle.' 'WARN'; return $false }
    foreach ($d in $nodes) {
        Write-Log ("Re-enumerating tracker port node ($($d.Status)): $($d.InstanceId)")
        try { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Seconds 2
        try { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Seconds 2
    }
    try { & $pnputil /scan-devices 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 4
    # verify + force-enable anything that came back present-but-not-OK (avoid code 22)
    $ok = $false
    foreach ($t in @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_2104&PID_030C' })) {
        $p = (Get-PnpDeviceProperty -InstanceId $t.InstanceId -KeyName 'DEVPKEY_Device_IsPresent' -ErrorAction SilentlyContinue).Data
        if ($t.Status -eq 'OK' -and $p) { $ok = $true }
        elseif ($p -and $t.Status -ne 'OK') {
            try { & $pnputil /enable-device "$($t.InstanceId)" 2>&1 | Out-Null } catch {}
            try { Enable-PnpDevice -InstanceId $t.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        }
    }
    Write-Log ("Tracker port re-enumeration: " + $(if ($ok) { 'device back OK/present.' } else { 'device still not enumerating.' }))
    return $ok
}
function Invoke-Recovery {
    # AUTO recovery ladder -- no USB power-cycle (kept out of auto on purpose).
    param([int]$Level)
    $t0 = Get-Date
    if ($Level -le 1) { Restart-RuntimeService }
    else { Restart-EyeXEngine; Restart-RuntimeService; Restart-MiddlewareService }
    # ANY recovery that restarts the runtime service breaks the interaction<->engine
    # PTP/warp binding: gaze comes back but the eyes-move-cursor warp stays dead until
    # the interaction process re-binds. So bounce interaction after EVERY level (not
    # just 2+), once a fresh Tracking returns, so the warp self-heals too.
    Invoke-PostRecoveryInteractionReset -Since $t0
}
function Invoke-FullReconnect {
    # MANUAL "fix it hard": tracker-port re-enumeration (recovers a descriptor-hung
    # device that is off the bus) + USB power-cycle + full stack recycle.
    Write-Log 'Full reconnect: tracker port re-enumeration + USB power-cycle + engine + services.'
    $t0 = Get-Date
    Reset-TrackerUsbNode | Out-Null
    Reset-UsbDevice
    Restart-EyeXEngine
    Restart-RuntimeService
    Restart-MiddlewareService
    Invoke-PostRecoveryInteractionReset -Since $t0
    # A full reconnect IS a clean re-enumeration: clear the degradation counter that
    # arms the preventive at-lock reconnect.
    $script:StallDegradationCount = 0
}
function Invoke-PostRecoveryInteractionReset {
    # After a full-stack restart the service respawns the interaction process
    # BEFORE the engine reaches Tracking, and it can bind its PTP session dead
    # (Mode E). Once the engine reports a fresh Tracking, bounce interaction so
    # it binds against a live engine.
    param([datetime]$Since)
    if (Wait-ForTracking -TimeoutSec 90 -Since $Since) {
        Restart-InteractionProcess
    } else {
        Write-Log 'Engine did not reach fresh Tracking within 90s; skipping interaction reset.' 'WARN'
    }
}

# ---- one-shot modes --------------------------------------------------------
if ($Once) {
    $s = Get-TrackerState
    $down = Get-StackDownReason
    Write-Log ("Stack=$(if($down){'DOWN: '+$down}else{'up'})  bootGrace=$(Test-InBootGrace)")
    if (-not $s) { Write-Log "Could not read tracker state." 'WARN'; exit 1 }
    Write-Log ("State=$s  healthy=$([bool]($HealthyStates -contains $s))  trusted=$(-not $down)")
    $cpu = Get-EngineCpuPct -SampleSec 5
    Write-Log ("EngineCPU=$(if($null -ne $cpu){"${cpu}%"}else{'n/a'})  consoleIdle=$(Get-ConsoleIdleSec)s  recalFlag=$([bool](Test-Path -LiteralPath $RecalFlag))")
    exit 0
}
if ($ForceReconnect) {
    Write-Log 'Manual -ForceReconnect requested.'
    Invoke-FullReconnect
    Write-Log 'Done.'
    exit 0
}
if ($RestartInteraction) {
    Write-Log 'Manual -RestartInteraction requested (fix cursor warp).'
    Restart-InteractionProcess
    Write-Log 'Done.'
    exit 0
}
if ($OnWake) {
    Write-Log 'Resume from sleep; checking state.'
    Start-Sleep -Seconds 6
    $s = Get-TrackerState
    $down = Get-StackDownReason
    if (Test-ConfigActive) {
        Write-Log 'Resume: calibration/config UI active; no action.'
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
            if ((Invoke-CalReapply) -and (Test-GazeWorking)) {
                Clear-RecalNeeded 'calibration re-applied on wake'
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
Clear-Recovering   # never start with a stale recovering flag from a previous run
# Resume/transition detection: the loop polls every few seconds, so if wall-clock
# jumps far more than that between iterations, the machine was suspended (sleep or
# hibernate) or just came up -- detected WITHOUT relying on Windows' flaky resume
# events. On any such transition (and at startup = post-boot/crash) run an aggressive
# recheck window so a post-wake Mode-D stall is caught in ~15s, not up to a minute.
$lastLoopMark = Get-Date
$burstUntil   = (Get-Date).AddSeconds($BurstSec)
while ($true) {
    try {
        if ((++$iter % 60) -eq 0) { Rotate-Log }

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
                $tL = Get-Date
                Invoke-FullReconnect
                if (Wait-ForTracking -TimeoutSec 90 -Since $tL) { Invoke-CalReapply | Out-Null }
                $lastLoopMark = Get-Date  # long op; do not false-trigger the resume-gap check
            }
        }
        $script:WasLocked = $lockedNow

        $s = Get-TrackerState
        $stackDown = Get-StackDownReason

        # Two fault classes:
        #  1) Stack down (service stopped / engine gone). The log state is stale
        #     here -- after a crash or cold boot it still says 'Tracking' from the
        #     previous session -- so it is ignored. Post-boot grace applies
        #     because 'Tobii Service' is delayed-start.
        #  2) Engine alive and reporting WaitingForDevice (the PRP-drop
        #     signature). Only this state is a fault; Tracking, Idle, null and
        #     all transient/setup states (incl. Configuring = calibration) are
        #     left alone.
        $fault = $null
        if ($stackDown) {
            if (-not (Test-InBootGrace)) { $fault = $stackDown }
        } elseif ($FaultStates -contains $s) {
            $fault = "state '$s'"
        }

        if (-not $fault) {
            if ($level -gt 0) { Write-Log "Recovered: state is now '$(if($s){$s}else{'unknown'})'." }
            $level = 0; $unhealthySince = $null
            Clear-RebootNeeded 'tracker healthy again'
            Clear-Recovering

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
            $strikesToAct = if ($inBurst) { 1 } else { 2 }
            if ($s -eq 'Tracking' -and -not (Test-ConfigActive) -and
                ((Get-Date) - $lastStallCheck).TotalSeconds -ge $checkEvery) {
                $lastStallCheck = Get-Date
                if (Test-SilentStall) {
                    $stallStrikes++
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
                }
            }

            Start-Sleep -Seconds $PollSec
            continue
        }

        # Never intervene while the user is calibrating / in the config UI.
        if (Test-ConfigActive) {
            $unhealthySince = $null
            Start-Sleep -Seconds $PollSec
            continue
        }

        if ($null -eq $unhealthySince) { $unhealthySince = Get-Date }
        if (((Get-Date) - $unhealthySince).TotalSeconds -lt $StuckThresholdSec) {
            Start-Sleep -Seconds $PollSec
            continue
        }

        $level++
        Write-Log ("Tracker fault ($fault) -> recovery level $level.") 'WARN'
        Set-Recovering
        # A stack-down fault needs the middleware service (re)started, which only
        # happens at level 2 of the ladder -- level 1 (runtime restart) can't help.
        if ($stackDown) {
            Invoke-Recovery -Level 2
        } elseif ((Test-TrackerUsbHung) -or ($level -ge 3)) {
            # WaitingForDevice with the tracker NOT cleanly on the bus (descriptor
            # hang / fell off), or plain restarts have not cleared it. Re-enumerate
            # the tracker's OWN USB port (safe: only its port, verifies it ends
            # enabled). If that can't bring it back, it is a true firmware/hardware
            # wedge that only a reboot clears -- flag it and stop thrashing.
            if (Test-Path -LiteralPath $RebootNeededFlag) {
                Write-Log 'Tracker off USB; reboot-needed already flagged -- waiting (no more port cycles).' 'WARN'
            } else {
                Write-Log 'WaitingForDevice with tracker hung on USB; re-enumerating its port.' 'WARN'
                if (Reset-TrackerUsbNode) {
                    Restart-EyeXEngine; Restart-RuntimeService; Restart-MiddlewareService
                    Clear-RebootNeeded 'tracker port re-enumerated'
                } elseif ($level -ge $UsbHangRebootLevel) {
                    Set-RebootNeeded 'tracker fell off USB and a port re-enumeration could not recover it; sleep/wake the PC (cuts tracker power) or reboot'
                }
            }
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
