# SlapMac

Smash Time

SmashMode reads the raw accelerometer inside Apple Silicon MacBooks at ~800 Hz, runs a four-algorithm voting system to distinguish genuine impacts from typing and ambient vibration, and plays a sound effect scaled to how hard you hit it.

---

## Requirements

| | |
|---|---|
| Mac | Apple Silicon (M1 or later) — the SPU accelerometer doesn't exist on Intel |
| macOS | 13 Ventura or later |
| Build tools | Xcode Command Line Tools — `xcode-select --install` |

No Xcode IDE required. Everything builds with `swiftc` via a single shell script.

---

## Build

```bash
git clone <this repo>
cd SlapMac
bash build.sh
```

Output:

```
build/
├── SlapMacDaemon          ← privileged background process
└── SlapMac.app            ← menu bar app
```

If you want to regenerate the placeholder WAV files (or add to them):

```bash
python3 Sounds/generate_sounds.py
bash build.sh              # re-copies sounds into the bundle
```

---

## Run

Two processes, two terminals:

```bash
# Terminal 1 — daemon needs root to open the IOKit HID device
sudo ./build/SlapMacDaemon

# Terminal 2 — menu bar app (or double-click the .app)
open ./build/SlapMac.app
```

The menu bar icon shows a hand (✋ connected, 🚫 daemon not running). Slap the laptop. Pick a sound profile from the menu.

To stop:

```bash
sudo pkill SlapMacDaemon
```

---

## Sound profiles

The Sound Profile menu is built dynamically at startup from whatever audio files are bundled inside the app. There are no hardcoded lists.

| Profile | Sounds |
|---|---|
| 🎵 All Sounds (default) | every file in `Sounds/` |
| one entry per file | e.g. `dangit`, `lizard`, `slap`, … |

Switch profiles from the menu bar icon → **Sound Profile**. The selected profile is checkmarked and takes effect immediately.

### Adding your own sounds

1. Drop any `.wav` or `.mp3` into `Sounds/`.
2. Run `bash build.sh`.

That's it — the new file appears automatically in the Sound Profile menu on next launch. No code changes needed.

---

## Architecture

```
MacBook chassis
      │  physical impact
      ▼
Bosch BMI286 IMU (inside Apple Silicon SoC, ~800 Hz)
      │  22-byte HID report via IOKit
      ▼
SlapMacDaemon  (runs as root)
      │
      ├── AccelerometerReader   reads raw X/Y/Z from the SPU
      ├── ImpactDetector        four-algorithm voting → ImpactEvent
      └── SocketServer          streams JSON over /var/run/slapmac.sock
                                        │
                                        ▼
                              SlapMacApp  (menu bar, runs as user)
                                        │
                              DaemonConnection   reads JSON from socket
                                        │  Combine publisher
                              AudioManager       plays sound scaled to force
```

The daemon/app split exists purely because IOKit HID requires root for the Apple SPU sensor. The unprivileged menu bar app handles the UI and audio.

ImpactEvents are transmitted as newline-delimited JSON:

```json
{"timestamp":1712000000.123,"magnitude":0.72,"algorithms":["magnitude","sta_lta","kurtosis"]}
```

`magnitude` is normalised 0.0–1.0 and drives both volume (0.35–1.0) and which player from the pool is selected.

---

## How the accelerometer is accessed

### The hardware

The Bosch BMI286 IMU lives inside the Apple Silicon SoC package (the "SPU" — Sensor Processing Unit). It is not exposed as a standard motion sensor via CoreMotion on macOS. Instead it appears as an IOKit HID device.

### The IOKit path

Most IOKit HID tutorials tell you to match by usage page `0x0020` (HID Sensor) / usage `0x0068` (Accelerometer 3D). That's the generic spec. Apple's SPU ignores it.

The actual path:

```
1. Wake the driver
   IOServiceMatching("AppleSPUHIDDriver")
   → set SensorPropertyReportingState = 1
   → set SensorPropertyPowerState     = 1
   → set ReportInterval               = 1000  (µs → ~1 kHz)

2. Enumerate the device
   IOServiceMatching("AppleSPUHIDDevice")
   → filter: PrimaryUsagePage = 0xFF00  (Apple vendor page)
              PrimaryUsage    = 3        (accelerometer on that page)
   → IOHIDDeviceCreate(kCFAllocatorDefault, service)

3. Open → register callback → schedule  (order matters)
   IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone)
   IOHIDDeviceRegisterInputReportCallback(device, buf, 4096, cb, ctx)
   IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), defaultMode)
```

