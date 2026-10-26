# Measurements — 2026-10-26 (iOS 27.0.1)

Device: iPhone 15 Pro (iPhone16,1), iOS 27.0.1 (24A446)
Headphones: AirPods, worn, system Spatial Audio + Head Tracking enabled
Build: `SpatialAudioStallRepro` Debug
Method: one cold launch per scenario via `devicectl`, one scenario per launch.
Each step is timed with `CACurrentMediaTime()` and emitted as an `os_signpost`
interval.

"Total" is the sum of the configuration steps below (prepare/cleanup steps are
excluded).

## 1. Info.plist A/B (the non-obvious part)

`LSApplicationCategoryType` and `LSSupportsGameMode` decide whether the app is
allowed to use **system Spatial Audio**. All three variants ran the identical
"switch to PlayAndRecord + VoiceChat while a tone is playing" sequence:

| Info.plist | runs | Total | setCategory | setMode | channel getters / setPreferred |
|---|---|---|---|---|---|
| neither key | 8 | 1835–2047 ms | 873–958 ms | 953–1077 ms | 0.2–84 ms |
| `LSSupportsGameMode` only | 4 | 1880 ms (1/4) · 4649–4762 ms (3/4) | 876–907 ms | 966 ms · 3745–3771 ms | 0.3–2.1 ms |
| both keys | 6 | **20839–32355 ms** | 1853–4787 ms | 418–456 ms | 1795–7718 ms |

Variants A/B/C were re-measured back-to-back on the same revision (2 / 3 / 2
runs); the ranges also include earlier runs of the same measurement code. In all
runs the AirPods were connected and `BluetoothA2DPOutput` was the route before
the switch.

- Removing both keys makes the stall an order of magnitude smaller but does
  **not** remove it: ~1.9 s in total, still ~21× the control.
- Game Mode alone is intermittent: 3 of 4 runs take ~4.65 s because `setMode`
  alone jumps to ~3.75 s; the fourth is indistinguishable from "neither key".
- Only with both keys do the read-only channel getters and `setPreferred*`
  calls block for seconds as well — that is what produces the 20–32 s total.

Runs taken while the AirPods were disconnected (route `out:Speaker`, totals
426–494 ms) are excluded; they are reproducible but not the scenario.


`AVGameBypassSystemSpatialAudio` is deliberately absent — setting it to `true`
bypasses system spatial audio and makes the symptom disappear.

## 2. Six cold launches with both keys (options = 13)

Values in ms. "First input buffer" is measured from `AVAudioEngine` start until
the input tap receives its first buffer.

| run | setCategory | setMode | inCh (getter) | outCh (getter) | prefSR | prefIO | prefIn | prefOut | setActive | Total | First input buffer |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1974.7 | 445.6 | 1795.1 | 7714.8 | 2253.3 | 2233.6 | 2204.0 | 4856.5 | 0.2 | 23478.3 | 20872.4 |
| 2 | 4776.9 | 421.4 | 1848.2 | 324.2 | 2313.6 | 2270.7 | 7717.8 | 2319.3 | 0.2 | 21992.7 | 19039.1 |
| 3 | 1937.6 | 455.1 | 1829.6 | 2238.1 | 2381.3 | 4935.8 | 2218.1 | 4842.7 | 0.3 | 20839.0 | 19088.2 |
| 4 | 1853.1 | 455.5 | 7269.4 | 4948.3 | 2283.9 | 2157.6 | 2221.2 | 7717.6 | 0.2 | 28907.3 | 18281.0 |
| 5 | 4786.8 | 464.4 | 1825.4 | 5196.8 | 5116.4 | 7676.3 | 2171.6 | 5106.7 | 0.2 | 32345.2 | 37633.9 |
| 6 | 4761.5 | 418.5 | 4829.6 | 5031.5 | 4993.1 | 5131.6 | 2240.7 | 4947.6 | 0.2 | 32354.7 | 23572.2 |

- Route before: `out:BluetoothA2DPOutput (spatial=1, ch=2)`, tone playing
- Route after: `in:BluetoothHFP (ch=1), out:BluetoothHFP (spatial=1, ch=2)`
- First input buffer arrives 40.0–70.0 s after the switch begins
  (20.8–32.4 s of configuration plus another 18.3–37.6 s to start input)
- The configuration shipped in this repository
  (`com.example.SpatialAudioStallRepro`) was re-verified after renaming the
  bundle id: **23628.5 ms** total, first input buffer **45917.4 ms** after the
  switch begins

### Same sequence with options = 237 (what a shipping game uses)

