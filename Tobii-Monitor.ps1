<#
    Tobii-Monitor.ps1  - passive telemetry recorder for the Tobii eye tracker.
    ------------------------------------------------------------------------
    OBSERVE ONLY. It never touches the device and never subscribes to gaze, so
    it cannot affect tracking. Runs continuously (own task, non-elevated), samples
    everything we care about every SampleSec, and appends one JSON line per sample
    to Tobii-Telemetry.jsonl. On a detected drop/recovery it writes an event line
    and (on drop) a full snapshot to Tobii-Diagnostics\snapshots\.

    Everything sampled is passive: ServerLog state, PnP device status, service
    states, process presence/CPU/mem, user-idle time, fullscreen state, power.

    Modes:
        (default)   run the sampling loop
        -Stats      print a health report (MTBF, drop count, uptime, etc.) & exit
        -Once       print a single current sample as JSON & exit
#>
[CmdletBinding()]
param(
    [int]$SampleSec       = 20,
    [string]$Telemetry    = 'C:\Scripts\Tobii-Telemetry.jsonl',
    [int]$MaxTelemetryBytes = 5242880,          # 5 MB rotation
    [string]$SnapshotDir  = 'C:\Scripts\Tobii-Diagnostics\snapshots',
    [string]$PauseFlag    = 'C:\Scripts\watchdog.pause',
    [switch]$Stats,
    [switch]$Once
)
$ErrorActionPreference = 'Continue'
$ServerLogPath = Join-Path $env:LOCALAPPDATA 'Tobii\Tobii Interaction\ServerLog.txt'
$HealthyStates = @('Tracking','Idle')
# Auto-detect the Tobii IS5 USB node (VID 2104 = Tobii). Works on any m17 R2 /
# IS5 unit -- no hardcoded per-device serial.
$DeviceInstId  = (Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match 'VID_2104&PID_030C' -and $_.Class -eq 'USBDevice' } |
    Select-Object -First 1).InstanceId

# ---- native helpers (passive) ---------------------------------------------
if (-not ('TobiiNative' -as [type])) {
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class TobiiNative {
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("kernel32.dll")] static extern uint GetTickCount();
    public static uint IdleMs(){ var l=new LASTINPUTINFO(); l.cbSize=(uint)Marshal.SizeOf(l); GetLastInputInfo(ref l); return GetTickCount()-l.dwTime; }
    [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
}
"@
}
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# ---- sampling --------------------------------------------------------------
$script:prevCpu = @{}   # procName -> [TimeSpan] last TotalProcessorTime
$script:prevAt  = $null

