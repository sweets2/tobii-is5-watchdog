# CyclePort.ps1 - USB-protocol-level port recovery for the Tobii IS5 tracker.
# Run via CyclePort.bat (self-elevating). ASCII only.
# Bypasses the PnP configuration manager entirely (which is poisoned by a
# reboot-pending flag): talks straight to the USB hub driver with
# IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX (electrical port status) and
# IOCTL_USB_HUB_CYCLE_PORT (protocol-level port reset + re-enumeration).

$ErrorActionPreference = 'Continue'
$log = 'C:\Scripts\cycleport-log.txt'
function Log([string]$m) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $m
  Add-Content -Path $log -Value $line
  Write-Output $line
}
Set-Content -Path $log -Value ''

$idn = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($idn)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Log 'NOT ELEVATED - aborting.'; exit 1 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class UsbHubIo {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr sa, uint dwCreationDisposition, uint dwFlags, IntPtr hTemplate);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr overlapped);
    const uint IOCTL_USB_GET_NODE_INFORMATION = 0x220408;
    const uint IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX = 0x220448;
    const uint IOCTL_USB_HUB_CYCLE_PORT = 0x220444;
    public static SafeFileHandle OpenHub(string path) {
        SafeFileHandle h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return h;
    }
    public static int PortCount(SafeFileHandle h) {
        byte[] buf = new byte[128]; int ret;
        if (!DeviceIoControl(h, IOCTL_USB_GET_NODE_INFORMATION, buf, buf.Length, buf, buf.Length, out ret, IntPtr.Zero)) return -1;
        return buf[6];
    }
    // returns raw connection-info buffer for a port, or null on failure
    public static byte[] ConnInfo(SafeFileHandle h, int port) {
        byte[] buf = new byte[2048]; int ret;
        BitConverter.GetBytes(port).CopyTo(buf, 0);
        if (!DeviceIoControl(h, IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX, buf, buf.Length, buf, buf.Length, out ret, IntPtr.Zero)) return null;
        return buf;
    }
    // returns 0 on success, else win32 error; statusReturned out
    public static int CyclePort(SafeFileHandle h, int port, out int statusReturned) {
        byte[] buf = new byte[8]; int ret; statusReturned = 0;
        BitConverter.GetBytes(port).CopyTo(buf, 0);
        if (!DeviceIoControl(h, IOCTL_USB_HUB_CYCLE_PORT, buf, 8, buf, 8, out ret, IntPtr.Zero)) return Marshal.GetLastWin32Error();
        statusReturned = BitConverter.ToInt32(buf, 4);
        return 0;
    }
}
'@

$STATUS = @('NoDevice','Connected','FailedEnum','GeneralFailure','Overcurrent','NotEnoughPower','NotEnoughBandwidth','NestedTooDeep','LegacyHub','Enumerating','Reset')
function Decode-Conn([byte[]]$buf) {
  # USB_NODE_CONNECTION_INFORMATION_EX: ConnectionIndex(0), DeviceDescriptor(4..21),
  # then cfg/speed/ishub/addr/pipes, ConnectionStatus at 32 (natural align) or 31 (packed).
  $vid = [BitConverter]::ToUInt16($buf, 12)   # idVendor within device descriptor (4+8)
  $pid2 = [BitConverter]::ToUInt16($buf, 14)
  $st = [BitConverter]::ToInt32($buf, 32)
  if ($st -lt 0 -or $st -gt 10) { $st = [BitConverter]::ToInt32($buf, 31) }
  if ($st -lt 0 -or $st -gt 10) { $st = [BitConverter]::ToInt32($buf, 28) }
  $name = if ($st -ge 0 -and $st -le 10) { $STATUS[$st] } else { "raw:$st" }
  return @{ Status = $st; Name = $name; Vid = $vid; Pid = $pid2 }
}

# Build candidate hub interface paths from every USB hub devnode that still exists,
# plus the tracker's (possibly devnode-less) parent hub, whose interface may still
# be alive because its removal was only DEFERRED to reboot.
$GUID = '{f18a0e88-c30c-11d0-8815-00a0c906bed8}'
$hubIds = New-Object System.Collections.Generic.List[string]
$hubIds.Add('USB\ROOT_HUB30\4&91c6074&0&0')  # tracker's parent (deferred-removed)
Get-PnpDevice -Class USB -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Hub' } | ForEach-Object { $hubIds.Add($_.InstanceId) }

