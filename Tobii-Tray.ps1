<#
    Tobii-Tray.ps1  - system-tray control for the Tobii watchdog.
    Left-click the tray icon = Pause/Resume.  Right-click = menu.
    Icon: green = active, gray = paused (manual), orange = auto-paused (game).

    It controls the watchdog purely by creating/removing a flag file
    (C:\Scripts\watchdog.pause). No admin needed. Settings persist to
    C:\Scripts\tray.settings.json.
#>
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeShell {
    [DllImport("shell32.dll")]
    public static extern int SHQueryUserNotificationState(out int state);
}
"@

$ScriptsDir = 'C:\Scripts'
$PauseFlag  = Join-Path $ScriptsDir 'watchdog.pause'
$Settings   = Join-Path $ScriptsDir 'tray.settings.json'
$LogPath    = Join-Path $ScriptsDir 'Tobii-Watchdog.log'
$RecalFlag  = Join-Path $ScriptsDir 'tobii-recal-needed.flag'

$state = @{ mode = 'active'; autoGames = $false }
if (Test-Path $Settings) {
    try { $j = Get-Content $Settings -Raw | ConvertFrom-Json
          if ($j.mode) { $state.mode = "$($j.mode)" }
          $state.autoGames = [bool]$j.autoGames } catch {}
}
function Save-Settings {
    @{ mode = $state.mode; autoGames = $state.autoGames } | ConvertTo-Json |
        Set-Content -LiteralPath $Settings -Encoding UTF8
}

function Test-FullscreenGame {
    # QUNS_RUNNING_D3D_FULL_SCREEN = 3, QUNS_PRESENTATION_MODE = 4
    $s = 0
    try { [void][NativeShell]::SHQueryUserNotificationState([ref]$s) } catch { return $false }
    return ($s -eq 3 -or $s -eq 4)
}

function New-DotIcon($color) {
    $bmp = New-Object System.Drawing.Bitmap 16,16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $b = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($b, 2,2,12,12)
    $b.Dispose(); $g.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $ico
}
$icoActive = New-DotIcon ([System.Drawing.Color]::LimeGreen)
$icoPaused = New-DotIcon ([System.Drawing.Color]::Gray)
$icoGame   = New-DotIcon ([System.Drawing.Color]::Orange)
$icoRecal  = New-DotIcon ([System.Drawing.Color]::Red)

$ni   = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$ni.ContextMenuStrip = $menu

$miStatus    = New-Object System.Windows.Forms.ToolStripMenuItem "Status"
$miStatus.Enabled = $false
$miReconnect = New-Object System.Windows.Forms.ToolStripMenuItem "Reconnect now (fix a freeze)"
$miWarp      = New-Object System.Windows.Forms.ToolStripMenuItem "Fix cursor warp (gaze OK, warp dead)"
$miReapply   = New-Object System.Windows.Forms.ToolStripMenuItem "Re-apply saved calibration (no dots)"
$miRecal     = New-Object System.Windows.Forms.ToolStripMenuItem "Recalibrate now (open Tobii app)"
$miToggle    = New-Object System.Windows.Forms.ToolStripMenuItem "Pause auto-recovery"
$miAuto      = New-Object System.Windows.Forms.ToolStripMenuItem "Auto-pause in fullscreen games"
$miAuto.CheckOnClick = $true
$miAuto.Checked = [bool]$state.autoGames
$miDrops  = New-Object System.Windows.Forms.ToolStripMenuItem "Recent disconnects"
$miStats  = New-Object System.Windows.Forms.ToolStripMenuItem "Health report"
$miLog    = New-Object System.Windows.Forms.ToolStripMenuItem "Open log"
$miTelem  = New-Object System.Windows.Forms.ToolStripMenuItem "Open telemetry folder"
$miExit   = New-Object System.Windows.Forms.ToolStripMenuItem "Exit tray (watchdog keeps running)"
$sep1 = New-Object System.Windows.Forms.ToolStripSeparator
$sep2 = New-Object System.Windows.Forms.ToolStripSeparator
$sep3 = New-Object System.Windows.Forms.ToolStripSeparator
[void]$menu.Items.Add($miStatus)
[void]$menu.Items.Add($sep1)
[void]$menu.Items.Add($miReconnect)
[void]$menu.Items.Add($miWarp)
[void]$menu.Items.Add($miReapply)
[void]$menu.Items.Add($miRecal)
[void]$menu.Items.Add($sep2)
[void]$menu.Items.Add($miToggle)
[void]$menu.Items.Add($miAuto)
[void]$menu.Items.Add($sep3)
[void]$menu.Items.Add($miDrops)
[void]$menu.Items.Add($miStats)
[void]$menu.Items.Add($miLog)
[void]$menu.Items.Add($miTelem)
[void]$menu.Items.Add($miExit)

