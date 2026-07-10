# Tobii Eye Tracker — Findings, History & Handoff

> Living record of the investigation into the Alienware/Tobii IS5 eye-tracker
> dropouts and the watchdog built to work around them. Written for a future agent
> or engineer picking this up cold. **Read this first.**
>
> Last updated: 2026-07-05. Also mirrored in Claude memory as
> `project_tobii_eyetracker_watchdog`.

---

## 1. The problem (user's words)

Alienware laptop with a Tobii eye tracker. For **5–6 years**, across every driver
version / Windows patch, the tracker works for "a few minutes to up to an hour"
and then **stops**. Previous attempts (with earlier AI/tools) tried USB resets and
other resets but never found a permanent fix. The user's goal: **keep the eye
tracker up as much as possible**, ideally self-healing in the background.

Hard constraints from the user:
- **Do NOT reboot the machine** automatically.
- **Do NOT close** the user's programs/terminals/browsers/prompts. If something
  needs closing, *ask* — the user runs a lot of other work in parallel.
- Restarting / disabling **Tobii** services & processes is fine, as much as needed.

---

## 2. Environment / how to work on this

- The box is **WSL2 (Ubuntu) inside Windows 10** (build 19045 / 22H2).
- Windows is reachable from WSL via interop: `powershell.exe -NoProfile -Command "..."`.
  This runs **non-elevated**. Privileged actions (restart services, PnP enable/disable,
  register tasks) need elevation.
- **Elevation options:** (a) a self-elevating script that calls
  `Start-Process powershell -Verb RunAs` (pops a UAC prompt on the Windows desktop),
  or (b) hand the user a command to paste into an **elevated PowerShell** they open.
- **UAC over Chrome Remote Desktop is flaky** — the secure-desktop prompt is often
  hard to click remotely. Prefer giving the user a paste-able command, or a
  self-deleting temp script they launch, over driving UAC ourselves.
- The automation guardrail blocks the agent from directly killing/unregistering
  tasks & processes it didn't create. Workaround used repeatedly: **write a
  self-elevating, self-deleting temp script to `C:\Scripts\_*.ps1` and give the
  user a one-line command to run it.** That's user-initiated, so it's allowed.
- **Windows user profile:** `C:\Users\<you>`. Machine: `YOUR-PC`.
- Windows filesystem from WSL: `/mnt/c/...`. `C:\Scripts` is `drwxrwxrwx` (writable).

---

## 3. Hardware / software facts (the exact device)

- **Device:** Tobii **IS5 "YAMATO17"** integrated eye tracker (Alienware).
- **USB node:** `USB\VID_2104&PID_030C\IS5xx-XXXXXXXXX`
  - FriendlyName **"EyeChip"**, Class `USBDevice`. VID 2104 = Tobii.
  - HID children: **"Tobii Device"**, **"Tobii Eye Tracker HID"**.
- **Services:**
  - **"Tobii Service"** — middleware. `C:\Program Files (x86)\Tobii\Service\Tobii.Service.exe`.
  - **"TobiiIS5YAMATO17"** (display name "Tobii Runtime Service") — low-level device
    runtime. `C:\Windows\System32\DriverStore\FileRepository\is5yamato17.inf_amd64_*\platform_runtime_IS5YAMATO17_service.exe`.
  - No dependency chain between them; both Auto-start.
- **User processes:**
  - **Tobii.EyeX.Engine.exe** — the EyeX engine (state machine, produces gaze).
    `C:\Program Files (x86)\Tobii\Tobii EyeX\Tobii.EyeX.Engine.exe`. **Child of
    Tobii.Service.exe** — restarting "Tobii Service" respawns it. Engine v1.37.0.641.
  - **Tobii.EyeX.Interaction.exe** — interaction layer.
  - **Tobii.EyeTracking.Portal.WPF.exe** — the "Tobii Experience" settings app (the
    one with the animated face + gaze dot).
