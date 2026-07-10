# Tobii IS5 Firmware Bug Dossier

Consolidated findings for the planned firmware-level fix. Written 2026-07-10 after a
day that produced one hard USB wedge and six recovery episodes. This is the handoff
document: everything known about the defect, the evidence behind each claim, and the
concrete starting points for attacking the firmware itself.

Companion running changelog: `C:\Scripts\TOBII-FINDINGS.md`. Watchdog suite repo:
https://github.com/sweets2/tobii-is5-watchdog

---

## 1. Executive summary

The integrated Tobii IS5 ("YAMATO17") eye tracker in this Alienware m17 R2 has a
firmware defect in its **idle -> reactivate transition path**. Every time the device
is idled (session lock, sleep, hibernate, runtime power-save) and then reactivated,
its microcontroller races through USB resume + re-enumeration + imaging-session
restart. When it loses that race, one of two things happens:

- **Soft failure** (common, several times/day): the engine drops to
  `WaitingForDevice` or silently stalls (claims `Tracking`, ~0% CPU). Software
  recovery works: service restarts, calibration re-apply, port re-enumeration.
- **Hard wedge** (rare until this week; twice in the last 2 days): the MCU hangs so
  completely it **stops asserting electrical presence on the USB bus** (hub reports
  `NoDevice` on its port). No software on Earth can reach it at that point; only
  removing its power rail reboots it. A ~10s S3 sleep/wake does exactly that.

The device has **no functioning internal watchdog** — a crashed MCU stays crashed
until external power removal. That is the core firmware bug to fix (or the vendor's
to fix via a firmware update, which should be checked first).

---

## 2. Device identity

| Field | Value |
|---|---|
| Marketing | Tobii IS5 integrated eye tracker (Alienware m17 R2) |
| Platform codename | IS5 `YAMATO17` (service: `TobiiIS5YAMATO17`) |
| USB | `VID_2104&PID_030C`, devnode friendly name **"EyeChip"** |
| Serial | IS5xx-XXXXXXXXX |
| Wedged identity | drops VID_2104, reappears as `VID_0000&PID_0002` "Device Descriptor Request Failed", then disappears from the bus entirely |
| Bus location | Intel PCH xHCI (`VEN_8086&DEV_A36D`), root hub `ROOT_HUB30\4&91c6074&0&0`, **electrical port 9** (24-port hub) |
| Host stack | Tobii Service + TobiiIS5YAMATO17 services, Tobii.EyeX.Engine (gaze), Tobii.EyeX.Interaction (cursor warp), legacy EyeX pipeline |
| Calibration | `C:\ProgramData\Tobii\Tobii Platform Runtime\IS5YAMATO17\<serial>\calibration.setpm` (9-pt, ~377 KB blob), re-appliable live via engine IPC (`Tobii-CalReapply.exe`) |

**CRITICAL CONSTRAINT:** a second concurrent Stream Engine gaze subscriber makes the
hardware reset every ~2-3 s. All monitoring must stay passive (log reading + process
CPU). Never subscribe to the gaze stream.

---

## 3. Failure taxonomy (all observed live)

| Mode | Signature | Root event | Fix |
|---|---|---|---|
| A: PRP drop | state `WaitingForDevice`, device still OK on bus | runtime connection loss | restart runtime service (level 1) or full stack (level 2) |
| B: silent stall | state says `Tracking`, engine ~0-0.3% CPU (healthy: 8-40%), IR dark | false recovery / stalled imaging session | calibration re-apply, else stack restart |
| D: calibration wipe | tracking "up" but 0% CPU after hibernate/sleep; device forgot calibration | power loss to device wiped volatile calibration state | re-apply stored calibration blob (no dots needed) |
| E: warp dead | gaze engine healthy (CPU normal), cursor does not follow | interaction<->engine PTP binding broken by a service restart | bounce Tobii.EyeX.Interaction |
| HARD WEDGE | device electrically ABSENT (hub port reads `NoDevice`); descriptor-failed phantom devnode | MCU crash in resume/re-enumeration path; no internal WDT | POWER REMOVAL ONLY: ~10s S3 sleep/wake (proven), or full shutdown |

## 4. Root-cause chain (evidence-backed)

1. **Trigger: session UNLOCK** (not sleep per se). Winlogon 811 notification codes
   decoded: 2=logon, 3=logoff, 4=lock, 5=unlock. Both hard wedges followed an
   unlock within seconds: 07-09 unlock 10:48:18 -> dead in 11 s (after hibernate);
   07-10 unlock 12:05:13 -> dead in 28 s (machine AWAKE the whole time, locked 71
   min; zero power events 11:00-13:00 — rules out sleep as a necessary factor).
