<#
    install-tobii-watchdog.ps1
    --------------------------
    Installs the Tobii eye-tracker watchdog and applies the permanent
    USB power-management mitigations. MUST run elevated (as Administrator).

    It:
      1. Disables USB selective suspend for the Tobii device (VID_2104&PID_030C)
         and globally in the active power plan, so Windows stops parking the
         eye tracker to "save power".
      2. Registers a Scheduled Task "TobiiWatchdog" that runs tobii-watchdog.ps1
         at logon, elevated, and keeps it running (auto-restart on failure).
      3. Starts the task immediately.
#>
[CmdletBinding()]
param(
    [string]$ScriptDir = "$PSScriptRoot"
)

$ErrorActionPreference = 'Stop'
if (-not $ScriptDir) { $ScriptDir = 'C:\Scripts' }

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal]`
        [Security.Principal.WindowsIdentity]::GetCurrent()`
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "This installer must run as Administrator." -ForegroundColor Red
        Write-Host "Re-launching elevated..." -ForegroundColor Yellow
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",
            '-ScriptDir',"`"$ScriptDir`""
        )
        exit
    }
}
Assert-Admin

$watchdog = Join-Path $ScriptDir 'Tobii-Watchdog.ps1'
if (-not (Test-Path $watchdog)) { throw "Cannot find $watchdog" }
$hiddenRunner = Join-Path $ScriptDir 'Tobii-RunHidden.vbs'
if (-not (Test-Path $hiddenRunner)) { throw "Cannot find $hiddenRunner" }
$wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'

function New-HiddenPowerShellTaskAction {
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string]$ScriptArguments = ''
    )
    $runnerArgs = "`"$hiddenRunner`" `"$ScriptName`""
    if ($ScriptArguments) { $runnerArgs += " $ScriptArguments" }
    New-ScheduledTaskAction -Execute $wscriptExe -Argument $runnerArgs
}

Write-Host "== 1. Disabling USB power-saving for the Tobii device ==" -ForegroundColor Cyan

# Per-device selective suspend off + don't let it idle into D3.
$devKeys = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue |
             Where-Object { $_.PSChildName -match 'VID_2104&PID_030C' }
foreach ($k in $devKeys) {
    Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
        $dp = Join-Path $_.PSPath 'Device Parameters'
        if (-not (Test-Path $dp)) { New-Item -Path $dp -Force | Out-Null }
        New-ItemProperty -Path $dp -Name 'SelectiveSuspendEnabled'      -PropertyType DWord -Value 0 -Force | Out-Null
        New-ItemProperty -Path $dp -Name 'AllowIdleIrpInD3'             -PropertyType DWord -Value 0 -Force | Out-Null
        New-ItemProperty -Path $dp -Name 'EnhancedPowerManagementEnabled' -PropertyType DWord -Value 0 -Force | Out-Null
        Write-Host "   set SelectiveSuspendEnabled=0 on $($_.PSChildName)"
    }
}

# Global USB selective suspend off in the active power plan (AC + DC).
# Call powercfg by full path (PATH can be stripped in some elevated contexts)
# and never let a hiccup here abort the install.
try {
    $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    $USB_SUBGROUP = '2a737441-1930-4402-8d77-b2bebba308a3'
    $USB_SELSUS   = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
    & $powercfg /setacvalueindex SCHEME_CURRENT $USB_SUBGROUP $USB_SELSUS 0 | Out-Null
    & $powercfg /setdcvalueindex SCHEME_CURRENT $USB_SUBGROUP $USB_SELSUS 0 | Out-Null
    & $powercfg /S SCHEME_CURRENT | Out-Null
    Write-Host "   USB selective suspend disabled in active power plan."
} catch {
    Write-Host "   (skipped global powercfg tweak: $($_.Exception.Message))" -ForegroundColor Yellow
}