Credit to [taigrr/apple-silicon-accelerometer](https://github.com/taigrr/apple-silicon-accelerometer) for reverse-engineering the vendor page, usage ID, and driver property names.

### Report format

Each callback delivers a 22-byte report:

```
Byte offset   Content
───────────   ───────────────────────────────────────────
0 – 5         Header / report ID / flags
6 – 9         X  (signed int32, little-endian, Q16.16)
10 – 13       Y
14 – 17       Z
18 – 21       Timestamp / padding
```

Q16.16 fixed-point means divide by 65536 to get g-force. At rest flat on a desk you'll read approximately X≈0, Y≈0, Z≈1 g.

### The buffer stability gotcha

Swift's `&array` syntax creates a **temporary** pinned pointer for the duration of the function call only. `IOHIDDeviceRegisterInputReportCallback` stores the pointer and writes to it asynchronously on every report. If you pass `&swiftArray`, the buffer is unpinned before the first report ever arrives and callbacks silently stop firing.

Fix: allocate with `UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)`. This gives a stable heap address that IOKit can hold forever — equivalent to Go's explicit `gcRoots = append(gcRoots, buf)` pattern.

---

## Impact detection algorithm

The `ImpactDetector` uses four independent algorithms. An impact fires only when at least **two agree** (configurable via `requiredVotes`) and the 400 ms cooldown has elapsed.

### Gravity removal

Before any algorithm runs, the raw vector magnitude has a slow exponential moving average (α = 0.995, time constant ~2 seconds) subtracted from it. This strips out the ~9.81 m/s² of static gravity and leaves only dynamic acceleration. The detector becomes orientation-agnostic — it doesn't matter whether the lid is open or the laptop is tilted.

```
dyn = max(0, ||(x, y, z)|| − EMA(||(x, y, z)||))
```

### Algorithm 1 — Magnitude threshold

The simplest algorithm: did the dynamic acceleration exceed a minimum force floor? The floor scales with sensitivity (0.5–2.5 m/s²). Catches obvious hard slaps; misses gentle taps.

### Algorithm 2 — STA/LTA (Short-Term Average / Long-Term Average)

Borrowed from seismology, where it is used to detect P-wave arrivals in continuous seismograms.

```
STA  = mean(window[-16:])       ≈ last 20 ms  @ 800 Hz
LTA  = mean(window[-400:])      ≈ last 500 ms
ratio = STA / LTA
```

A sudden impact creates a large spike in the short-term average while the long-term average is still near zero. Ratios above 3–6× (sensitivity-dependent) trigger a vote. This is robust against slow ambient vibration (e.g., music, fans) that raises both averages equally.

### Algorithm 3 — CUSUM (Cumulative Sum control chart)

CUSUM is a sequential change-point detection algorithm from statistical quality control. It accumulates positive deviations from a slowly-adapting reference level:

```
S_t = max(0, S_{t-1} + dyn_t − ref_t − k)
```

where `k = 0.4` is a slack parameter and `ref_t` drifts at 0.05% per sample. When `S_t` exceeds a threshold (4–10, sensitivity-dependent), a structural change in the signal has occurred. CUSUM is particularly good at catching sustained vibration buildup that magnitude and STA/LTA might miss.

### Algorithm 4 — Kurtosis

Kurtosis measures the "tailedness" of a distribution — how much of the variance comes from rare extreme values vs. the bulk of samples.

```
kurt = E[(x − µ)⁴] / σ⁴
```

A Gaussian distribution has kurtosis 3. Pure noise has low kurtosis. An impact looks like a very short, very large spike in an otherwise quiet signal — kurtosis of 5–7+ (sensitivity-dependent) on the last 32 samples (~40 ms). This makes kurtosis excellent at distinguishing percussive impacts from the relatively smooth vibration of typing.

### Force normalisation

Once an impact fires, the raw dynamic acceleration is soft-clipped to 0–1:

```
normalizedForce = min(1.0, dyn / 6.0)
```

6 m/s² is calibrated as a "hard slap" ceiling. The normalised value drives audio volume (0.35 + force × 0.65) so a light tap sounds quieter than a full slap.

---

## Tuning

| Parameter | Location | Effect |
|---|---|---|
| Sensitivity | Menu bar → Sensitivity | 👆 Any tap / 🖐 Medium / 🤜 Hard slaps only |
| `requiredVotes` | `ImpactDetector.swift` | 1 = any algorithm fires, 4 = all must agree |
| `cooldown` | `ImpactDetector.swift` | Minimum seconds between impacts |

Sensitivity is applied in the app — no rebuild needed when changing it. It gates on the impact's normalised force (0–1), so lighter hits are filtered out at higher settings.

If you still get false positives while typing, increase `requiredVotes` to 3 in `ImpactDetector.swift` and rebuild.

---

## Project structure

```
SlapMac/
├── build.sh                     ← builds everything, no Xcode needed
├── Shared/
│   └── ImpactEvent.swift        ← JSON-serialisable event shared by both targets
├── SlapMacDaemon/               ← root process, IOKit + detection
│   ├── main.swift
│   ├── AccelerometerReader.swift
│   ├── ImpactDetector.swift
│   └── SocketServer.swift
├── SlapMacApp/                  ← unprivileged menu bar app
│   ├── AppDelegate.swift
│   ├── MenuBarController.swift  ← menu bar, sensitivity, dynamic profile menu
│   ├── AudioManager.swift       ← scans Sounds/ at startup, no hardcoded list
│   ├── DaemonConnection.swift
│   └── Info.plist
└── Sounds/
    ├── generate_sounds.py       ← synthesises placeholder WAVs
    ├── slap.wav / thwack.wav / moan.wav / scream.wav / oof.wav
    ├── lizard.mp3               ← 🦎
    ├── dangit.mp3
    └── (add any .wav or .mp3 here and rebuild — no code changes needed)
```

---

## Troubleshooting

**Daemon exits immediately with "must run as root"**
→ Use `sudo ./build/SlapMacDaemon`.

**"[AccelerometerReader] IOHIDDeviceOpen failed"**
→ Confirm you ran with `sudo`. The Apple SPU requires root.

**App shows "○ Daemon not running"**
→ Start the daemon first, or check `/var/run/slapmac.sock` exists.

**No sound despite impacts being logged**
→ Check that `Sounds/` files were copied into the bundle (`build/SlapMac.app/Contents/Resources/Sounds/`). Re-run `bash build.sh`.

**False positives while typing**
→ Lower sensitivity in the menu bar, or increase `requiredVotes` to 3 in `ImpactDetector.swift` and rebuild.

**Works on M1/M2 but not M3/M4**
→ The SPU device path may have changed. Run `sudo /tmp/hidscan` (compile `Tools/HIDScan.swift` if needed) to inspect the current device tree.