2. **Mechanism:** at lock, the Tobii runtime idles the tracker (IR off, imaging
   session closed). At unlock it reactivates it. The reactivation makes the MCU do
   USB resume + re-enumeration + imaging restart; a race/state-machine bug in that
   path can hard-hang it. Once hung it stops driving the USB data lines entirely.
3. **Amplifier:** the 07-09 mid-install GPU BSOD left Windows on Basic Display
   Adapter. Drop rate went from ~1/day to ~hourly immediately after (see section
   5). Tobii is tightly coupled to display state for gaze->screen mapping; every
   messy display/session transition is another roll of the dice.
4. **Why it stays dead:** no (functioning) internal watchdog timer in the firmware.
   A crashed MCU never self-resets. External power removal is the only reset line.

## 5. Frequency data (watchdog log, complete since 2026-07-05)

Recovery episodes per day (distinct level-1 entries) + confirmed silent stalls:

| Date | Episodes | Silent stalls | Notes |
|---|---|---|---|
| 07-05 | 6 | - | |
| 07-06 | 3 | 2 (telemetry) | |
| 07-07 | 1 | 8 | stall detector's first day |
| 07-08 | 1 | 3 | quiet baseline: ~1-3/day |
| 07-09 | 8 | 1 | GPU BSOD mid-driver-install this day; first hard wedge 23:49 |
| 07-10 | 6 | (1 pending) | second hard wedge 12:05; evening cluster: 17:24, 17:50, 18:01 = 3 episodes in 37 min |

Reading: baseline was ~1-3 episodes/day (all auto-healed, mostly invisible). Since
the half-installed GPU driver: 6-8/day with clustering — the 07-10 evening cluster
is one episode every ~12 minutes. The user-visible experience "it goes down all the
time" dates precisely from the 07-09 BSOD.

## 6. What software can and cannot do (all proven, not theorized)

CAN (the watchdog does all of this automatically):
- Restart runtime/middleware services, kill/respawn engine + interaction
- Re-apply the stored calibration blob to a live device via engine IPC (fixes Mode D with no user dots)
- Re-enumerate the tracker's own USB port incl. the descriptor-failed phantom node (recovers a device that is failing enumeration but still electrically present)
- Read per-port ELECTRICAL truth from the hub driver (`IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX` via `CyclePort.ps1`) — works below/despite poisoned PnP state, even non-elevated
- Trigger S3 sleep with a kernel resume timer for hands-free power-cycle (`SleepWake-Tracker.bat`; wake timers enabled on AC only)

CANNOT (each exhaustively attempted against a hard wedge, 2026-07-10):
- Reach a device that stopped asserting bus presence: devnode removal + rescan, hub restart/cycle, xHCI restart/cycle, controller subtree removal, `IOCTL_USB_HUB_CYCLE_PORT` (fails win32=433 — the port is electrically EMPTY)
- Cut VBUS to the internal port from software (hub does not expose per-port power switching for it)
- Expect PowerShell `Disable-PnpDevice` to work on hubs/controllers ("Not supported" — must use pnputil, and even that gets deferred-to-reboot when children are in use)

Gotchas that cost hours: devnode locator numbers do NOT match electrical ports
(trust the hub survey); `nhi` System-log errors during rescans are the idle
Thunderbolt controller waking (red herring); the WSL->powershell.exe bridge is
non-elevated and `-ErrorAction SilentlyContinue` hides the access-denied.

## 7. Current defenses (watchdog suite, all live as of 07-10 17:41)

- Passive fault detection: state log + stack presence + engine-CPU stall sampling (20s confirm, 5s poll)
- Escalating ladder: runtime restart -> full stack -> port re-enumeration -> sleep/wake-needed flag; fail-fast escalation (no more 90s waits on a parked WaitingForDevice); warp re-bind after every level
- Wake/unlock coverage: clock-gap resume detection + LogonUI-based unlock detection, both enter a 150s burst window (15s checks, act on first strike)
- Preventive: at session LOCK with accumulated degradation samples -> full clean reconnect while the user is away (the unlock then starts from a fresh device)
- Visibility: tray icon green/orange/yellow/red (active/recovering/paused/failure) + one balloon per recovery episode; left-click = menu (no more silent pause toggling)
- Latency floor: the engine takes ~90s to boot to Tracking; level-1 outage ~1.5-2 min, level-2 ~3 min. No watchdog change can beat the engine boot time.
- KNOWN BLIND SPOT: the stall detector requires recent user input; for a gaze-mouse user a dead tracker CAUSES input idle, suppressing its own detection (catch-22, found 07-10 18:09). Fix planned: allow idle-time stall recovery with more strikes.

## 8. Firmware attack plan (the future project)

Goal: stop the MCU from hard-hanging on idle->reactivate, or make it self-recover.

