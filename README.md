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
| `Tobii-Watchdog.ps1` | Passive watchdog. Reads the engine log and process load (never the gaze stream), serializes every recovery request through one coordinator, and runs a bounded recovery state machine. It learns a healthy CPU baseline and catches both near-zero and 4–6% half-alive stalls, including a conservative quiet-user path. |
| `Tobii-Tray.ps1` / `.vbs` | System-tray app: **Reconnect now**, **Fix cursor warp**, **Recalibrate now**, manual **Sleep/wake tracker**, Pause/Resume, Health report, and Recent disconnects. Green now requires an OK, present EyeChip; blue reports a missing device or active recovery, and gray reports a stale watchdog heartbeat. |
| `Tobii-Monitor.ps1` | Passive telemetry recorder (observe-only): logs typed incidents/recoveries + snapshots, watchdog recovery phase, and gap-aware statistics. |
| `Tobii-Sentinel.ps1` | Supervises the watchdog and telemetry heartbeat files and restarts those processes if they hang. It never touches the Tobii stack or machine power. |
| `Tobii-CalReapply.cs` → `.exe` | The **Mode-D fix**: re-pushes the tracker's *stored* calibration to the live engine after a hibernate-resume — **no restart, no recalibration dots**. Uses the safe engine-IPC path (`Tobii.Interaction`), never a raw gaze stream. Compiled by the installer with the built-in .NET compiler. |
| `Install-TobiiWatchdog.ps1` | Registers no-console scheduled tasks through `Tobii-RunHidden.vbs`, configures tray autostart, disables USB selective suspend, and builds `Tobii-CalReapply.exe`. |
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
  watchdog stops thrashing and raises a **manual sleep/wake needed** notification.
  On this machine a short owner-initiated S3 cycle restores the electrically absent
  tracker; the watchdog never sleeps or reboots the PC itself.
- **Catches PnP failures even when EyeX says `unknown`.** USB presence is checked
  independently on every loop, and a present `Tobii Device` with Code 10 triggers
  an immediate clean-stack rebuild. A live `VID_0000&PID_0002` Code 43 node is
  matched to EyeChip by PnP parent and location. USB recovery is bounded to two
  passes: restart the current representation, rescan, then restart one late Code 43
  node if the first pass created it. It never loops or touches the shared hub.
- **Auto-recovers a dead stack** — if the Tobii service or engine process is
  missing (crash, or a cold boot after the battery died in sleep), that's a fault
  too, with a post-boot grace so it never fights the service's delayed autostart.
- **Prevents the "cursor warp dead" wedge (Mode E):** after every recovery and
  once after watchdog startup, resume, or unlock, it waits for `Tracking`, then
  quietly bounces `Tobii.EyeX.Interaction` so its touchpad (PTP) session binds against a live
  engine. If gaze works but warp is dead anyway, the tray's **Fix cursor warp**
  restarts just that process — no full reconnect, no recalibration risk.
- **Auto-fixes lost calibration after hibernate (Mode D) — no recalibration:**
  the engine can claim `Tracking` while doing no gaze work at all (seen live: 22
  minutes at ~0.3% CPU; healthy tracking runs ~8–13%; the IR LEDs go dark). This
  is the classic hibernate-resume failure: the tracker's calibration is volatile
  firmware state, wiped when hibernate cuts its power, and no restart re-binds it.
  The watchdog compares engine CPU with a learned healthy baseline. It has a fast
  user-active path plus a slower quiet-session path, because dead gaze can itself
  stop conventional input. On a confirmed stall it **re-applies
  your *stored* calibration to the engine** (`Tobii-CalReapply.exe`) — the same
  thing the calibration UI does, minus the dots — in about a second, with no
  restart. This runs first (it's cheap and non-disruptive); only if it *and* the
  clean restart/port-re-enumeration ladder fail to bring gaze back does it classify
  the terminal state: failed calibration becomes **red/recalibrate**, while a
  successfully calibrated but still degraded imaging session becomes
  **orange/manual sleep**. On
  resume it also fires immediately, so gaze is back the moment you sit down.
  There's a manual **"Re-apply saved calibration"** tray item too.
- **Safe by design:** it never subscribes to gaze, never intervenes during
  calibration, and never sleeps or reboots the PC automatically. Wake, tray, and
  main-loop recoveries share a global coordinator so they cannot collide.
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
- Recovery can take roughly one to three minutes when the legacy EyeX engine needs
  a cold start; it never reboots, sleeps, or closes your other apps automatically.
- Provided as-is under the MIT license. It restarts vendor services and power-cycles
  a USB device; read the scripts before running.

## Contributing

Issues and PRs welcome — especially confirmations/fixes for other Alienware models,
and any progress on the failure modes that currently need a manual reconnect.
