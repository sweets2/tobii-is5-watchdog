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

    Recovery escalation (auto): 1 = restart runtime service; 2+ = kill+respawn
    EyeX engine, restart runtime + service. (No USB power-cycle in auto -- that
    once left the device DISABLED; it's manual-only via -ForceReconnect.)

    Modes:  -Once  print state & exit   -ForceReconnect  full reconnect & exit
            -OnWake  resume-from-sleep reconnect if not tracking
#>
[CmdletBinding()]
param(
    [int]$StuckThresholdSec = 30,
    [int]$PollSec          = 5,
    [int]$GraceSec         = 45,
    [string]$LogPath       = 'C:\Scripts\Tobii-Watchdog.log',
    [int]$MaxLogBytes      = 1048576,
    [string]$PauseFlag     = 'C:\Scripts\watchdog.pause',
    [string]$ServerLog     = "",
    [switch]$Once,
    [switch]$ForceReconnect,
    [switch]$OnWake
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
function Get-TrackerState {
    $path = $ServerLog
    if (-not $path) {
        $mine = Join-Path $env:LOCALAPPDATA 'Tobii\Tobii Interaction\ServerLog.txt'
        if (Test-Path $mine) { $path = $mine }
        else {
            $c = Get-ChildItem 'C:\Users\*\AppData\Local\Tobii\Tobii Interaction\ServerLog.txt' -EA SilentlyContinue |
                 Sort-Object LastWriteTime -Descending
            if ($c) { $path = $c[0].FullName }
        }
    }
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
    else              { Restart-EyeXEngine; Restart-RuntimeService; Restart-MiddlewareService }
}
function Invoke-FullReconnect {
    # MANUAL "fix it hard": USB power-cycle (verified) + full stack recycle.
    Write-Log 'Full reconnect: USB power-cycle + engine + services.'
    Reset-UsbDevice
    Restart-EyeXEngine
    Restart-RuntimeService
    Restart-MiddlewareService
}

# ---- one-shot modes --------------------------------------------------------
if ($Once) {
    $s = Get-TrackerState
    if (-not $s) { Write-Log "Could not read tracker state." 'WARN'; exit 1 }
    Write-Log ("State=$s  healthy=$([bool]($HealthyStates -contains $s))")
    exit 0
}
if ($ForceReconnect) {
    Write-Log 'Manual -ForceReconnect requested.'
    Invoke-FullReconnect
    Write-Log 'Done.'
    exit 0
}
if ($OnWake) {
    Write-Log 'Resume from sleep; checking state.'
    Start-Sleep -Seconds 6
    $s = Get-TrackerState
    if (($FaultStates -contains $s) -and -not (Test-ConfigActive)) {
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
Write-Log "Tobii watchdog (log-state) started. threshold=${StuckThresholdSec}s poll=${PollSec}s grace=${GraceSec}s log=$LogPath"
$level = 0; $unhealthySince = $null; $iter = 0; $paused = $false
while ($true) {
    try {
        if ((++$iter % 60) -eq 0) { Rotate-Log }

        if (Test-Path $PauseFlag) {
            if (-not $paused) { Write-Log "Paused (tray)."; $paused = $true; $level = 0; $unhealthySince = $null }
            Start-Sleep -Seconds 2
            continue
        } elseif ($paused) { Write-Log "Resumed (tray)."; $paused = $false }

        $s = Get-TrackerState
        # Only WaitingForDevice is a fault. Anything else (incl. null, Configuring,
        # and all transient states) is left alone -> reset timers and wait.
        if ($FaultStates -notcontains $s) {
            if ($level -gt 0) { Write-Log "Recovered: state is now '$s'." }
            $level = 0; $unhealthySince = $null
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
        Write-Log ("Tracker stuck in '$s' -> recovery level $level.") 'WARN'
        Invoke-Recovery -Level $level
        Start-Sleep -Seconds ($GraceSec + [Math]::Min(($level - 1) * 30, 120))
        $unhealthySince = Get-Date
    } catch {
        Write-Log "Loop error: $($_.Exception.Message)" 'ERROR'
        Start-Sleep -Seconds $PollSec
    }
}