Write-Host "== 1b. Building the calibration re-apply helper (Mode-D auto-fix) ==" -ForegroundColor Cyan
# Tobii-CalReapply.exe re-pushes the stored calibration to the engine after a
# hibernate-resume (no restart, no dots). Compiled here against the local Tobii
# assemblies with the built-in .NET Framework compiler; x86 to match the SDK.
$calSrc   = Join-Path $ScriptDir 'Tobii-CalReapply.cs'
$calExe   = Join-Path $ScriptDir 'Tobii-CalReapply.exe'
$tobiiCfg = 'C:\Program Files (x86)\Tobii\Tobii Configuration'
$csc      = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if ((Test-Path $calSrc) -and (Test-Path $csc) -and (Test-Path $tobiiCfg)) {
    try {
        $refModel = Join-Path $tobiiCfg 'Tobii.Interaction.Model.dll'
        $refNet   = Join-Path $tobiiCfg 'Tobii.Interaction.Net.dll'
        & $csc /nologo /platform:x86 /target:exe /out:"$calExe" "/reference:$refModel" "/reference:$refNet" "$calSrc" 2>&1 | Out-Null
        if (Test-Path $calExe) { Write-Host "   built Tobii-CalReapply.exe." }
        else { Write-Host "   WARN: compile produced no exe; Mode-D auto-fix unavailable (recalibration still works)." -ForegroundColor Yellow }
    } catch {
        Write-Host "   WARN: could not build Tobii-CalReapply.exe: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "   (skipped: needs Tobii Configuration + csc.exe. Mode-D auto-fix unavailable; recalibration still works.)" -ForegroundColor Yellow
}

Write-Host "== 2. Registering scheduled task 'TobiiWatchdog' ==" -ForegroundColor Cyan

$taskName = 'TobiiWatchdog'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# WScript creates no console window. PowerShell's -WindowStyle Hidden is too late:
# conhost can briefly appear and steal focus before PowerShell processes that flag.
$action = New-HiddenPowerShellTaskAction -ScriptName 'Tobii-Watchdog.ps1'

# Run at logon of the current (interactive) user, with highest privileges so
# service restarts / USB power-cycles work. Running as the user (not SYSTEM)
# also means the watchdog can find that user's ServerLog.txt.
$user = "$env:USERDOMAIN\$env:USERNAME"
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Keeps the Tobii eye tracker alive by forcing a reconnect when it gets stuck.' | Out-Null
Write-Host "   registered '$taskName' (runs at logon as $user, elevated)."

Write-Host "== 2b. Registering wake task 'TobiiWatchdog-OnWake' ==" -ForegroundColor Cyan
$wakeName = 'TobiiWatchdog-OnWake'
Unregister-ScheduledTask -TaskName $wakeName -Confirm:$false -ErrorAction SilentlyContinue

$wakeAction = New-HiddenPowerShellTaskAction -ScriptName 'Tobii-Watchdog.ps1' -ScriptArguments '-OnWake'

# Fire on resume-from-sleep: System log, Power-Troubleshooter event ID 1
# ("the system has returned from a low power state").
$wakeTrigClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$wakeTrig = New-CimInstance -CimClass $wakeTrigClass -ClientOnly
$wakeTrig.Enabled = $true
$wakeTrig.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and (EventID=1)]]</Select></Query></QueryList>'

$wakeSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $wakeName -Action $wakeAction -Trigger $wakeTrig `
    -Principal $principal -Settings $wakeSettings `
    -Description 'Reconnects the Tobii eye tracker immediately after the PC wakes from sleep.' | Out-Null
Write-Host "   registered '$wakeName' (fires on resume from sleep, elevated)."

Write-Host "== 2d. Registering on-demand 'TobiiReconnect' task (tray button) ==" -ForegroundColor Cyan
$rcName = 'TobiiReconnect'
Unregister-ScheduledTask -TaskName $rcName -Confirm:$false -ErrorAction SilentlyContinue
$rcAction = New-HiddenPowerShellTaskAction -ScriptName 'Tobii-Watchdog.ps1' -ScriptArguments '-ForceReconnect'
$rcSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
# No trigger: it only runs when started on demand (by the tray). Runs elevated,
# so the non-admin tray can trigger a privileged reconnect without a UAC prompt.
Register-ScheduledTask -TaskName $rcName -Action $rcAction `
    -Principal $principal -Settings $rcSettings `
    -Description 'On-demand: force-reconnect the Tobii eye tracker (fired by the tray "Reconnect now").' | Out-Null
Write-Host "   registered '$rcName' (on-demand, elevated)."