function Get-EngineState {
    if (-not (Test-Path -LiteralPath $ServerLogPath)) { return @{ state=$null; ageSec=$null } }
    $age = $null
    try { $age = [int]((Get-Date) - (Get-Item -LiteralPath $ServerLogPath).LastWriteTime).TotalSeconds } catch {}
    $st = $null
    try { $m = Select-String -LiteralPath $ServerLogPath -Pattern 'Now in state (\w+)' -EA Stop | Select-Object -Last 1
          if ($m) { $st = $m.Matches[0].Groups[1].Value } } catch {}
    return @{ state=$st; ageSec=$age }
}
function Get-CpuPct([string]$name) {
    $p = Get-Process -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { $script:prevCpu.Remove($name); return @{ present=$false; cpu=$null; mem=$null; pid=$null } }
    $now = $p.TotalProcessorTime; $mem = [math]::Round($p.WorkingSet64/1MB,1); $cpu = $null
    if ($script:prevCpu.ContainsKey($name) -and $script:prevAt) {
        $secs = ((Get-Date) - $script:prevAt).TotalSeconds
        if ($secs -gt 0) { $cpu = [math]::Round(100*($now - $script:prevCpu[$name]).TotalSeconds/$secs, 1) }
    }
    $script:prevCpu[$name] = $now
    return @{ present=$true; cpu=$cpu; mem=$mem; pid=$p.Id }
}
function Get-Sample {
    $es = Get-EngineState
    $dev = Get-PnpDevice -InstanceId $DeviceInstId -ErrorAction SilentlyContinue
    $prob = $null
    if ($dev) { try { $prob = (Get-PnpDeviceProperty -InstanceId $DeviceInstId -KeyName 'DEVPKEY_Device_ProblemCode' -EA SilentlyContinue).Data } catch {} }
    $svcMw = (Get-Service 'Tobii Service' -EA SilentlyContinue).Status
    $svcRt = (Get-Service 'TobiiIS5YAMATO17' -EA SilentlyContinue).Status
    $eng = Get-CpuPct 'Tobii.EyeX.Engine'
    $rt  = Get-CpuPct 'platform_runtime_*'   # Tobii runtime svc exe (model-agnostic)
    $inter = [bool](Get-Process 'Tobii.EyeX.Interaction' -EA SilentlyContinue)
    $idle = [int]([TobiiNative]::IdleMs()/1000)
    $fs = -1; try { $s=0; [void][TobiiNative]::SHQueryUserNotificationState([ref]$s); $fs=$s } catch {}
    $ac = '?'; $batt = $null
    try { $ps=[System.Windows.Forms.SystemInformation]::PowerStatus; $ac="$($ps.PowerLineStatus)"; $batt=[math]::Round($ps.BatteryLifePercent*100) } catch {}
    $script:prevAt = Get-Date
    [ordered]@{
        ts     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        state  = $es.state
        logAge = $es.ageSec
        dev    = if ($dev) { "$($dev.Status)" } else { 'absent' }
        prob   = $prob
        svcMw  = "$svcMw"
        svcRt  = "$svcRt"
        engCpu = $eng.cpu
        engMem = $eng.mem
        rtCpu  = $rt.cpu
        inter  = $inter
        idle   = $idle
        fs     = $fs
        ac     = $ac
        batt   = $batt
        paused = (Test-Path $PauseFlag)
    }
}