$targets = @()   # hubs we can open: @{Path=..;Handle=..;Id=..;Ports=..}
foreach ($id in ($hubIds | Select-Object -Unique)) {
  $path = '\\?\' + ($id -replace '\\', '#') + '#' + $GUID
  try {
    $h = [UsbHubIo]::OpenHub($path)
    $n = [UsbHubIo]::PortCount($h)
    if ($n -le 0 -or $n -gt 30) { $n = 16 }
    Log ("OPENED hub " + $id + "  ports=" + $n)
    $targets += @{ Handle = $h; Id = $id; Ports = $n }
  } catch {
    Log ("cannot open hub " + $id + " -> " + $_.Exception.Message)
  }
}
if (-not $targets) { Log 'No hub interface could be opened. Nothing to cycle at this layer.'; exit 2 }

# Electrical survey of every port on every openable hub.
$candidates = @()
foreach ($t in $targets) {
  for ($p = 1; $p -le $t.Ports; $p++) {
    $buf = [UsbHubIo]::ConnInfo($t.Handle, $p)
    if ($null -eq $buf) { continue }
    $d = Decode-Conn $buf
    if ($d.Status -ne 0) {
      Log ("  hub " + $t.Id + " port " + $p + ": " + $d.Name + "  vid=0x" + $d.Vid.ToString('X4') + " pid=0x" + $d.Pid.ToString('X4'))
    }
    $isTobii = ($d.Vid -eq 0x2104)
    $isSick  = ($d.Status -ge 2 -and $d.Status -le 4) -or ($d.Status -eq 10)
    # port 9 of the tracker's own hub is the known location - always a candidate
    $isKnownPort = ($t.Id -match '4&91c6074' -and $p -eq 9)
    if ($isSick -or $isTobii -or $isKnownPort) {
      $candidates += @{ Hub = $t; Port = $p; Why = $(if($isSick){'sick:'+$d.Name}elseif($isTobii){'tobii-vid'}else{'known-port'}) }
    }
  }
}

if (-not $candidates) {
  Log 'SURVEY RESULT: no port shows a failed/tobii device electrically. The tracker is not answering the hub at all (device truly powered-wedged).'
} else {
  foreach ($c in $candidates) {
    Log ("CYCLING hub " + $c.Hub.Id + " port " + $c.Port + " (" + $c.Why + ") ...")
    $sr = 0
    $err = [UsbHubIo]::CyclePort($c.Hub.Handle, $c.Port, [ref]$sr)
    if ($err -eq 0) { Log ("  cycle OK, statusReturned=" + $sr) } else { Log ("  cycle FAILED win32err=" + $err) }
  }
  Start-Sleep 5
  & C:\Windows\System32\pnputil.exe /scan-devices | Out-Null
  Start-Sleep 10
  # re-survey the cycled ports + check devnode
  foreach ($c in $candidates) {
    $buf = [UsbHubIo]::ConnInfo($c.Hub.Handle, $c.Port)
    if ($buf) { $d = Decode-Conn $buf; Log ("  after: hub port " + $c.Port + " = " + $d.Name + " vid=0x" + $d.Vid.ToString('X4')) }
  }
  $ok = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_2104&PID_030C' -and $_.Status -eq 'OK' }
  if ($ok) {
    Log 'TRACKER IS BACK. Restarting Tobii stack...'
    Restart-Service -Name 'Tobii Service' -Force -ErrorAction SilentlyContinue
    Restart-Service -Name 'TobiiIS5YAMATO17' -Force -ErrorAction SilentlyContinue
    Remove-Item 'C:\Scripts\tobii-reboot-needed.flag' -Force -ErrorAction SilentlyContinue
    Log 'DONE - recovered at the USB protocol layer.'
  } else {
    Log 'DONE - port cycled but tracker did not re-enumerate.'
  }
}
foreach ($t in $targets) { $t.Handle.Close() }
