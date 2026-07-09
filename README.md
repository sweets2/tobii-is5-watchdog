# Tobii IS5 Eye Tracker Watchdog (Alienware m17 R2)

Keeps the integrated **Tobii IS5 eye tracker** alive on laptops where it drops out
"after a few minutes to an hour" and stops tracking until something restarts the
Tobii software. Built and tested on an **Alienware m17 R2**, but the failure is in
Tobii's software stack (not the specific unit), so it should apply to other machines
with the same integrated tracker (USB `VID_2104&PID_030C`, the legacy "Tobii Eye
Tracking for Windows" / EyeX stack).

If you've fought the Alienware eye tracker dying every ~hour for years: this is a
watchdog that detects the drop and auto-reconnects, plus a tray app with a manual
"Reconnect now" button and passive telemetry so you can see what's happening.

> **Status:** working daily-driver tooling, not a polished product. PowerShell +
> a tray utility. See [`FINDINGS.md`](FINDINGS.md) for the full technical
> investigation and root-cause analysis.

## The problem (root cause)

The Tobii **EyeX engine** repeatedly loses its internal "PRP" connection to the
low-level **Tobii Runtime Service**, drops into the `WaitingForDevice` state, and
suspends tracking. The USB device reports **"OK" in Device Manager the whole time**
— which is why years of hardware/USB-reset attempts never found it. Windows logs
show no USB disconnect, no PnP removal, and no power event at the failure times.
It's a bug in Tobii's closed-source stack for this legacy/integrated product, so it
can't be patched — a supervisor that forces a reconnect is the pragmatic fix.

Full evidence, quantified logs, and the five distinct failure modes (A–E) are in
[`FINDINGS.md`](FINDINGS.md).

## What's included

| Component | Role |
|---|---|
| `Tobii-Watchdog.ps1` | Passive watchdog. Reads the engine's `ServerLog.txt` (never touches the gaze stream) and auto-recovers when it's stuck in `WaitingForDevice`. Also checks the stack is actually *running* (service + engine process), so a crash or dirty cold boot can't hide behind a stale "Tracking" log line — and catches the **silent stall** where the engine *claims* Tracking but does no gaze work (near-zero CPU while you're actively at the machine). |
| `Tobii-Tray.ps1` / `.vbs` | System-tray app: **Reconnect now**, **Fix cursor warp**, **Recalibrate now**, Pause/Resume auto-recovery, auto-pause in fullscreen games, Health report, Recent disconnects. Instant reconnect on sleep/resume, power-source, and display changes. Turns **red + notifies you** when the watchdog determines a recalibration is needed. |
| `Tobii-Monitor.ps1` | Passive telemetry recorder (observe-only): logs drops/recoveries + snapshots to help diagnose. `-Stats` prints MTBF / drops-per-hour / outage lengths. |
| `Tobii-CalReapply.cs` → `.exe` | The **Mode-D fix**: re-pushes the tracker's *stored* calibration to the live engine after a hibernate-resume — **no restart, no recalibration dots**. Uses the safe engine-IPC path (`Tobii.Interaction`), never a raw gaze stream. Compiled by the installer with the built-in .NET compiler. |
| `Install-TobiiWatchdog.ps1` | Registers the scheduled tasks + tray autostart, disables USB selective suspend for the device, and builds `Tobii-CalReapply.exe`. |
| `Uninstall-TobiiWatchdog.ps1` | Removes everything. |

## Install

**Easiest — one click:**
1. Download this repo (green **Code** button → **Download ZIP**) and unzip it anywhere.
2. Double-click **`Install.bat`** → approve the admin prompt.
   It copies the tool into `C:\Scripts`, sets everything up, and starts it.
3. A **green dot** appears in your system tray. Done — it runs at every logon.

**To remove:** double-click **`Uninstall.bat`**.

<details>
<summary>Manual install (PowerShell)</summary>

Put the files in `C:\Scripts`, then in an **elevated PowerShell**:
```powershell
powershell -ExecutionPolicy Bypass -File "C:\Scripts\Install-TobiiWatchdog.ps1"
```
Uninstall: `powershell -ExecutionPolicy Bypass -File "C:\Scripts\Uninstall-TobiiWatchdog.ps1"`
</details>

