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
    EyeX engine, restart runtime + service. (No USB power-cycle in auto -- that
    once left the device DISABLED; it's manual-only via -ForceReconnect and the
    silent-stall ladder, both of which verify the device ends ENABLED.)

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
    [string]$RecalFlag         = 'C:\Scripts\tobii-recal-needed.flag',
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
function Invoke-StallRecovery {
    # Ladder for the 'Tracking-but-dead' stall. Each step is verified by actual
    # engine CPU, not by the state line (the state line is the thing that lies).
    if ($script:LastStallRecovery -and ((Get-Date) - $script:LastStallRecovery).TotalMinutes -lt $StallCooldownMin) {
        Write-Log 'Silent stall again within cooldown; flagging for recalibration instead of restarting again.' 'WARN'
        Set-RecalNeeded 'stall persisted through recovery cooldown'
        return
    }
    $script:LastStallRecovery = Get-Date
    Write-Log 'SILENT STALL confirmed: engine claims Tracking at idle CPU while user is active. Starting stall ladder.' 'ERROR'
    $t0 = Get-Date
    Invoke-Recovery -Level 2
    if (Test-StallCleared -Since $t0) {
        Write-Log 'Stall cleared by stack restart.'
        Clear-RecalNeeded 'engine tracking again'
        return
    }
    Write-Log 'Stall survived the stack restart; escalating to full reconnect (USB power-cycle).' 'WARN'
    $t1 = Get-Date
    Invoke-FullReconnect
    if (Test-StallCleared -Since $t1) {
        Write-Log 'Stall cleared by full reconnect.'
        Clear-RecalNeeded 'engine tracking again'
        return
    }
    Write-Log 'Stall survived the full ladder; this is almost certainly lost calibration (Mode D).' 'ERROR'
    Set-RecalNeeded 'auto-recovery exhausted; engine tracks nothing at 0% CPU'
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
function Invoke-Recovery {
    # AUTO recovery ladder -- no USB power-cycle (kept out of auto on purpose).
    param([int]$Level)
    if ($Level -le 1) { Restart-RuntimeService }
    else {
        $t0 = Get-Date
        Restart-EyeXEngine; Restart-RuntimeService; Restart-MiddlewareService
        Invoke-PostRecoveryInteractionReset -Since $t0
    }
}
function Invoke-FullReconnect {
    # MANUAL "fix it hard": USB power-cycle (verified) + full stack recycle.
    Write-Log 'Full reconnect: USB power-cycle + engine + services.'
    $t0 = Get-Date
    Reset-UsbDevice
    Restart-EyeXEngine
    Restart-RuntimeService
    Restart-MiddlewareService
    Invoke-PostRecoveryInteractionReset -Since $t0
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
    } else { Write-Log "Resume: state '$(if($s){$s}else{'unknown'})'; no action." }
    exit 0
}

# ---- single-instance guard -------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\TobiiWatchdogSingleton', [ref]$createdNew)
if (-not $createdNew) { Write-Log 'Another watchdog instance is already running; exiting.'; exit 0 }

# ---- main loop -------------------------------------------------------------
Rotate-Log
Write-Log "Tobii watchdog (log-state + stack-presence + silent-stall) started. threshold=${StuckThresholdSec}s poll=${PollSec}s grace=${GraceSec}s bootgrace=${BootGraceSec}s stall<${StallCpuPct}%cpu/${StallCheckEverySec}s cooldown=${StallCooldownMin}m log=$LogPath"
$level = 0; $unhealthySince = $null; $iter = 0; $paused = $false
$stallStrikes = 0; $lastStallCheck = Get-Date; $script:LastStallRecovery = $null
while ($true) {
    try {
        if ((++$iter % 60) -eq 0) { Rotate-Log }

        if (Test-Path $PauseFlag) {
            if (-not $paused) { Write-Log "Paused (tray)."; $paused = $true; $level = 0; $unhealthySince = $null }
            Start-Sleep -Seconds 2
            continue
        } elseif ($paused) { Write-Log "Resumed (tray)."; $paused = $false }

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
            # Two positive samples ~a minute apart before acting; never while
            # the calibration UI is open.
            if ($s -eq 'Tracking' -and -not (Test-ConfigActive) -and
                ((Get-Date) - $lastStallCheck).TotalSeconds -ge $StallCheckEverySec) {
                $lastStallCheck = Get-Date
                if (Test-SilentStall) {
                    $stallStrikes++
                    if ($stallStrikes -ge 2) {
                        $stallStrikes = 0
                        Invoke-StallRecovery
                        $lastStallCheck = Get-Date
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
        # A stack-down fault needs the middleware service (re)started, which only
        # happens at level 2 of the ladder -- level 1 (runtime restart) can't help.
        if ($stackDown) { Invoke-Recovery -Level 2 } else { Invoke-Recovery -Level $level }
        Start-Sleep -Seconds ($GraceSec + [Math]::Min(($level - 1) * 30, 120))
        $unhealthySince = Get-Date
    } catch {
        Write-Log "Loop error: $($_.Exception.Message)" 'ERROR'
        Start-Sleep -Seconds $PollSec
    }
}
