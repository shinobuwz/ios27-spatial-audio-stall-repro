# SpatialAudioStallRepro

Minimal reproduction for an **iOS 27.0.1 / AVAudioSession** bug, intended for an
Apple Feedback Assistant report. AVFoundation only — no third-party SDK, no
Agora, no Wwise.

**The bug:** on AirPods with system Spatial Audio enabled, when another
AudioUnit in the process is still rendering over A2DP, switching the shared
`AVAudioSession` to `playAndRecord` + `voiceChat` (HFP) blocks the calling thread
for seconds per call:

`setCategory:withOptions:error:`, `setMode:error:`,
`inputNumberOfChannels`, `outputNumberOfChannels`,
`setPreferredSampleRate:error:`, `setPreferredIOBufferDuration:error:`,
`setPreferredInputNumberOfChannels:error:`,
`setPreferredOutputNumberOfChannels:error:`, `setActive:error:`

Stop the rendering AudioUnit before the same sequence and every call returns in
well under 2 ms.

Measured on the same build and device: **20.8–32.4 s vs 87 ms** (options 13), and
**36.2 s** with the option set a shipping game uses (`237`). iOS' own hang
detector flags a **Severe Hang of 41.02 s** on the main thread.

Full data, hang table and main-thread stacks:
[`docs/MEASUREMENTS-2026-10-26.md`](docs/MEASUREMENTS-2026-10-26.md).
Submission-ready problem description: [`FEEDBACK.md`](FEEDBACK.md).

## Preconditions

1. Physical device: iPhone 15 Pro / iOS 27.0.1 (other iPhones with Spatial
   Audio support should reproduce as well)
2. AirPods connected **and worn**, Spatial Audio + Head Tracking enabled in
   Settings
3. Microphone permission granted on first launch

### Info.plist keys matter (the non-obvious part)

These two keys in `Resources/Info.plist` are not decoration — they decide whether
the app is allowed to use **system Spatial Audio** at all:

```xml
<key>LSApplicationCategoryType</key>
<string>public.app-category.games</string>
<key>LSSupportsGameMode</key>
<true/>
```

A/B measurement of the identical call sequence (same revision, AirPods connected,
A2DP before the switch). The keyless run is the control group for the Spatial
Audio variable; §3 of the measurements doc is a separate baseline for the
"another AudioUnit is rendering" variable. Note that the control is already
abnormal (~21× the playback-stopped baseline) and that Game Mode alone is
intermittent:

| Info.plist | role | Total configuration cost |
|---|---|---|
| neither key | **control (Spatial Audio off)** | 1835–2047 ms |
| `LSSupportsGameMode` only | partial (Game Mode, no Spatial Audio) | 1.9 s (1 of 4 runs) / 4.65–4.76 s (3 of 4) |
| both keys | **treatment (Spatial Audio on)** | **20839–32355 ms** |

Do **not** add `AVGameBypassSystemSpatialAudio`: setting it to `true` bypasses
system spatial audio and the stall disappears, which looks like "no bug".

## Build / run

### Xcode

Open `SpatialAudioStallRepro.xcodeproj`, select the target, choose your team
under Signing & Capabilities (the bundle id is `com.example.SpatialAudioStallRepro`,
change it if you need to), then run on the device.

### Command line

```bash
DEVELOPMENT_TEAM=ABCDE12345 ./run_repro.sh <device-udid-or-name> repro
DEVELOPMENT_TEAM=ABCDE12345 ./run_repro.sh <device-udid-or-name> both   # control, then repro
DEVELOPMENT_TEAM=ABCDE12345 ./run_repro.sh <device-udid-or-name> repro opts237
```

`run_repro.sh` builds, installs, cold-launches the app, waits 75 s and pulls
`Documents/stall_repro.log`, printing that run's `STEP` / `SUMMARY` / `IMPACT`
lines.

## UI and launch arguments

| Button | What it does |
|---|---|
| 1) Play 440 Hz | `AVAudioPlayer` loops a tone — the "another AudioUnit is rendering" condition |
| 2) Stop playback | stops the tone |
| 3) Repro | keeps playing, switches to `PlayAndRecord + VoiceChat`, times every call |
| 4) Control | stops the player, `setActive:NO`, then runs the identical switch |
| 5) Dump audio session | category / mode / sample rate / route / channel counts |
| 6) Share log | share `stall_repro.log` through the system share sheet |

Launch arguments (both `-auto-repro` and `auto-repro` forms are accepted, the
dashless form is for `devicectl`):

| Argument | Effect |
|---|---|
| `auto-repro` | run the repro sequence automatically after launch |
| `auto-control` | run the control sequence automatically |
| `opts12` / `opts13` / `opts237` | category options (default 13: `MixWithOthers｜AllowBluetoothHFP｜DefaultToSpeaker`) |
| `engine-tone` | render the tone with `AVAudioEngine + AVAudioPlayerNode` instead of `AVAudioPlayer` |
| `dual-tone` | play with both at once |

## Reading the log

```
STEP setCategory(PlayAndRecord) 1974.7ms options=13
SUMMARY mode=repro options=13 total_ms=23478.3 category_ms=1974.7 ... slow=1 route=...
IMPACT mode=repro first_input_buffer=20872.4ms since_config_start=44407.4ms frames=4800
```

- `STEP` — one API call: duration, error code, details
- `SUMMARY` — total configuration cost (sum of the configuration steps),
  `slow=1` when it exceeds 1 s
- `IMPACT` — time from the start of the switch until the microphone actually
  delivers its first buffer, i.e. how long the user waits for voice chat
- Every step is also an `os_signpost` interval (subsystem
  `com.example.stallrepro`), so it shows up in Instruments directly

## Extra evidence worth attaching to the report

1. **Screen recording** — Control Center showing Spatial Audio enabled while the
   app is frozen
2. **sysdiagnose** — volume up + volume down + side button, then Settings →
   Privacy & Security → Analytics & Improvements → Analytics Data →
   `sysdiagnose_*`
3. **Main-thread samples**:

```bash
xcrun xctrace record --device '<device name>' --template 'Time Profiler' \
  --time-limit 70s --output stall_profiler.trace --launch -- \
  com.example.SpatialAudioStallRepro auto-repro
xcrun xctrace export --input stall_profiler.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]' \
  --output hangs.xml
```

`hangs.xml` already contains `Severe Hang`; the `time-profile` table shows the
main thread parked in `avas::client::SessionCore::setCategory` /
`GetProperty` / `SetProperty`.

## Layout

```
Sources/main.m                        app entry point
Sources/StallReproViewController.m    all measurement logic
Resources/Info.plist                  includes the two Spatial Audio keys
run_repro.sh                          build / install / cold launch / pull log
docs/MEASUREMENTS-2026-10-26.md       measurements, hang records, main-thread stacks
evidence/                             raw logs / hang table / stacks from the runs below
FEEDBACK.md                           problem description ready for Feedback Assistant
```

`evidence/` contains the raw capture output referenced by the report
(`control-cold-launch.log`, `repro-cold-launch.log`, `repro-options-237.log`,
`hangs.xml`, `main-thread-stacks.txt`); see [`evidence/README.md`](evidence/README.md).
`logs/` and `artifacts/` are local scratch output and are not committed.