## How it works / what it catches

- **Auto-recovers all *connection-drop* outages** (`WaitingForDevice`) from any
  trigger — sleep, AC/battery change, display change, heavy load, or the random
  PRP bug. Recovery escalates: restart runtime service → recycle the EyeX engine +
  services → **re-enumerate the tracker's own USB port**. That last step recovers a
  tracker that hung mid-enumeration and fell *off the USB bus* — common after a
  hibernate/sleep resume, where it re-appears as a generic "Device Descriptor
  Request Failed" node — **without a reboot**. It touches only the tracker's own port
  (never the shared hub/keyboard) and verifies the device ends *enabled*, so it's safe
  to run automatically. If even a port re-enumeration can't bring the device back, the
  watchdog stops thrashing and raises a **"reboot needed"** tray notification (a
  firmware/hardware wedge only a reboot clears). A *blanket* USB power-cycle stays
  manual-only (`Reconnect now`) — it once left the device disabled.
- **Auto-recovers a dead stack** — if the Tobii service or engine process is
  missing (crash, or a cold boot after the battery died in sleep), that's a fault
  too, with a post-boot grace so it never fights the service's delayed autostart.
- **Prevents the "cursor warp dead" wedge (Mode E):** after every full recovery it
  waits for the engine to report a *fresh* `Tracking`, then bounces
  `Tobii.EyeX.Interaction` so its touchpad (PTP) session binds against a live
  engine. If gaze works but warp is dead anyway, the tray's **Fix cursor warp**
  restarts just that process — no full reconnect, no recalibration risk.
- **Auto-fixes lost calibration after hibernate (Mode D) — no recalibration:**
  the engine can claim `Tracking` while doing no gaze work at all (seen live: 22
  minutes at ~0.3% CPU; healthy tracking runs ~8–13%; the IR LEDs go dark). This
  is the classic hibernate-resume failure: the tracker's calibration is volatile
  firmware state, wiped when hibernate cuts its power, and no restart re-binds it.
  The watchdog samples engine CPU while you're *actively giving input* (still
  fully passive, no gaze subscription) and, on a confirmed stall, **re-applies
  your *stored* calibration to the engine** (`Tobii-CalReapply.exe`) — the same
  thing the calibration UI does, minus the dots — in about a second, with no
  restart. This runs first (it's cheap and non-disruptive); only if it *and* the
  full restart/USB-power-cycle ladder fail to bring gaze back (e.g. no stored
  calibration exists) does the tray go **red** and ask you to recalibrate. On
  resume it also fires immediately, so gaze is back the moment you sit down.
  There's a manual **"Re-apply saved calibration"** tray item too.
- **Safe by design:** it only *reads* the log, only acts on genuine fault
  states, and never intervenes during calibration.
- **What it can't auto-fix:** a *first-time* or genuinely corrupt calibration —
  if no valid calibration was ever stored, there's nothing to re-apply and you
  must do the dots once (it detects and notifies). And the rare "streaming but
  invalid gaze" freeze, which has no passive signature while the user is away;
  detecting that would need a gaze-stream subscription — which **breaks this
  hardware** (see FINDINGS §6). Don't do it. (Ordinary hibernate calibration
  loss is now auto-fixed by the re-apply above — no dots needed.)

## Compatibility

- Confirmed: **Alienware m17 R2**, Windows 10 22H2, integrated Tobii IS5
  (`VID_2104&PID_030C`), "Tobii Eye Tracking for Windows" 4.8 stack.
- Likely works on other Alienware/laptop models with the same integrated Tobii
  EyeX/IS-series tracker. The scripts **auto-detect** the device (by Tobii's USB
  VID) and the Tobii services/processes by pattern, so there are no hardcoded
  per-unit serials. Please open an issue with your model if you try it.

## Caveats

- Windows only; PowerShell 5.1 (built in). Some actions need admin (the installer
  self-elevates).
- Recovery restarts the Tobii services/engine (a ~10s blip); it never reboots the
  PC or closes your other apps.
- Provided as-is under the MIT license. It restarts vendor services and power-cycles
  a USB device; read the scripts before running.

## Contributing

Issues and PRs welcome — especially confirmations/fixes for other Alienware models,
and any progress on the failure modes that currently need a manual reconnect.
