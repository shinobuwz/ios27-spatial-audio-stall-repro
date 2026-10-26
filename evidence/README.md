# Raw evidence

Collected on iPhone 15 Pro, iOS 27.0.1 (24A446), AirPods worn with system
Spatial Audio + Head Tracking enabled. One cold launch per log file unless noted.
All logs come from the same build of this repository
(`com.example.SpatialAudioStallRepro`, Debug).

| file | what it is | headline |
|---|---|---|
| `control-cold-launch.log` | playback stopped + `setActive:NO` before the identical switch | `total_ms≈89`, `slow=0` |
| `repro-cold-launch.log` | 440 Hz still playing while the session switches to `PlayAndRecord + VoiceChat` | `total_ms≈24543`, `slow=1` |
| `repro-options-237.log` | same as above with `opts237` (the option set a shipping game uses) | `total_ms=36226`, first input buffer after 58.60 s |
| `hangs.xml` | hang table exported from the Instruments trace | `Severe Hang 41.02 s` on the main thread |
| `main-thread-stacks.txt` | main-thread stacks captured inside the stall | parked in `avas::client::SessionCore` (synchronous XPC) |
| `plist-a-no-keys.log` | Info.plist with neither key (2 runs) | 1835.3 / 1979.5 ms, getters and `setPreferred*` in single-digit ms |
| `plist-b-gamemode-only.log` | `LSSupportsGameMode` only (3 runs) | bimodal: 4648.7 / 4656.0 ms vs 1880.1 ms; the slow runs have `setMode` ≈ 3.75 s |
| `plist-c-both-keys.log` | both keys, i.e. what this repository ships (2 runs) | 32345.2 / 32354.7 ms, first input buffer 37.6 s / 23.6 s after capture start |

## How the two runs relate

`control-cold-launch.log` and `repro-cold-launch.log` are two separate cold
launches of the **same build with the same Info.plist**. The only difference is
whether the 440 Hz `AVAudioPlayer` is still rendering when the session is
reconfigured:

```
# control
SUMMARY mode=control options=13 total_ms=88.4 category_ms=1.9 mode_ms=0.5 ... slow=0
IMPACT  mode=control first_input_buffer=601.4ms

# repro
SUMMARY mode=repro options=13 total_ms=24543.0 category_ms=1942.3 mode_ms=421.8 ... slow=1
IMPACT  mode=repro first_input_buffer=23602.5ms since_config_start=48203.6ms
```

## Reading a log

- `===== RUN mode=… options=… tone=… =====` starts a run; the app appends to
  `Documents/stall_repro.log`, so several runs can live in one file.
- `STEP <name> <ms>` — one `AVAudioSession` call, its duration, error code and
  details. `STEP prepare.*` / `STEP cleanup.*` are outside the measured window.
- `SUMMARY … total_ms=… slow=0|1` — sum of the configuration steps; `slow=1`
  means it exceeded one second.
- `IMPACT … first_input_buffer=… since_config_start=…` — when the microphone
  actually delivers audio, i.e. how long the user waits for voice chat.
- `NOTIFY route-change …` — A2DP → HFP route notifications with the port type
  and `spatial=` flag.

## Reproducing these logs

```bash
DEVELOPMENT_TEAM=<your team id> ./run_repro.sh <device> both
```

or manually:

```bash
xcrun devicectl device process launch --device <UDID> --terminate-existing \
  com.example.SpatialAudioStallRepro auto-control   # then wait ~10 s
xcrun devicectl device process launch --device <UDID> --terminate-existing \
  com.example.SpatialAudioStallRepro auto-repro     # then wait ~55 s
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.example.SpatialAudioStallRepro \
  --source Documents/stall_repro.log --destination ./stall_repro.log
```
