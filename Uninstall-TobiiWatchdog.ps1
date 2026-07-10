<#
    uninstall-tobii-watchdog.ps1
    Removes the TobiiWatchdog scheduled task. Run as Administrator.
    (Leaves the USB power-management tweaks in place; they are harmless.)
#>
[CmdletBinding()] param()
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    exit
}
foreach ($t in 'TobiiWatchdog','TobiiWatchdog-OnWake','TobiiReconnect','TobiiFixWarp','TobiiMonitor','TobiiSentinel') {
    Stop-ScheduledTask       -TaskName $t -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "removed scheduled task: $t" -ForegroundColor Green
}
# Tray utility: stop it, remove autostart + flag.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'Tobii-Tray\.ps1|Tobii-Monitor\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'TobiiTray' -ErrorAction SilentlyContinue
Remove-Item 'C:\Scripts\watchdog.pause' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Scripts\tobii-recal-needed.flag' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Scripts\tobii-reboot-needed.flag' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Scripts\tobii-recovering.flag' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Scripts\tobii-watchdog.heartbeat.json' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Scripts\tobii-monitor.heartbeat.json' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Scripts\tobii-recovery-state.json' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Scripts\tobii-force-reconnect.request' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Scripts\Tobii-CalReapply.exe' -Force -ErrorAction SilentlyContinue
Write-Host "removed tray autostart + pause/recal flags + calibration helper" -ForegroundColor Green