function Apply-State {
    $gameActive = $false
    if ($state.autoGames) { $gameActive = Test-FullscreenGame }
    $effPaused = ($state.mode -eq 'paused') -or $gameActive

    if ($effPaused) {
        if (-not (Test-Path $PauseFlag)) { New-Item -ItemType File -Path $PauseFlag -Force | Out-Null }
    } else {
        if (Test-Path $PauseFlag) { Remove-Item $PauseFlag -Force -ErrorAction SilentlyContinue }
    }

    $recalNeeded = Test-Path $RecalFlag
    if ($recalNeeded)               { $ni.Icon = $icoRecal;  $txt = 'RECALIBRATION NEEDED' }
    elseif ($state.mode -eq 'paused') { $ni.Icon = $icoPaused; $txt = 'Paused (manual)' }
    elseif ($gameActive)            { $ni.Icon = $icoGame;   $txt = 'Auto-paused (game)' }
    else                            { $ni.Icon = $icoActive; $txt = 'Active' }

    $ni.Text       = "Tobii Watchdog: $txt"
    $miStatus.Text = "Status: $txt"
    $miToggle.Text = if ($state.mode -eq 'paused') { 'Resume auto-recovery' } else { 'Pause auto-recovery' }
    $miAuto.Checked = [bool]$state.autoGames

    # The watchdog raises this flag when its whole recovery ladder failed and
    # the engine still tracks nothing: that is calibration loss (Mode D), which
    # only human eyes can fix. Nag once on appearance, then every 5 minutes.
    if ($recalNeeded) {
        if (((Get-Date) - $script:lastRecalNag).TotalMinutes -ge 5) {
            $script:lastRecalNag = Get-Date
            $ni.ShowBalloonTip(15000, 'Tobii: recalibration needed',
                'The eye tracker lost its calibration and auto-recovery could not fix it. Click here (or tray menu > Recalibrate now) to open the Tobii app and recalibrate.',
                [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    } else {
        $script:lastRecalNag = [datetime]::MinValue
    }
}

function Open-TobiiCalibration {
    # Opens the Tobii Experience (Store) app, which hosts the calibration UI.
    # Package family name is looked up live so nothing is hardcoded per-machine.
    try {
        $pkg = Get-AppxPackage -Name 'TobiiAB.TobiiEyeTrackingPortal' -ErrorAction Stop
        if ($pkg) {
            Start-Process explorer.exe "shell:AppsFolder\$($pkg.PackageFamilyName)!App"
            return
        }
    } catch { }
    # Fallback: legacy EyeX settings panel, if present.
    $legacy = 'C:\Program Files (x86)\Tobii\Tobii EyeX Config\Tobii.EyeXConfig.exe'
    if (Test-Path $legacy) { Start-Process $legacy; return }
    $ni.ShowBalloonTip(5000, 'Tobii', 'Could not find the Tobii calibration app. Open it from the Start menu.', [System.Windows.Forms.ToolTipIcon]::Warning)
}

function Invoke-CalReapplyNow {
    # Re-push the tracker's STORED calibration to the live engine (no restart, no
    # dots) -- the fix for a hibernate-resume that came up with tracking dead. Runs
    # as the logged-in user (this tray process), which is required to reach the engine.
    $exe = 'C:\Scripts\Tobii-CalReapply.exe'
    if (-not (Test-Path $exe)) {
        $ni.ShowBalloonTip(4000, 'Tobii', 'Re-apply tool not found. Re-run the installer.', [System.Windows.Forms.ToolTipIcon]::Warning); return
    }
    $ni.ShowBalloonTip(3000, 'Tobii', 'Re-applying your saved calibration (no dots)...', [System.Windows.Forms.ToolTipIcon]::Info)
    try {
        $p = Start-Process -FilePath $exe -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        if ($p.ExitCode -eq 0) {
            Remove-Item 'C:\Scripts\tobii-recal-needed.flag' -Force -ErrorAction SilentlyContinue
            Apply-State
            $ni.ShowBalloonTip(3000, 'Tobii', 'Saved calibration re-applied - tracking should be back.', [System.Windows.Forms.ToolTipIcon]::Info)
        } else {
            $ni.ShowBalloonTip(5000, 'Tobii', 'Could not re-apply the saved calibration - you may need to Recalibrate.', [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    } catch {
        $ni.ShowBalloonTip(4000, 'Tobii', 'Re-apply failed to start.', [System.Windows.Forms.ToolTipIcon]::Warning)
    }
}

function Invoke-ReconnectNow {
    # Fires the elevated on-demand task (no UAC prompt for the user).
    try {
        Start-ScheduledTask -TaskName 'TobiiReconnect' -ErrorAction Stop
        $ni.ShowBalloonTip(3000, 'Tobii', 'Reconnecting the eye tracker...', [System.Windows.Forms.ToolTipIcon]::Info)
    } catch {
        $ni.ShowBalloonTip(4000, 'Tobii', 'Reconnect task not found. Re-run the installer.', [System.Windows.Forms.ToolTipIcon]::Warning)
    }
}

function Toggle-Pause {
    $state.mode = if ($state.mode -eq 'paused') { 'active' } else { 'paused' }
    Save-Settings; Apply-State
}

function Show-Drops {
    $tel = 'C:\Scripts\Tobii-Telemetry.jsonl'
    $rows = @()
    if (Test-Path $tel) {
        $evts = Get-Content $tel -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
            Where-Object { $_.evt -eq 'drop' -or $_.evt -eq 'recovered' }
        foreach ($e in $evts) {
            $t = ($e.ts -replace 'T',' ')
            if ($e.evt -eq 'drop') {
                $rows += ("{0}   *** DISCONNECT ***   (on {1}{2})" -f $t, $e.ac, $(if($e.batt){" $($e.batt)% batt"}else{''}))
            } else {
                $rows += ("{0}   recovered after {1}s" -f $t, $e.outageSec)
            }
        }
    }
    $dropCount = ($rows | Where-Object { $_ -match 'DISCONNECT' }).Count
    if (-not $rows) { $rows = @('No disconnects recorded yet. (Good news!)') }
    [array]::Reverse($rows)   # newest first
    $header = "Recent Tobii disconnects  -  $dropCount total recorded (newest first)`r`n" + ('=' * 60)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Tobii - Recent disconnects'
    $form.Size = New-Object System.Drawing.Size(560,440)
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'
    $tb.Dock = 'Fill'; $tb.WordWrap = $false
    $tb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $tb.Text = $header + "`r`n" + ($rows -join "`r`n")
    $tb.Select(0,0)
    $form.Controls.Add($tb)
    [void]$form.ShowDialog()
    $form.Dispose()
}

$miDrops.add_Click({ Show-Drops })
$miReconnect.add_Click({ Invoke-ReconnectNow })
$miReapply.add_Click({ Invoke-CalReapplyNow })
$miWarp.add_Click({
    # Mode E: engine/gaze healthy but cursor warp dead (Experience tracks your
    # face fine, warp does nothing). Restarting the interaction process re-binds
    # its PTP session. Much gentler than a full reconnect.
    try {
        Start-ScheduledTask -TaskName 'TobiiFixWarp' -ErrorAction Stop
        $ni.ShowBalloonTip(3000, 'Tobii', 'Restarting the interaction process (cursor warp)...', [System.Windows.Forms.ToolTipIcon]::Info)
    } catch {
        $ni.ShowBalloonTip(4000, 'Tobii', 'FixWarp task not found. Re-run the installer.', [System.Windows.Forms.ToolTipIcon]::Warning)
    }
})
$miRecal.add_Click({ Open-TobiiCalibration })
$ni.add_BalloonTipClicked({ if (Test-Path $RecalFlag) { Open-TobiiCalibration } })
$miToggle.add_Click({ Toggle-Pause })
$miAuto.add_Click({ $state.autoGames = $miAuto.Checked; Save-Settings; Apply-State })
$miStats.add_Click({
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'C:\Scripts\Tobii-Monitor.ps1' -Stats 2>&1 | Out-String
        if (-not $out) { $out = 'No telemetry yet.' }
        [System.Windows.Forms.MessageBox]::Show($out, 'Tobii Health Report') | Out-Null
    } catch { [System.Windows.Forms.MessageBox]::Show("Couldn't run report: $($_.Exception.Message)", 'Tobii') | Out-Null }
})
$miLog.add_Click({ if (Test-Path $LogPath) { Start-Process notepad.exe $LogPath } })
$miTelem.add_Click({ Start-Process explorer.exe 'C:\Scripts' })
$miExit.add_Click({ $ni.Visible = $false; $ni.Dispose(); [System.Windows.Forms.Application]::Exit() })
$ni.add_MouseClick({ param($s,$e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Pause } })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.add_Tick({ Apply-State })   # refresh icon + re-check fullscreen when auto is on

$script:lastRecalNag = [datetime]::MinValue

# Instant reaction to power-source and display changes (event-driven, ~0 idle cost).
# Both funnel into the TobiiWatchdog-OnWake task, which only reconnects if the
# engine actually dropped (WaitingForDevice) and never during calibration.
$script:lastEventCheck = [datetime]::MinValue
function Fire-EventCheck {
    param([string]$why)
    if (((Get-Date) - $script:lastEventCheck).TotalSeconds -lt 25) { return }  # debounce bursts
    $script:lastEventCheck = Get-Date
    try { Start-ScheduledTask -TaskName 'TobiiWatchdog-OnWake' -ErrorAction SilentlyContinue } catch {}
}
[Microsoft.Win32.SystemEvents]::add_PowerModeChanged({
    param($s,$e)
    if ($e.Mode -eq [Microsoft.Win32.PowerModes]::StatusChange -or $e.Mode -eq [Microsoft.Win32.PowerModes]::Resume) { Fire-EventCheck 'power' }
})
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged({ Fire-EventCheck 'display' })

$ni.Visible = $true
Apply-State
$timer.Start()
[System.Windows.Forms.Application]::Run()

# Detach handlers on exit (avoids a leaked SystemEvents subscription).
[Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged({ Fire-EventCheck 'display' })
