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
| `Install-TobiiWatchdog.ps1` | Registers the scheduled tasks + tray autostart, and disables USB selective suspend for the device. |
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
  services → (manual only) USB power-cycle.
- **Auto-recovers a dead stack** — if the Tobii service or engine process is
  missing (crash, or a cold boot after the battery died in sleep), that's a fault
  too, with a post-boot grace so it never fights the service's delayed autostart.
- **Prevents the "cursor warp dead" wedge (Mode E):** after every full recovery it
  waits for the engine to report a *fresh* `Tracking`, then bounces
  `Tobii.EyeX.Interaction` so its touchpad (PTP) session binds against a live
  engine. If gaze works but warp is dead anyway, the tray's **Fix cursor warp**
  restarts just that process — no full reconnect, no recalibration risk.
- **Catches the "Tracking" lie (silent stall / lost calibration):** the engine
  can claim `Tracking` while doing no gaze work at all (seen live: 22 minutes at
  ~0.3% CPU after the device came back without usable calibration; healthy
  tracking runs ~8–13%). The watchdog samples engine CPU while you're *actively
  giving input* (so it should be seeing your eyes) — still fully passive, no
  gaze subscription. On a confirmed stall it runs the ladder (stack restart →
  USB power-cycle reconnect), verifying each step by actual CPU; if nothing
  brings gaze back it's calibration loss, so the tray goes **red**, notifies
  you, and one click opens the Tobii calibration app. The flag self-clears when
  you recalibrate.
- **Safe by design:** it only *reads* the log, only acts on genuine fault
  states, and never intervenes during calibration.
- **What it can't auto-fix:** the recalibration itself (needs your eyes on the
  calibration dots — it detects and notifies instead), and the rare "streaming
  but invalid gaze" freeze, which has no passive signature while the user is
  away. Detecting that would need a gaze-stream subscription — which **breaks
  this hardware** (see FINDINGS §6). Don't do it.

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