function Write-Line($obj) {
    try {
        $dir = Split-Path $Telemetry -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        if ((Test-Path $Telemetry) -and (Get-Item $Telemetry).Length -ge $MaxTelemetryBytes) {
            $arch = Join-Path $dir ("Tobii-Telemetry-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".jsonl")
            Move-Item -LiteralPath $Telemetry -Destination $arch -Force -EA SilentlyContinue
        }
        ($obj | ConvertTo-Json -Compress) | Add-Content -LiteralPath $Telemetry -Encoding UTF8
    } catch {}
}

function Write-Snapshot($reason) {
    try {
        if (-not (Test-Path $SnapshotDir)) { New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null }
        $f = Join-Path $SnapshotDir ("snap-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$reason.txt")
        $o = @()
        $o += "=== Tobii snapshot ($reason) $(Get-Date) ==="
        $o += "Sample: " + ((Get-Sample) | ConvertTo-Json -Compress)
        $o += "--- device ---"
        $o += (Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_2104|TOBIIHID' } | Format-Table Status,Class,FriendlyName -Auto | Out-String)
        $o += "--- services ---"
        $o += (Get-Service 'Tobii Service','TobiiIS5YAMATO17' -EA SilentlyContinue | Format-Table Name,Status -Auto | Out-String)
        $o += "--- processes ---"
        $o += (Get-Process -EA SilentlyContinue | Where-Object {$_.Name -match 'Tobii|EyeX'} | Format-Table Name,Id,@{n='MB';e={[math]::Round($_.WorkingSet64/1MB)}} -Auto | Out-String)
        $o += "--- last 40 ServerLog lines ---"
        $o += (Get-Content -LiteralPath $ServerLogPath -Tail 40 -EA SilentlyContinue | Where-Object {$_ -match '\S'})
        $o += "--- System USB/PnP/power events (last 5 min) ---"
        try {
            Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddMinutes(-5)} -EA Stop |
              Where-Object { $_.ProviderName -match 'PnP|USB|Power' } |
              Select-Object -First 12 TimeCreated,Id,ProviderName | ForEach-Object { $o += ("  {0} {1} {2}" -f $_.TimeCreated,$_.Id,$_.ProviderName) }
        } catch { $o += "  (event query skipped)" }
        $o -join "`r`n" | Set-Content -LiteralPath $f -Encoding UTF8
    } catch {}
}

# ---- -Once -----------------------------------------------------------------
if ($Once) { (Get-Sample) | ConvertTo-Json; exit 0 }

# ---- -Stats ----------------------------------------------------------------
if ($Stats) {
    if (-not (Test-Path $Telemetry)) { "No telemetry yet at $Telemetry"; exit 0 }
    $rows = Get-Content $Telemetry | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_ }
    if (-not $rows) { "No parseable telemetry."; exit 0 }
    $first=[datetime]$rows[0].ts; $last=[datetime]$rows[-1].ts
    $span=($last-$first).TotalHours
    $drops = @($rows | Where-Object { $_.evt -eq 'drop' })
    $recs  = @($rows | Where-Object { $_.evt -eq 'recovered' })
    $outages = $recs | Where-Object { $_.outageSec } | ForEach-Object { [double]$_.outageSec }
    "===== Tobii health report ====="
    "window        : {0}  ->  {1}  ({2:N1} h)" -f $first,$last,$span
    "samples       : {0}" -f $rows.Count
    "drops         : {0}  ({1:N2}/hr)" -f $drops.Count, $(if($span){$drops.Count/$span}else{0})
    "recoveries    : {0}" -f $recs.Count
    if ($drops.Count) { "MTBF          : {0:N1} min between drops" -f $(if($drops.Count){($span*60)/$drops.Count}else{0}) }
    if ($outages)     { "outage sec    : min={0} median={1} max={2} mean={3:N1}" -f ($outages|Measure-Object -Min).Minimum, ($outages|Sort-Object)[[int]($outages.Count/2)], ($outages|Measure-Object -Max).Maximum, ($outages|Measure-Object -Average).Average }
    $stateCounts = $rows | Group-Object state | Sort-Object Count -Descending
    "state distrib :"; $stateCounts | ForEach-Object { "   {0,-18} {1,5}  ({2:N1}%)" -f $_.Name,$_.Count,(100*$_.Count/$rows.Count) }
    $lastDrop = $drops | Select-Object -Last 1
    if ($lastDrop) { "last drop     : {0} ({1:N1} h ago)" -f $lastDrop.ts, (($last-[datetime]$lastDrop.ts).TotalHours) }
    "current       : state={0} dev={1} paused={2}" -f $rows[-1].state,$rows[-1].dev,$rows[-1].paused
    exit 0
}

# ---- single-instance guard -------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\TobiiMonitorSingleton', [ref]$createdNew)
if (-not $createdNew) { exit 0 }   # another monitor already running

# ---- sampling loop ---------------------------------------------------------
# A "drop" is only a genuine connection loss (WaitingForDevice). Transient/setup
# states like Configuring (calibration) are NOT drops -- counting them inflated the
# stats and made calibration look like an outage.
$prevFault = $false; $dropAt = $null
Get-Sample | Out-Null    # prime CPU deltas
Start-Sleep -Seconds 2
while ($true) {
    try {
        $s = Get-Sample
        $isFault = ($s.state -eq 'WaitingForDevice')
        if (-not $prevFault -and $isFault) {
            $s.evt = 'drop'; $dropAt = Get-Date
            Write-Snapshot 'drop'
        } elseif ($prevFault -and -not $isFault -and $dropAt) {
            $s.evt = 'recovered'; $s.outageSec = [int]((Get-Date)-$dropAt).TotalSeconds; $dropAt = $null
        }
        Write-Line $s
        $prevFault = $isFault
    } catch { }
    Start-Sleep -Seconds $SampleSec
}