### 8.0 Before touching firmware — cheaper levers to try first
1. **Check for a vendor firmware update.** Tobii Experience / Tobii Service ships a
   firmware upgrade tool; Dell may also bundle IS5 firmware in a driver pack.
   Determine current FW version (Tobii Experience about panel, or the platform
   runtime logs at startup) and compare. A YAMATO17 update may simply fix this.
2. **Device-level USB power management registry switch:** under
   `HKLM\SYSTEM\CurrentControlSet\Enum\USB\VID_2104&PID_030C\<serial>\Device Parameters`
   try `EnhancedPowerManagementEnabled=0` (and/or `AllowIdleIrpInD3=0`,
   `DeviceSelectiveSuspended=0`). This stops Windows from putting the device into
   low-power idle at all — if the idle edge never happens, the race never runs.
   Low risk, reversible, survives reboots. TRY THIS FIRST.
3. **Stop the runtime from idling the device at lock:** hunt for power-save options
   in Tobii service config (`C:\ProgramData\Tobii*` JSON/XML configs, service
   registry keys). If the runtime keeps the imaging session alive at the lock
   screen, the unlock reactivation disappears.
4. **Ask Tobii.** The IS5 is integrated OEM hardware; support may have a known-issue
   firmware or an engineering tool. Mention: descriptor hang after resume, device
   drops off bus, requires power removal.

### 8.1 Reconnaissance (no risk)
- Locate firmware images on disk: search Tobii Service / Platform Runtime install
  dirs and `C:\ProgramData\Tobii` for firmware blobs (`*.iff`, `*.fw`, `*.bin`,
  upgrade packages mentioning YAMATO/IS5). The upgrade tool that ships with the
  stack must read them — its file formats are the way in.
- Capture the failure on the wire: USBPcap/Wireshark session across a lock/unlock
  cycle (and a sleep/wake) to see exactly which USB transaction the device dies on
  (expected: it ACKs resume signaling then never answers GET_DESCRIPTOR).
- Identify the MCU: photograph the module (bezel teardown), read the chip markings;
  correlate with firmware image architecture (entropy scan / disassembly probe).
  The devnode name "EyeChip" suggests Tobii's custom ASIC + companion MCU: confirm.
- Dump USB descriptors of the healthy device (lsusb -v equivalent / USBTreeView
  export) — needed later to verify a patched device still enumerates identically.

### 8.2 Analysis targets in the firmware image
- The USB suspend/resume interrupt handlers (the crash lives here).
- Watchdog timer configuration: is there a WDT that is disabled or never kicked?
  Enabling a WDT that resets the MCU on hang would convert every future hard wedge
  into a ~1s self-recovery — arguably the single highest-value one-bit patch.
- Version strings / build info for exact-version vendor escalation.

### 8.3 Risks to respect
- The device is integrated: a bricked EyeChip cannot be swapped without board work.
  Never flash a modified image without (a) a verified factory image to restore,
  (b) confirmation the upgrade tool can force-flash a device in DFU/bootloader
  mode even when the app firmware is dead.
- The calibration blob and serial live device-side; preserve/back up whatever the
  upgrade tool can read before writing anything.

## 9. Open questions
1. Does a vendor firmware update for IS5 YAMATO17 exist that fixes resume hangs?
2. Does `EnhancedPowerManagementEnabled=0` prevent the idle edge entirely? (Best
   cheap fix candidate — test for a week and compare episode counts vs section 5.)
3. What exact USB transaction does the MCU die on (needs USBPcap capture)?
4. Is there a DFU/bootloader mode reachable when app firmware is hung?
5. Why did 07-05 log 6 episodes (pre-BSOD)? Check what that day's system events
   show — possibly an earlier instability period, possibly hot weather.
6. Does finishing the Intel GPU driver install return the rate to ~1-3/day?
   (Measure section-5 style for a week after the reboot.)

## 10. Artifacts inventory
- `C:\Scripts\Tobii-Watchdog.ps1` — the watchdog (all detection + recovery)
- `C:\Scripts\Tobii-Tray.ps1` — tray UI (status colors, balloons, manual actions)
- `C:\Scripts\Tobii-CalReapply.exe` — live calibration re-apply via engine IPC
- `C:\Scripts\CyclePort.ps1` — hub-driver electrical port survey + port cycle
- `C:\Scripts\SleepWake-Tracker.bat/.ps1` — one-click self-waking power-cycle (+ Desktop copy)
- `C:\Scripts\Fix-TrackerUsb.bat/.ps1` — elevated 5-step USB escalation ladder
- `C:\Scripts\Enable-WakeTimers.bat` — one-time wake-timer policy (AC only)
- `C:\Scripts\TOBII-FINDINGS.md` — dated running changelog (machine-specific master; NEVER overwrite from repo)
- `C:\Scripts\tobii-watchdog.log`, `Tobii-Telemetry.jsonl` — evidence logs
- Repo (public, scrubbed): github.com/sweets2/tobii-is5-watchdog