Write-Host "== 2d2. Registering on-demand 'TobiiFixWarp' task (tray button) ==" -ForegroundColor Cyan
$fwName = 'TobiiFixWarp'
Unregister-ScheduledTask -TaskName $fwName -Confirm:$false -ErrorAction SilentlyContinue
$fwAction = New-HiddenPowerShellTaskAction -ScriptName 'Tobii-Watchdog.ps1' -ScriptArguments '-RestartInteraction'
$fwSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
# No trigger: on-demand only (tray "Fix cursor warp"). Restarts the interaction
# process to re-bind its PTP session (Mode E: gaze fine, cursor warp dead).
Register-ScheduledTask -TaskName $fwName -Action $fwAction `
    -Principal $principal -Settings $fwSettings `
    -Description 'On-demand: restart Tobii.EyeX.Interaction to fix a dead cursor warp (fired by the tray "Fix cursor warp").' | Out-Null
Write-Host "   registered '$fwName' (on-demand, elevated)."

Write-Host "== 2e. Registering passive 'TobiiMonitor' task (telemetry, non-elevated) ==" -ForegroundColor Cyan
$monitor = Join-Path $ScriptDir 'Tobii-Monitor.ps1'
$monName = 'TobiiMonitor'
if (Test-Path $monitor) {
    Unregister-ScheduledTask -TaskName $monName -Confirm:$false -ErrorAction SilentlyContinue
    $monAction = New-HiddenPowerShellTaskAction -ScriptName 'Tobii-Monitor.ps1'
    $monTrigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    # Non-elevated (Limited): it only reads state, never touches the device.
    $monPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $monSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $monName -Action $monAction -Trigger $monTrigger `
        -Principal $monPrincipal -Settings $monSettings `
        -Description 'Passive telemetry recorder for the Tobii eye tracker (observe-only, never touches the device).' | Out-Null
    Start-ScheduledTask -TaskName $monName -ErrorAction SilentlyContinue
    Write-Host "   registered + started '$monName' (logon, non-elevated, observe-only)."
} else {
    Write-Host "   (Tobii-Monitor.ps1 not found; skipping monitor)" -ForegroundColor Yellow
}

Write-Host "== 2f. Registering watchdog/monitor sentinel ==" -ForegroundColor Cyan
$sentinel = Join-Path $ScriptDir 'Tobii-Sentinel.ps1'
$sentinelName = 'TobiiSentinel'
if (Test-Path $sentinel) {
    Unregister-ScheduledTask -TaskName $sentinelName -Confirm:$false -ErrorAction SilentlyContinue
    $sentinelAction = New-HiddenPowerShellTaskAction -ScriptName 'Tobii-Sentinel.ps1'
    $sentinelTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    $sentinelSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $sentinelName -Action $sentinelAction -Trigger $sentinelTrigger `
        -Principal $principal -Settings $sentinelSettings `
        -Description 'Restarts the Tobii watchdog or passive monitor if their heartbeat becomes stale.' | Out-Null
    Start-ScheduledTask -TaskName $sentinelName -ErrorAction SilentlyContinue
    Write-Host "   registered + started '$sentinelName' (one-minute heartbeat supervision)."
} else {
    Write-Host "   (Tobii-Sentinel.ps1 not found; skipping process supervision)" -ForegroundColor Yellow
}

Write-Host "== 2c. Registering the tray utility to start at logon ==" -ForegroundColor Cyan
$trayVbs = Join-Path $ScriptDir 'Tobii-Tray.vbs'
if (Test-Path $trayVbs) {
    # Per-user autostart (HKCU Run). The tray needs no admin; it runs in the
    # user session and controls the watchdog via the pause flag file.
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-ItemProperty -Path $runKey -Name 'TobiiTray' `
        -Value ("wscript.exe `"$trayVbs`"") -PropertyType String -Force | Out-Null
    Write-Host "   tray will start at logon (HKCU Run: TobiiTray)."
} else {
    Write-Host "   (Tobii-Tray.vbs not found; skipping tray autostart)" -ForegroundColor Yellow
}

Write-Host "== 3. Starting the watchdog now ==" -ForegroundColor Cyan
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
Get-ScheduledTask | Where-Object { $_.TaskName -match 'Tobii' } | Select-Object TaskName,State | Format-Table -AutoSize

$logPath = 'C:\Scripts\Tobii-Watchdog.log'
Write-Host ""
Write-Host "Done. Watchdog log: $logPath" -ForegroundColor Green
Write-Host "Tail it with:  Get-Content `"$logPath`" -Wait" -ForegroundColor Green