| setCategory | setMode | inCh (getter) | outCh (getter) | prefSR | prefIO | prefIn | prefOut | setActive | Total | First input buffer |
|---|---|---|---|---|---|---|---|---|---|---|
| 4680.1 | 5616.7 | 1097.8 | 2229.5 | 4892.5 | 7670.9 | 5122.6 | 4915.6 | 0.2 | **36226.3** | 22326.0 |

Per-call values are in the same range as the earlier probe run
(`rebuild-tone`: 1931.7 / 5621.7 / 1156.0 / 4962.0), so the option bits are not
the trigger. In this run `AVAudioEngine startAndReturnError:` itself blocked for
22240.3 ms, and the first input buffer arrived 58.60 s after the switch began.

## 3. Control (same build: stop playback, deactivate, then switch)

| step | duration |
|---|---|
| setCategory(PlayAndRecord) | 1.7 ms |
| setMode(VoiceChat) | 0.5 ms |
| inputNumberOfChannels | 0.4 ms |
| outputNumberOfChannels | 0.7 ms |
| setPreferredSampleRate | 0.9 ms |
| setPreferredIOBufferDuration | 0.4 ms |
| setPreferredInputNumberOfChannels | 0.7 ms |
| setPreferredOutputNumberOfChannels | 0.3 ms |
| setActive(YES) | 81.2 ms |
| **Total** | **87.2 ms** |
| First input buffer | 662.2 ms |

That is a **239–415×** difference. Identical calls, identical device and
headphones; the only difference is whether another AudioUnit is still rendering
when the switch happens.

## 4. System hang detection (Instruments Time Profiler, same build)

`xctrace`'s Hangs instrument reports on the app's main thread:

```
Hang         start=00:04.063.560  duration=587.32 ms   thread=Main Thread
Severe Hang  start=00:06.726.553  duration=41.02 s     thread=Main Thread
Hang         start=00:54.017.098  duration=817.67 ms   thread=Main Thread
```

The 41.02 s Severe Hang covers the whole window: category switch → configuration
→ first input buffer.

## 5. Main-thread stacks (same trace)

```
### setCategory (main thread, t=6.73s)
    avas::client::SessionCore::setCategory(NSString*, NSString*, AVAudioSessionRouteSharingPolicy, unsigned long)
    avas::client::SessionCore::setCategory(NSString*, unsigned long, NSError* __autoreleasing*)
    -[AVAudioSession setCategory:withOptions:error:]

### inputNumberOfChannels (main thread, t=13.79s)
    avas::client::SessionCore::GetProperty_DefaultToZero<unsigned int>(NSString*, bool) const
    avas::client::KVOProperty<unsigned int>::UpdateIfDirty(...)
    -[AVAudioSession inputNumberOfChannels]

### outputNumberOfChannels (main thread, t=14.11s)
    -[AVAudioSession outputNumberOfChannels]

### setPreferredInputNumberOfChannels (main thread, t=26.43s)
    avas::client::SessionCore::SetProperty(NSString*, id<NSSecureCoding>, bool) const
    -[AVAudioSession setPreferredInputNumberOfChannels:error:]
```

The same trace also samples `SessionCore::SetBatchProperties` → `NSXPCEncoder`
(synchronous XPC encoding) and `SessionCoreLegacy_iOS::HandleDeferredMessage`
(route notification handling), i.e. the wait happens in a synchronous round trip
between the app and the audio daemon, not in app-side computation.

## 6. Capture commands

The raw logs, hang table and stack extract are committed under
[`../evidence/`](../evidence).

```bash
# build + install
xcodebuild -project SpatialAudioStallRepro.xcodeproj \
  -scheme SpatialAudioStallRepro -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/stallrepro-derived \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<TEAM> -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> \
  /tmp/stallrepro-derived/Build/Products/Debug-iphoneos/SpatialAudioStallRepro.app

# one scenario, one cold launch
xcrun devicectl device process launch --device <UDID> --terminate-existing \
  com.example.SpatialAudioStallRepro auto-repro

# pull the log
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.example.SpatialAudioStallRepro \
  --source Documents/stall_repro.log --destination ./stall_repro.log

# trace with stacks (xctrace needs the hardware UDID or the device name,
# not devicectl's identifier)
xcrun xctrace record --device '<device name>' --template 'Time Profiler' \
  --time-limit 70s --output stall_profiler.trace --launch -- \
  com.example.SpatialAudioStallRepro auto-repro
xcrun xctrace export --input stall_profiler.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]' \
  --output hangs.xml
```

## 7. Relation to the shipping-app numbers

Earlier the same day, on the same device and headphones, a probe app that also
had a third-party audio SDK loaded measured `setCategory` 4727 ms,
19.6 s total configuration, and 6.6 ms when the playing unit was torn down first.
The 20.8–32.4 s measured here is the same order of magnitude; per-call values
vary between 2 s and 8 s depending on system state, so ranges are reported
instead of single numbers.