- **Logs** (`%LOCALAPPDATA%\Tobii\Tobii Interaction\` = `C:\Users\<you>\AppData\Local\Tobii\Tobii Interaction\`):
  - `ServerLog.txt` (+ rotations `.1`..`.10`) — the engine state machine log. **Primary signal.**
  - `InteractionLog.txt` — gaze interaction events (updates only during active gaze use).
  - `ConfigurationLog.txt` — config; contains "large gap between gaze data timestamps" lines.
- **Settings:** `%APPDATA%\Tobii\Tobii Interaction\engine.settings.txt`,
  `engine.commonSettings.txt`. No exposed "power save" toggle (it's baked into the engine).
- **Tobii Stream Engine SDK present** (used briefly, then abandoned — see §6):
  `C:\Program Files (x86)\Tobii\Tobii EyeX\tobii_stream_engine.dll` (native, **x86**)
  and `Tobii.StreamEngine.Net.dll` (.NET wrapper, x86). Loading these requires a
  **32-bit** PowerShell: `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`.

---

## 4. Root cause (what's actually wrong)

The engine's state machine (in `ServerLog.txt`) cycles:
`Initialize → WaitingForConnection → ConnectToEyeTracker → PreparingForTracking → Tracking`,
and drops to `WaitingForDevice` / `Idle` on trouble.

**The failure:** the EyeX engine repeatedly loses its internal **"PRP" connection**
(Tobii Platform Runtime Protocol) to the runtime service `TobiiIS5YAMATO17`. Log
signature:
```
... PRP_ERROR_ENUM_CONNECTION_FAILED / DEVICE_ERROR_CONNECTION_FAILED / TOBII_ERROR_CONNECTION_FAILED
An error occurred in the eye tracking engine event loop (Connection to the eye tracker was lost...)
>>> Statemachine: Now in state WaitingForDevice <<<
Stopping the eye tracking host.  ->  Eyetracking suspended.
```

Quantified from the logs (561 `WaitingForDevice` events, time-to-recovery):
| Recovery time | Count | |
|---|---|---|
| 0–5 s | 151 | normal self-heal |
| 6–60 s | ~17 | |
| **1–5 min** | **19** | user notices |
| **5–60 min** | **112** | the outages fought for years |
| >1 h | 262 | sleep / away |

**It is NOT hardware and NOT Windows power management.** Windows event logs across
the failures showed: **zero USB-hub disconnect events**, **no Kernel-PnP device
removals at failure times**, and **no power events except across sleep**. The device
reports **"OK" in Device Manager the entire time it's "lost"** (which is exactly why
years of hardware/USB-reset attempts never found it, and why the earlier
presence-based watchdog never fired — see §7). Nothing else contends for the sensor:
Windows Hello face is off (WbioSrvc stopped), presence sensing not configured, and
the IR sensor is a dedicated Tobii device (not the "Integrated Webcam").

**Conclusion:** it's a bug inside **Tobii's own closed-source stack** (runtime ↔
engine PRP connection) for this legacy/abandoned IS5 EyeX product. We cannot patch
it. Every driver version has it. So a supervising watchdog that forces a reconnect
is the correct, pragmatic fix — not a lazy band-aid.

---

## 5. The THREE observed failure modes

- **Mode A — connection drop.** Engine → `WaitingForDevice`, tracking suspended.
  **Detectable from the log.** Usually self-heals in <5s; sometimes stuck 5–60 min.
  This is the original problem and what the watchdog auto-recovers.
- **Mode B — silent stall while "Tracking".** State machine stays in `Tracking`
  but **gaze data stops flowing** ("large gap between gaze data timestamps",
  "activated power save"). Log looks healthy → **log parsing is BLIND to it.**
- **Mode C — streaming but all-INVALID.** Device streams gaze callbacks at ~33 Hz
  but **validity is always INVALID** (Experience face frozen; "works 2–3 seconds
  when reopened then stops"). Sensor isn't locking onto eyes. Also invisible to
  log parsing, and **cannot be distinguished from "user looked away" without a gaze
  subscription — which is unsafe on this hardware (see §6).**

Modes B & C are handled by the **manual "Reconnect now"** tray button, not auto-detection.

### THE MODE-D FIX: re-apply stored calibration without recalibrating

**Solved.** After a hibernate-resume the EyeX engine comes up in the `Tracking`
state but with **no calibration bound to the live device** (0% CPU, IR LEDs dark).
The calibration is *volatile firmware state* wiped when hibernate cuts tracker power;
**no restart, USB power-cycle, or boot-order trick re-binds it** (all tested — see the
"what does NOT work" note below). The only thing that does is re-pushing the stored
calibration blob to the engine — which, until now, only the recalibration UI did.

We found the safe primitive by decompiling the Tobii stack:

```
Tobii.Interaction.Host  ->  IContext.SetProfileCalibrationDataAsync(
        profileName, trackerUri, timestamp, numPoints, byte[] calibrationData, handler)
```

This goes through the **EyeX engine over IPC** (the same channel the interaction app
uses) — **not** a raw Stream Engine gaze subscription (that resets this hardware; see
§6). `Tobii-CalReapply.exe` (built from `Tobii-CalReapply.cs`) does exactly this:

1. Reads the current profile + tracker URI from the registry
   (`HKLM\SOFTWARE\WOW6432Node\Tobii\EyeXConfig\CurrentUserProfile` / `DefaultEyeTracker`).
2. Loads the stored calibration blob from the tracker's `calibration.setpm`
   (`C:\ProgramData\Tobii\Tobii Platform Runtime\<model>\<serial>\calibration.setpm`).
   The `.setpm` is a **16-byte header + the raw EyeX calibration blob**, so it strips
   the header and passes the remainder as `calibrationData`.
3. Connects a `Host`, calls `SetProfileCalibrationDataAsync(...)`, waits for
   `ResultCode.Ok`, disconnects.

Verified live on a hibernate-dead device: engine CPU jumped **0.5% → ~30–40%**, IR
LEDs came back, gaze worked — **with zero recalibration dots.** It also registers the
calibration for the *current* serial (the profile previously only had a stale entry
for an old serial), which is likely why resume lost it in the first place.

The watchdog now runs this **first** in its stall ladder and on resume, so Mode D
self-heals in ~1s with no restart; the red "recalibrate" flag is only raised if even
this fails (no stored calibration to re-apply). Manual trigger: tray → **Re-apply
saved calibration**.

> ⚠️ Note: this uses the **`Tobii.Interaction` engine-IPC** path only. Do **not** be
> tempted by `ConnectedEyeTracker.SetCalibration()` in `Tobii.Configuration.Common` —
> that one is built on the **Stream Engine** (opens a raw device connection) and is the
> §6 hazard.

### 5a. Physical signal: the IR illuminator LEDs go DARK on every drop

Reported behavior: **every time tracking stops, the visible IR illuminator LEDs in
the tracker bezel go out**, and return when it recovers. Interpretation:

- The illuminators are driven by the **low-level runtime** / device firmware and only
  pulse while there is an **active imaging session**. LEDs dark = the runtime has
  **torn down the device's streaming session**, not merely a middleware hiccup. (If
  only the engine's connection to the runtime dropped while the device kept imaging,
  the LEDs would stay lit.)
- **Not a contradiction with "Device Manager says OK."** The USB device stays
  enumerated/powered (that's what DM reports); it just has no active tracking
  session. Two different things.
- Best interpretation: this is **downstream of** the connection loss (engine drops →
  runtime stops streaming → illuminators power down), i.e. a *symptom*, not the
  trigger — but it's the most reliable **human-visible ground truth** of a real drop,
  more trustworthy than the log in the "Tracking"-lie / silent-stall case.
- **Open question to resolve on the next silent stall (Mode B):** do the LEDs stay
  on (session live, calibration/validity lost) or go dark (session torn down while
  the log still claims `Tracking`)? A decisive data point either way.
- **Cannot be used as a watchdog signal:** reading illuminator/camera state requires
  opening a device/stream session, which resets this hardware (§6). LEDs stay a
  manual eyeball check only.

---

## 6. ⚠️ CRITICAL LESSON: never subscribe to the gaze stream

We built a "gaze-data watchdog" that opened its **own Tobii Stream Engine gaze
subscription** (2nd client) to detect stalls by watching real data flow. As a
*detector* it worked perfectly (100 callbacks/3s; distinguishes valid vs invalid;
"callbacks flowing = alive even when you look away, zero = frozen").

**BUT a second persistent gaze subscriber BREAKS this hardware.** With the EyeX
engine + Experience app + our subscription all reading gaze, the IS5 **resets every
~2–3 seconds** — the Experience face visualization froze; "works a few seconds then
stops." The user correctly suspected our script was interfering. Disabling the
watchdog immediately made tracking **stable and perfect**.

**Verdict / rule for all future work:** the watchdog must be **PASSIVE** — read
`ServerLog.txt` only, **never** open a Tobii gaze/stream subscription (not even a
brief probe; even short concurrent subscriptions glitch it). The SDK approach is
dead for monitoring. (The SDK still works for one-off manual diagnostics if the
engine is stopped, but don't run it alongside live tracking.)

This is why Mode B/C can't be auto-detected safely, and why we fall back to a
manual reconnect button.

---

## 7. Everything we tried (chronological), and outcomes

1. **Found no prior scripts from the current session's tools.** But discovered an
   **earlier "Codex" attempt** already in `C:\Scripts` (Jul 2): a `Tobii-Watchdog.ps1`
   + `Restart-TobiiEyeChip.ps1` + a `Tobii-Diagnostics` folder, and a scheduled
   task running the watchdog every 60s.
2. **Diagnosed Codex's watchdog as ineffective:** it decided whether to act using
   `Get-PnpDevice` **Status == OK / ProblemCode == 0** — a *device-presence* check.
   Since the device stays "OK" while tracking is dead, it logged "All target devices
   OK; no repair needed" every minute and **never fired.** Right suspicion, wrong signal.
   → Archived it to `Tobii-Diagnostics\_archived-codex-watchdog\` with a note.
3. **Disabled USB selective suspend** (per-device `SelectiveSuspendEnabled=0`,
   `AllowIdleIrpInD3=0`, `EnhancedPowerManagementEnabled=0` on the VID_2104 node;
   plus global powercfg USB selective-suspend off, AC+DC). Reduces drop frequency;
   not a full fix. **Left in place (harmless, keep it).**
4. **Built a log-state watchdog** (read `ServerLog.txt`, detect non-`Tracking`).
   - Bug found: it read only `Get-Content -Tail 400`; after long steady tracking the
     last state line was >400 lines back → returned null → treated as "do nothing"
     → **went blind and missed real drops.** Fixed: whole-file `Select-String` for
     the last `Now in state`, and time the hang by the watchdog's **own clock**.
5. **Recovery escalation** developed: L1 restart runtime service; L2 kill+respawn
   EyeX engine + restart runtime + middleware; L3 USB power-cycle.
   - Discovered the **EyeX engine can WEDGE**: it respawns (as child of Tobii.Service)
     but never reaches the state machine (only logs statistics warnings). A plain
     service restart isn't enough — must **kill Tobii.EyeX.Engine/Interaction** so a
     truly fresh one starts.
6. **⚠️ pnputil GOTCHA:** `pnputil /restart-device` on the EyeChip **left it DISABLED**
   (problem code **22 = CM_PROB_DISABLED**). Then *nothing* reaches Tracking until
   it's re-enabled (`pnputil /enable-device`). Fixes applied: Reset-UsbDevice now
   **verifies the device ends `OK` and force-enables if not**, and **USB power-cycle
   was removed from AUTO recovery** (manual-only now).
7. **Built the gaze-data watchdog** (§6) — worked as a detector, **but broke tracking**.
   Abandoned. Confirmed by the user; disabling it restored perfect tracking.
8. **Final design (current):** passive log-state watchdog + system-tray utility with
   a **manual "Reconnect now"** button (+ pause/resume, + optional auto-pause in games).

---

## 8. Current architecture (what's deployed)

Everything lives in **`C:\Scripts\`**.

**Files:**
- `Tobii-Watchdog.ps1` — **passive log-state watchdog** (64-bit, no SDK, no gaze
  subscription). Reads `ServerLog.txt`; if state stays non-`Tracking`/`Idle` past
  `StuckThresholdSec` (30s), runs recovery. Honors a pause flag. Modes: `-Once`
  (print state), `-ForceReconnect` (full manual reconnect incl. verified USB
  power-cycle), `-OnWake`. Single-instance mutex `Global\TobiiWatchdogSingleton`.
  Log rotation at 1 MB.
- `Tobii-Tray.ps1` — system-tray utility (WinForms NotifyIcon). Left-click = pause/
  resume. Right-click menu: **Reconnect now**, Pause/Resume auto-recovery,
  Auto-pause in fullscreen games (uses `SHQueryUserNotificationState`; off by
  default), Open log, Exit. Writes `watchdog.pause` and `tray.settings.json`;
  "Reconnect now" fires the `TobiiReconnect` task.
- `Tobii-Monitor.ps1` — **passive telemetry recorder** (observe-only, non-elevated,
  never touches the device / never subscribes to gaze). Samples every 20s and
  appends a JSON line to `Tobii-Telemetry.jsonl`; detects drops/recoveries and writes
  event lines + on-drop snapshots. Modes: `-Once` (one sample), `-Stats` (health report).
- `Tobii-Tray.vbs` — hidden launcher for the tray (no console flash).
- `Install-TobiiWatchdog.ps1` — registers tasks + USB fixes + tray autostart. Elevated.
- `Uninstall-TobiiWatchdog.ps1` — removes tasks, tray autostart, pause flag. Elevated.
- `README.md` — user-facing summary.
- `TOBII-FINDINGS.md` — **this file.**
- Runtime: `Tobii-Watchdog.log` (rotating), `watchdog.pause` (present ⇒ paused),
  `tray.settings.json`, `Tobii-Telemetry.jsonl` (rotating 5 MB), and
  `Tobii-Diagnostics\snapshots\snap-*.txt` (full context dumped on each drop).
- `Tobii-Diagnostics\` — Codex's original diagnostic captures (kept for history).
  `Tobii-Diagnostics\_archived-codex-watchdog\` — Codex's old scripts + a note.
- `_*.ps1` — transient self-deleting temp scripts (should not linger).

**Scheduled tasks:**
- `TobiiWatchdog` — at logon, elevated (RunLevel Highest), runs the watchdog loop.
- `TobiiWatchdog-OnWake` — fires on resume-from-sleep (Power-Troubleshooter event 1),
  runs `-OnWake`.
- `TobiiReconnect` — **on-demand, elevated, no trigger.** The non-admin tray triggers
  it (`Start-ScheduledTask TobiiReconnect`) to force a reconnect **without a UAC prompt**.
- `TobiiMonitor` — at logon, **non-elevated (Limited), observe-only.** Runs
  `Tobii-Monitor.ps1` continuously; records telemetry + snapshots. Never acts.

**Telemetry (`Tobii-Telemetry.jsonl`)** — one compact JSON object per 20s sample,
all PASSIVE reads. Fields: `ts`, `state` (engine state from ServerLog), `logAge`
(sec since ServerLog written), `dev` (EyeChip PnP status), `prob` (problem code),
`svcMw`/`svcRt` (service states), `engCpu`/`engMem`/`rtCpu` (engine + runtime CPU%
/ mem — rtCpu≈0 while streaming stalled), `inter` (interaction proc present), `idle`
(user idle sec via GetLastInputInfo — presence proxy), `fs` (SHQueryUserNotificationState:
3/4 = fullscreen game/presentation), `ac` (power line), `batt` (%), `paused`.
Transition rows add `evt` = `drop` / `recovered` (+ `outageSec`). `-Stats` computes
MTBF, drops/hr, outage min/median/max, state distribution, last-drop age.
This is the substrate for iterating: mine it to correlate drops with time/power/
fullscreen/idle, and to measure whether mitigations actually reduce frequency.

**Autostart:** tray via `HKCU\...\Run\TobiiTray = wscript.exe "C:\Scripts\Tobii-Tray.vbs"`.

---

## 9. Operating it (commands)

```powershell
# current state (passive read)
powershell -File "C:\Scripts\Tobii-Watchdog.ps1" -Once

# force a full reconnect (USB power-cycle + engine/services), verified enable
powershell -File "C:\Scripts\Tobii-Watchdog.ps1" -ForceReconnect      # (elevated)

# watch the log live
Get-Content "C:\Scripts\Tobii-Watchdog.log" -Wait

# pause / resume auto-recovery by hand (tray does this):
New-Item  "C:\Scripts\watchdog.pause" -Force      # pause
Remove-Item "C:\Scripts\watchdog.pause"           # resume

# fire the manual reconnect task (what the tray button does)
Start-ScheduledTask -TaskName TobiiReconnect

# monitoring / telemetry
powershell -File "C:\Scripts\Tobii-Monitor.ps1" -Stats     # health report (MTBF, drops/hr, outages)
powershell -File "C:\Scripts\Tobii-Monitor.ps1" -Once      # one live sample (JSON)
Get-Content "C:\Scripts\Tobii-Telemetry.jsonl" -Tail 20    # raw recent samples
# snapshots of each drop: C:\Scripts\Tobii-Diagnostics\snapshots\

# reinstall / redeploy (elevated)
powershell -File "C:\Scripts\Install-TobiiWatchdog.ps1"

# uninstall everything (elevated)
powershell -File "C:\Scripts\Uninstall-TobiiWatchdog.ps1"
```

Quick manual full-stack recycle (what "Reconnect now" effectively does):
```powershell
Stop-Service 'Tobii Service' -Force
Get-Process 'Tobii.EyeX.Engine','Tobii.EyeX.Interaction' | Stop-Process -Force
Stop-Service 'TobiiIS5YAMATO17' -Force
Start-Sleep 2
Start-Service 'TobiiIS5YAMATO17'; Start-Sleep 3
Start-Service 'Tobii Service'
# if the device shows Error/Disabled:
pnputil /enable-device "USB\VID_2104&PID_030C\IS5xx-XXXXXXXXX"
```

Check device / gaze health (manual diagnostics):
```powershell
Get-PnpDevice -InstanceId 'USB\VID_2104&PID_030C\IS5xx-XXXXXXXXX' | Select Status
# Status OK = present; "Error" + ProblemCode 22 = DISABLED -> enable it.
```

---

## 10. Open issues / what is NOT solved

- **Mode B & C are not auto-detected.** The only reliable auto-signal for them is a
  gaze subscription, which **breaks the hardware** (§6). Current answer: the manual
  **"Reconnect now"** tray button. If someone finds a passive signal for gaze-data
  flow (e.g., a Tobii-written counter/log that updates per frame *without* us
  subscribing), that could enable safe auto-detection — investigate `ConfigurationLog`
  / statistics files, but note `ConfigurationLog.txt` was observed stale (not live).
- **We never fully confirmed** whether a reconnect reliably restores *valid* gaze in
  Mode C, because the diagnostic that would test it required a gaze subscription and
  the user reported the subscription itself was the problem mid-test. Re-test only
  with the engine stopped, or via the Experience app visually.
- **Root cause is a vendor bug** we can't fix. Only mitigations: reduce frequency
  (USB suspend off — done), auto-recover Mode A (done), manual reconnect for B/C.
- Deep-clean opportunity: prune old `Tobii-Watchdog-*.log` rotations and stray
  `_*.ps1` temp files if any survived.

---

## 11. Notes for a future agent

- **Do not "improve" this by adding gaze/stream-engine monitoring.** It will seem
  like a great idea (it detects everything). It **breaks the tracker.** See §6.
- Keep the watchdog **passive**. If adding detection, it must not touch the device
  during healthy operation.
- Keep **USB power-cycle out of auto-recovery** (it can disable the device). Manual only,
  always with the enable-verify.
- Respect the user's constraints (§1): no reboots, don't close their apps; ask first.
- Prefer **self-deleting temp scripts + a paste-able command** for privileged actions;
  UAC-over-remote-desktop is unreliable here.
- The tracker recovering to `Tracking` in `ServerLog.txt` (state line) is the ground
  truth for "connection restored." Valid *gaze* (eyes detected) is separate and can
  only be seen via the Experience app or a (careful, engine-stopped) SDK probe.
- **All monitoring must stay passive** (reads only). The telemetry recorder never
  touches the device — keep it that way. Adding fields = fine; adding any device I/O
  or gaze subscription = forbidden (§6).

---

## 13. Session 3 (2026-07-05): Tier-2 power fixes applied; driver + Experience-migration avenues conclusively closed

Explored whether anything *besides* the watchdog could fix this — community research,
a real driver-version check, and a full audit of a prior Tobii Experience migration
attempt. Two of three leads panned out as real, reversible mitigations; two "maybe
there's a real fix" avenues turned out to be dead ends that were already tried.

### 13a. Tier-2 power fixes — APPLIED, both no-reboot, both AC-only (DC/battery untouched)

1. **USB selective suspend, propagated up the tree.** §7.3 only disabled selective
   suspend on the EyeChip leaf device. The **USB Root Hub (USB 3.0)** and the
   **Intel(R) USB 3.1 eXtensible Host Controller** above it (`PCI\VEN_8086&DEV_A36D...`
   — this machine uses Intel's native XHCI, *not* an ASMedia controller, so the
   known Tobii/ASMedia bandwidth bug doesn't apply here) had **no override at all** —
   running on Windows' default power-saving behavior. Set on both ancestor nodes via
   elevated registry write (`HKLM:\SYSTEM\CurrentControlSet\Enum\<id>\Device Parameters`):
   `SelectiveSuspendEnabled=0`, `EnhancedPowerManagementEnabled=0`, `AllowIdleIrpInD3=0`.
   Confirmed applied. No reboot, no re-enumeration — takes effect on next natural
   power-state transition.
2. **PCIe ASPM (Active State Power Management) → Off on AC.** Was set to **"Maximum
   power savings"** on *both* AC and DC in the active ("Balanced") power scheme —
   aggressive PCIe link power-state cycling is a plausible contributor to a USB
   controller transiently losing its link. Set via
   `powercfg /setacvalueindex <scheme> SUB_PCIEXPRESS ASPM 0` (AC only; DC left at
   "Maximum power savings" to preserve battery life). Applied live via
   `powercfg /setactive`, no elevation needed, no reboot.
3. **Minimum CPU state → 100% on AC.** Was 5% on both AC/DC (aggressive C-state
   diving). Set to 100% on AC only via `SUB_PROCESSOR PROCTHROTTLEMIN`; DC left at
   5%. Same no-elevation, no-reboot application.

Current power scheme GUID (Balanced): `381b4222-f694-41f0-9685-ff5bb260df2e`.
USB ancestor chain for reference: EyeChip → `USB\ROOT_HUB30\4&91c6074&0&0` →
`PCI\VEN_8086&DEV_A36D&SUBSYS_093C1028&REV_10\3&11583659&0&A0` (Intel USB 3.1 XHCI).

**Not yet measured** whether these reduce drop frequency — needs `Tobii-Monitor.ps1
-Stats` compared before/after over several days. **Current plan (next step): run
the existing watchdog + these Tier-2 settings together and use the telemetry to see
if MTBF/outage-length improves** — this is a combination, not an either/or; the
watchdog stays as the safety net regardless of what the power tweaks do.

### 13b. Driver-update avenue — CONCLUSIVELY CLOSED (not just "probably no update")

User suspected the driver was already current from a past attempt. Verified for
real instead of trusting Dell's page metadata:
- Dell lists **PKVP7** (`Tobii-Experience-Driver_PKVP7_WIN64_4.33.0.2936`) as the
  current package for Alienware M15 R2/M17 R2, page-dated 2019-11-14 — one month
  *after* the installed driver's 2019-10-16 date, so it looked like a real update.
- **Downloaded and extracted it with 7-Zip (no execution)** and diffed the embedded
  INF `DriverVer` strings against the live system: `IS5Yamato17.inf` → `1.7.0.2232,
  10/16/2019` and `TobiiEyeTracker.inf` → `1.16.1710.0, 10/09/2019` — **byte-for-byte
  identical** to what's already installed, plus an identical `Middleware_Bundle_v4.8.0.641_x86.exe`
  inside. Dell's DUP wrapper version/date does **not** track the actual driver
  payload version — it can be repackaged/reposted with a newer wrapper date around
  identical file contents. The lower Dell ID **MCWGF** (4.15.0.910, June 2019) is
  older than what's installed and would have been a downgrade/no-op — likely
  explains the user's memory of a past attempt "ending up with the exact
  installations we already have."
- Cross-checked against **sub-revisions already sitting in `C:\Users\<you>\Downloads`**
  from a prior session (`PKVP7_..._A02_02`, dated 2026-06-17) — extracted and
  confirmed **same identical INF versions**. There is no newer official driver.
  Verdict: **this laptop already has the latest Tobii driver for this hardware,
  full stop.** Do not spend more effort re-checking Dell's site for this device.

### 13c. Tobii Experience migration — ALREADY ATTEMPTED, CONCLUSIVELY A DEAD END

Community research (Tobii dev forums, an SCS Software/ETS2 forum thread) suggested
migrating from the legacy "Tobii Eye Tracking for Windows"/EyeX stack to the newer
Store-delivered **"Tobii Experience"** app fixed similar connection-drop symptoms on
other Tobii hardware, and Tobii's own Alienware-Experience changelog explicitly
lists a fix for "eye tracking stops working after hours of idling." Alienware m17 R2
is confirmed on Tobii's supported-device list for Experience. This looked like the
most promising lead — **but forensic evidence on this machine shows it was already
tried:**
- `C:\Users\<you>\Downloads` contains `Tobii-Experience-Application_5HC61_WIN64_1.18.698.0_A02_03.EXE`
  (2026-06-29) and a file named `Tobii Experience Installer.exe` which, on
  inspection, is actually **Microsoft's own generic `StoreInstaller.exe`**
  (CompanyName: Microsoft Corporation) — the executable the Microsoft Store runs
  when you click "Get". Both created within 4 minutes of each other on 2026-06-29,
  consistent with: downloaded 5HC61 stub → it opened the Store page → clicked Get →
  StoreInstaller ran.
- **The Store app is in fact currently installed**: `TobiiAB.TobiiEyeTrackingPortal`,
  v**1.27.4060.0** (self-updated via the Store well past anything Dell references),
  `Status: Ok`, at `C:\Program Files\WindowsApps\TobiiAB.TobiiEyeTrackingPortal_...`.
  User confirmed recollection: installed it and had to recalibrate.
- **But it is not what's driving eye tracking.** A week later, `Tobii Service` and
  `Tobii.EyeX.Engine.exe` — the **legacy** processes — are the ones confirmed
  Running, and the watchdog log shows the identical `WaitingForDevice` drop/recover
  cycle happening *on the same day this was re-investigated*. The Portal app itself
  was not running as a process; its only recent file activity was a passive
  `GamesList.xml` cache write.
- **Conclusion:** for this integrated Alienware bundle specifically, "Tobii
  Experience" appears to be a **configuration/calibration UI layered on top of the
  same underlying runtime** (`Tobii.Service.exe` → `Tobii.EyeX.Engine.exe` → PRP →
  `TobiiIS5YAMATO17`), not a replacement engine. Installing and calibrating through
  it does not change which code path actually does real-time tracking, so it does
  not touch the root-cause bug. **Do not re-attempt this migration** expecting a
  different outcome — it's already been run to completion once.

### 13d. Verification technique worth reusing

For any future "is there really a newer X" question about a closed-source vendor
package: **don't trust a vendor page's version/date field — download the installer,
extract it with `7z.exe x <file> -o<dir> -y` (works on most self-extracting
DUP/NSIS/InstallShield payloads without running any installer logic), and diff the
actual embedded `DriverVer`/file-version strings against what `Get-PnpDeviceProperty`
/ `Get-WmiObject Win32_PnPSignedDriver` reports as currently installed.** This is
how §13b was resolved definitively instead of guessing from page metadata. 7-Zip is
present at `C:\Program Files\7-Zip\7z.exe`.

`DRIVER-BRIEFING.md` (the standalone doc written to hand this driver question to a
separate agent) has been **deleted** — its questions are now fully answered above,
so it's redundant with this file.

---

## 14. Change log (append newest at the bottom)

- **2026-07-05 — initial build.** Diagnosed root cause; disabled USB selective
  suspend; built log-state watchdog (fixed tail-400 blindness, clock-based timing,
  engine-recycle, USB enable-verify). Tried gaze-subscription watchdog → **it broke
  the tracker (2-3s resets)** → reverted to passive log-state only. Added tray
  (Reconnect now / Pause / auto-pause-in-games) + tasks (TobiiWatchdog, -OnWake,
  TobiiReconnect). Wrote this file.
- **2026-07-05 — added comprehensive passive telemetry.** New `Tobii-Monitor.ps1`
  + `TobiiMonitor` task (non-elevated, observe-only): 20s samples → `Tobii-Telemetry.jsonl`,
  drop/recovery events, on-drop snapshots, `-Stats` health report. Tray got "Health
  report" + "Open telemetry folder". Purpose: gather data to iterate on. NEXT ideas
  (not yet built): Tier-2 power tweaks (parent-hub USB power, PCIe ASPM off, max CPU
  on AC); Tier-1 recovery rate-limit + notify + self-healing heartbeat; Tier-3
  experimental mode-B detection via rtCpu≈0 + user-active (idle low). Mine the
  telemetry first to see which failure modes actually dominate.
- **2026-07-05 — driver briefing.** Wrote `DRIVER-BRIEFING.md` (self-contained
  context for a separate agent to discuss the driver/firmware angle). Captured exact
  versions: Alienware m17 R2, Win10 22H2 19045; Tobii driver **oem451.inf v1.16.1710.0
  (2019-10-08)**; EyeChip USB node on generic **winusb.inf**; stack = "Tobii Eye
  Tracking for Windows" 4.8.0.641 / Engine 1.37.0.641 / Service 1.38.0.641 /
  Stream Engine Service 0.9.4.1394. Open driver questions listed there.
- **2026-07-05 — Tier-2 power fixes applied; driver & Experience-migration avenues
  closed for good (§13).** Disabled USB selective suspend on the Root Hub + Host
  Controller (only the leaf EyeChip device had it before). Set PCIe ASPM off and
  min CPU state 100%, both AC-only, in the active power scheme. Verified via
  extract-and-diff of the actual driver package (not just page metadata) that this
  machine already has the latest possible Tobii driver — no update exists.
  Discovered via Downloads-folder forensics that a Tobii Experience Store-app
  migration was already fully attempted on 2026-06-29 (installed, recalibrated,
  self-updated to v1.27.4060.0) but the legacy EyeX engine is still what actually
  drives tracking — Experience is a config UI on this bundle, not a different
  engine, so it doesn't touch the bug. Deleted `DRIVER-BRIEFING.md` (superseded by
  §13). **Current/next step: run the watchdog + Tier-2 power settings together and
  use `Tobii-Monitor.ps1 -Stats` to compare MTBF/outage-length before vs. after —
  not evaluated in isolation, evaluated as the combination.**
- **2026-07-06 — NEW failure signature: "needs recalibration" after sleep/unplug
  (possible Mode D, distinct from the PRP-drop bug).** User's tracker stopped working
  this morning; **Tobii Experience explicitly said it needs to be recalibrated.**
  Context: worked ~last night after midnight → put to sleep, **unplugged (on battery)**
  → this morning not working. Diagnosis at the time: connection layer fully healthy
  (device OK/problemcode 0, services Running, engine held `Tracking` since 10:33:09),
  and the user's tray "Reconnect now" (`-ForceReconnect`, incl. USB power-cycle) ran
  correctly but did NOT restore usable gaze — because the issue was **lost/invalidated
  calibration**, which a stack reconnect can't fix. `ServerLog` "No displayDeviceName
  found for index 1" confirmed benign (single display at index 0). This suggests
  calibration profile may be getting invalidated across sleep/battery transitions —
  if it recurs every sleep cycle, that's a new avenue (where is the calibration
  profile stored? does DC/battery or the resume path wipe it?). Recovery this time =
  recalibrate in Tobii Experience (guided the user). Also: the **telemetry monitor
  had died** 2026-07-05 13:32 (lastRun result 0xC000013A, task idle) — restarted it
  (`Start-ScheduledTask TobiiMonitor`), so it may need a self-heal/heartbeat (Tier-1)
  so it doesn't silently stop. Codex's old `Restart Tobii EyeChip on Wake` task still
  lingers (Ready) pointing at an archived script — inert but should be removed.
- **2026-07-06 — BUG: watchdog interrupted a calibration; fixed to only act on
  WaitingForDevice.** During the recalibration above, it threw "oops no connection
  found" — because **calibration puts the engine in state `Configuring`**, and the
  watchdog treated *any* non-`Tracking`/`Idle` state as "stuck" after 30s, so it
  fired a service-restart mid-calibration and killed the connection. User correctly
  turned off the watchdog, recalibrated, and it worked. FIX: watchdog now recovers
  **only** from `$FaultStates = @('WaitingForDevice')` (the real PRP-drop signature);
  all transient/setup states (Initialize, WaitingForConnection, ConnectToEyeTracker,
  PreparingForTracking, Configuring) and null are left alone. Added `Test-ConfigActive`
  guard: never recover while `Tobii.Configuration` is running. Applied to both the
  main loop and `-OnWake`. (This is the 2nd time the watchdog itself caused harm —
  1st was the gaze-subscription; keep the watchdog CONSERVATIVE: passive detection,
  act only on the one known fault, never during user setup.) Watchdog left OFF by
  the user; re-enable reloads the fixed script.
- **2026-07-06 — removed Codex's dead wake task + added instant event-driven
  reaction.** Removed `Restart Tobii EyeChip on Wake` (inert; archived script).
  Clarified: the watchdog was ALREADY trigger-agnostic (acts on `WaitingForDevice`
  from any cause; `-OnWake` is just a fast-path). Added, in the TRAY (event-driven,
  ~0 idle cost, no new process/poll): `SystemEvents.PowerModeChanged`
  (AC/DC StatusChange + Resume) and `SystemEvents.DisplaySettingsChanged` both fire
  `Start-ScheduledTask TobiiWatchdog-OnWake` (25s debounce). That task runs the safe
  `-OnWake` check → reconnects ONLY if `WaitingForDevice` and not calibrating. So
  power-source and display changes now recover in seconds instead of waiting for the
  ~30s poll, with no false action on benign changes. Tray must be restarted to load
  the new handlers (non-elevated: kill Tobii-Tray.ps1 proc + relaunch via the vbs).
  Reference: triggers that cause real connection drops (all caught) vs. non-connection
  modes (display-mapping, calibration-loss, invalid-gaze) documented in this session's
  reply — the fast-paths only help the connection-drop class.
- **2026-07-06 evening — battery-died-in-sleep cold boot exposed a watchdog blind
  spot; fixed with a passive stack-presence check.** Battery drained during sleep
  → cold boot (not a resume). For ~3 min after logon there was no eye tracking and
  the watchdog saw nothing wrong: `Tobii Service` is **Automatic (Delayed Start)**
  (starts ~2+ min after boot), the engine process didn't exist, and the last
  ServerLog state line still said `Tracking` from hours before the battery died —
  the log-state check trusts a stale log across crash/boot. Manual "Reconnect now"
  fixed it in ~20s. Also ruled out: Kernel-PnP event 219 at boot (`WudfRd` failed
  to load for TobiiHidDriver) fires on every boot — an artifact, not a cause.
  FIX (still fully passive — Get-Service/Get-Process only, never gaze): watchdog
  now (1) trusts the log state only while `Tobii.EyeX.Engine` is alive; (2) treats
  "`Tobii Service` not Running OR engine process absent" as a fault → recovery at
  level 2 (level 1 runtime-restart can't start the middleware), same threshold +
  calibration guard, plus a **240s post-boot grace** (`-BootGraceSec`) so it never
  fights delayed auto-start; (3) `-OnWake` does the same stack check; (4) `-Once`
  prints stack/trust status. Would have auto-recovered this incident ~1 min after
  logon. Watch for false recoveries (e.g. Tobii Service legitimately stopped
  long-term).
- **2026-07-06 late evening — MODE E discovered & fixed: "gaze fine, cursor warp
  dead" = Tobii.EyeX.Interaction's PTP session wedged.** Incident investigated
  live before recovery. Every layer healthy: device OK, runtime log clean, engine
  Tracking at normal CPU, Experience face tracking fine — yet cursor warp did
  nothing. KEY INSIGHT: warp is delivered by `Tobii.EyeX.Interaction` sending
  phantom-touch input through the **Tobii Touchpad Filter Driver** on the
  physical precision touchpad; the InteractionLog keeps logging "PTP
  communication: Flush sent" (and warp conceal/restore events) into the dead
  pipe with no error, so there is NO passive log signature. Broken-vs-healthy
  startup logs are identical. Proven by the fix: restarting ONLY the interaction
  process restored warp instantly. Learned: Tobii.Service does NOT respawn a
  killed interaction process, and it runs elevated (non-admin Stop-Process
  denied). Likely trigger: a full-stack restart respawns interaction seconds
  BEFORE the engine reaches Tracking; it binds a dead PTP session and never
  retries. FIXES: (1) watchdog `-RestartInteraction` mode; (2) prevention —
  after level-2 recovery / -ForceReconnect the watchdog waits (≤90s) for a FRESH
  `Tracking` line (timestamp-checked) then bounces interaction; (3) tray "Fix
  cursor warp" → on-demand elevated `TobiiFixWarp` task (installer registers
  it). Failure modes now: A=WaitingForDevice drop (auto), B=stalled gaze
  timestamps (blind), C=streaming-but-invalid (blind), D=calibration lost
  (profile = `...\Tobii Platform Runtime\<platform>\<serial>\calibration.setpm`),
  E=interaction PTP wedge (FixWarp; auto-prevented after recoveries).
- **2026-07-07 midnight — MODE B/D caught live: the watchdog's first FALSE
  recovery, and silent-stall detection built.** Timeline: the device flapped on
  the USB bus (3 re-enumerations in 5s — `pr_log` "Could not get calibration
  version for device" bursts in `setup_device_info`) → Mode A drop → watchdog
  ran the ladder and logged "Recovered: state is now 'Tracking'" — **but the
  engine was lying.** It sat 22 min claiming `Tracking` at ~0.3% CPU (healthy
  tracking with a user present is **8–13%**), started only the *presence*
  stream, never a gaze stream, and dropped straight into power save. The device
  had come back **without usable calibration** (Experience prompted to
  recalibrate; the on-disk `calibration.setpm` was intact — the device/runtime
  just wouldn't load it, and calibration sync wrongly said "in sync"). Neither
  an interaction bounce nor a full reconnect w/ USB power-cycle fixed it; ONLY
  recalibrating did (which rewrites `calibration.setpm` — that timestamp is a
  reliable "user recalibrated" signal). KEY INSIGHT: **engine CPU is a passive,
  reliable gaze-health signal** — the missing detector for modes B/C/D — when
  gated on the user actively giving console input (`GetLastInputInfo`), since
  an idle engine is legitimate when nobody is in front (power save). FIXES:
  (1) watchdog **silent-stall check**: every 60s while state=Tracking, if the
  user is active (input <60s ago) and engine CPU <1.5% over a 12s sample, twice
  in a row → stall ladder: stack restart → full reconnect (USB power-cycle) →
  raise `tobii-recal-needed.flag`; every step verified by *actual CPU*, not the
  state line; 45-min cooldown caps the lid-closed-on-external-monitor false
  positive; (2) tray: red icon + balloon nag every 5 min while the flag is up,
  "Recalibrate now" menu item + balloon click → opens the Tobii Experience app
  (PackageFamilyName looked up live); (3) watchdog auto-clears the flag when
  `calibration.setpm` is rewritten (user recalibrated) or the stall clears.
  Modes B and D are now DETECTED (not blind); D still needs human eyes for the
  recalibration itself.
- **IR illuminator LEDs go dark on every drop** (new section 5a). The visible IR
  LEDs in the tracker bezel go out whenever tracking stops and return on recovery →
  the runtime tears down the device's active imaging session (not just a middleware
  glitch), consistent with and downstream of the connection-loss root cause. Best
  human-visible ground truth that a drop is real; cannot be used as an automated
  signal (sensing the LEDs = opening a device/stream session = the §6 hardware
  reset). Action item: note LED state during a Mode B silent stall.
- **Tracker can hang mid-USB-enumeration and fall off the bus (auto-recovered, no
  reboot).** Distinct from both the calibration loss (Mode D) and a normal PRP drop
  (where the device still reads OK): after a hibernate/sleep resume the IS5 firmware
  can wedge, drop its real id (`VID_2104&PID_030C`) and re-appear as a generic
  `VID_0000&PID_0002` **"Device Descriptor Request Failed"** node on the same hub port
  (`present=False`). Plain service/engine restarts can't help — there is no device to
  talk to — so the watchdog now **re-enumerates the tracker's own USB port**: it
  disables+enables *both* the real tracker node and the descriptor-failed stand-in on
  that port (the connection locator is read at runtime, never hardcoded), then rescans.
  This recovered a fully-off-the-bus device live with no reboot. It touches only the
  tracker's port — never the parent hub, which also carries the keyboard — and verifies
  the device ends enabled, which is why it's safe in the automatic ladder (a *blanket*
  USB power-cycle stays manual-only; it once left the device disabled). If even a port
  re-enumeration can't bring it back, that's a firmware/hardware wedge only a reboot
  clears: the watchdog stops thrashing and raises a distinct **"reboot needed"** tray
  notification instead of a recalibration one.
- **Gaze-cursor warp self-heals after every recovery, not just full restarts.** A
  level-1 recovery (runtime-service restart only) fixes a connection drop but breaks
  the interaction<->engine PTP binding, so gaze comes back while the eyes-move-cursor
  *warp* stays dead. The post-recovery interaction re-bind now runs after **every**
  recovery level (it previously ran only at level 2+), so the warp re-binds whenever
  gaze returns -- no manual "Fix cursor warp" needed.
- **A descriptor-hung tracker cannot be revived by ANY software path — only power
  removal.** Second hard wedge in two days proved this exhaustively. The drop happened
  while the machine was *awake* under heavy CPU load (no sleep/resume involved), so the
  enumeration-hang is not a resume-only failure. With the device off the bus
  (`present=False`, descriptor-request-failed), an elevated escalation ladder was run:
  removing all stale devnodes + rescan (the port then enumerates *nothing* — the device
  is electrically mute), restarting the parent root hub, disable/enable of the hub,
  restarting the xHCI host controller, disable/enable of the controller, and finally
  `pnputil /remove-device /subtree` on the controller itself. Every hub/controller
  operation was vetoed online ("system reboot is needed") because in-use children
  prevent releasing the hub, and the first deferred operation poisons all later ones
  on that node. Conclusion: once the watchdog's own port re-enumeration fails, the
  firmware is wedged below anything software can reach; the reboot-needed flag is the
  correct terminal state, and a full shutdown (power removal — not a warm restart) is
  the only fix. Gotchas for anyone attempting this: PowerShell's `Disable-PnpDevice`
  (CIM) returns "Not supported" for root hubs and host controllers — use
  `pnputil /disable-device | /enable-device | /restart-device` instead; and
  `pnputil /scan-devices` requires elevation, so verify results from a log rather than
  assuming silenced cmdlets ran. Also confirmed: `nhi` (Thunderbolt host-interface)
  errors that appear during rescans are a red herring — the idle TB controller waking
  into RTD3 when the scan pokes all buses, unrelated to the tracker's fabric.
- **Session unlock — not just sleep — triggers the enumeration wedge; the watchdog
  now bursts on unlock.** Decoding the Winlogon/Operational 811 notification codes
  (2=logon, 3=logoff, 4=lock, 5=unlock) showed both hard USB wedges happened seconds
  after a session *unlock*: one after a hibernate wake, and one on a machine that had
  been awake the whole time — locked for 71 minutes running builds, tracker dead 28
  seconds after unlock. Mechanism: at lock the Tobii runtime idles the tracker
  (illuminators off, imaging session closed); at unlock it re-activates the device,
  and that idle→reactivate power transition is what the IS5 firmware wedges on.
  Sleep/hibernate is merely one way to produce the same edge. The catch for a
  watchdog: lock/unlock produces **no clock gap and no Windows power event**, so
  resume detection stays silent. Fix: the main loop watches for the lock screen via
  the `LogonUI` process and, on the locked→unlocked edge, enters the same aggressive
  burst window as a resume (fast checks, act on first strike). While locked it adds
  nothing — the engine legitimately idles there, and the stall detector already
  requires user activity before acting.
- **Preventive at-lock reconnect — catching the wedge before it happens.** The hard
  wedge gave a full hour of warning: repeated silent-stall samples (engine at ~0% CPU
  while the user was active) below the action threshold. Acting mid-use would disrupt
  the user, but the moment the session *locks* is the perfect intervention point — the
  user is away, and the next danger is precisely the unlock reactivation. So every
  degradation sample now increments a counter that only a full reconnect (a genuine
  clean re-enumeration — not a mere calibration re-apply) clears; on the
  unlocked→locked edge, if two or more samples have accumulated, the watchdog runs a
  full reconnect + calibration re-apply right then. The device rides out the lock
  freshly enumerated instead of idling in a fragile state, and unlock starts clean.
  Healthy devices are left alone, so there is no churn; the preventive pass is skipped
  when the tracker is already off the bus (the fault ladder owns that), the stack is
  down, or a reboot is pending. Caveat if you use Windows Hello face login: the
  reconnect makes the camera briefly unavailable at the start of a lock — check
  `WbioSrvc` before enabling this pattern on a Hello machine.
- **A ~10-second sleep/wake revives a descriptor-hung tracker — no reboot needed.**
  The definitive diagnosis came from dropping below the (reboot-pending-poisoned) PnP
  layer entirely: opening the hub's device interface directly
  (`\\?\USB#ROOT_HUB30#...#{f18a0e88-c30c-11d0-8815-00a0c906bed8}` — this works even
  when the hub's devnode has been deferred-removed, and even without elevation) and
  issuing `IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX` per port. That returns the
  *electrical* truth of the bus, independent of every devnode: the wedged tracker's
  port read **NoDevice** — the hung MCU stops asserting bus presence entirely, which
  is why no software path (PnP, pnputil, or `IOCTL_USB_HUB_CYCLE_PORT`, which fails
  with win32 error 433 on an electrically empty port) can reach it. Caution: devnode
  locator numbers did NOT match electrical ports (phantom devnodes claimed ports the
  survey showed empty) — trust the survey, not the instance IDs. The fix: S3 sleep
  cuts the tracker's power rail on this laptop, so a ~10s sleep/wake reboots the
  tracker's firmware; it re-asserted presence, the devnode re-created itself, and the
  watchdog's on-wake handler restored the stack, calibration and warp automatically.
  Session, terminals and running builds all survive — vastly cheaper than the full
  shutdown previously believed necessary. The tray's terminal notification now says
  SLEEP/WAKE instead of REBOOT. Survey/cycle tool: `CyclePort.ps1` (hub instance ID
  inside is machine-specific — adjust for your hub).
- **Recovery must be visible, or it looks like failure.** A routine drop was caught
  and fixed by the ladder in ~3.5 minutes with zero intervention — but the user
  couldn't tell the watchdog was on it (dark IR LEDs during recovery look identical
  to a dead watchdog) and escalated manually. Fix: the watchdog now writes a
  `recovering` flag while its ladder runs (cleared on health, on startup, and by the
  uninstaller), and the tray shows an orange icon + one balloon per episode: "drop
  caught - auto-recovering, typically back in 1-4 min, no action needed." Tray UX
  also reworked: LEFT-click now opens the same menu as right-click instead of
  silently toggling pause (the silent-pause landmine, hit twice), Pause/Resume is
  the top menu item, and the palette is green=active, orange=recovering,
  yellow=paused (manual or game), red=failure (recalibration / sleep-wake needed).
- **Recovery latency audit: the "4-minute outage" was conservatism, not blindness —
  and 100+ seconds of it was cuttable.** Breakdown of a level-2 outage: ~38s
  detect/confirm (fine), 1s level-1 restart, **90s** waiting out the full
  verify-timeout while the engine sat parked in a fresh WaitingForDevice (useless —
  the device was never coming back at that level), 45s anti-thrash grace, **30s**
  re-confirming a fault that had never cleared, then ~95s for the level-2 stack
  restart + engine boot (the hard floor — the engine takes ~90s to reach Tracking).
  Fixes: (1) Wait-ForTracking now FAILS FAST when the restarted engine parks in a
  fresh WaitingForDevice for 15s continuously (after a 20s settle) — escalation
  starts ~60s sooner; (2) between ladder rungs the fault re-confirmation drops from
  the full threshold to 10s (it was already continuously confirmed); (3) detection
  threshold 30s -> 20s and inter-rung grace 45s -> 25s. Net: a level-1 drop heals
  in ~1.5-2 min (engine boot dominates, unchangeable) and a level-2 drop in ~3 min
  instead of ~4.5. The engine's own ~90s boot-to-Tracking is the floor no watchdog
  can cut.
- **Sleep stays manual, always.** The watchdog never suspends the machine itself
  (zero suspend calls in it — verified); a surprise sleep would be worse than a dead
  tracker. When the power-wedge state is detected the tray turns ORANGE ("needs
  sleep") and points at the one-click SleepWake button; blue now means
  auto-recovering. Final palette: green = active, blue = recovering, orange = needs
  a manual sleep, yellow = paused, red = recalibration needed.
