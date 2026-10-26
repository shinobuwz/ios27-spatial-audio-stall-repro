# Feedback Assistant — draft

Copy the sections below into Feedback Assistant. Area: **AVFoundation / Audio**.
Type: **Incorrect Behavior**. Attach `stall_repro.log`, the Instruments trace,
a sysdiagnose and a screen recording.

---

## Title

AVAudioSession configuration calls block for seconds when switching A2DP → HFP
while another AudioUnit is rendering (iOS 27.0.1, AirPods, system Spatial Audio)

## Area / Type

AVFoundation › AVAudioSession — Incorrect Behavior

## Configuration

- iPhone 15 Pro (iPhone16,1), iOS 27.0.1 (24A446)
- AirPods, worn; **Spatial Audio + Head Tracking enabled** in Settings
- Test app uses AVFoundation only — no third-party SDK, no Agora, no Wwise
- The app declares `LSApplicationCategoryType = public.app-category.games` and
  `LSSupportsGameMode = YES`. These two keys matter: they are what makes system
  Spatial Audio available to this app on AirPods. It does **not** set
  `AVGameBypassSystemSpatialAudio`.
- Reproduction project (public, AVFoundation only): https://github.com/shinobuwz/ios27-spatial-audio-stall-repro

## Description

While an audio unit owned by the app is rendering 440 Hz to AirPods over A2DP,
changing the shared `AVAudioSession` to `playAndRecord`
(`allowBluetoothHFP | defaultToSpeaker | mixWithOthers`) + `voiceChat` blocks the
calling (main) thread for seconds per call.

Every call below is a synchronous, main-thread `AVAudioSession` call that is
expected to return in milliseconds:

`setCategory:withOptions:error:`, `setMode:error:`,
`inputNumberOfChannels`, `outputNumberOfChannels`,
`setPreferredSampleRate:error:`, `setPreferredIOBufferDuration:error:`,
`setPreferredInputNumberOfChannels:error:`,
`setPreferredOutputNumberOfChannels:error:`, `setActive:error:`

The whole configuration path takes **20.8–32.4 s**, after which the microphone
still needs another 18.3–37.6 s before the first `AVAudioEngine` input buffer
arrives (40–70 s from the switch until audio actually flows).

If the playing audio unit is stopped before the same sequence is executed, every
call returns in well under 2 ms and the total is 87 ms. So the stall requires
"a rendering audio unit exists in the process at the moment of the switch".

## Steps to reproduce

1. Connect AirPods, enable Spatial Audio + Head Tracking, wear them.
2. Launch the attached app (`com.example.SpatialAudioStallRepro`) and allow the
   microphone. Or launch it with the `auto-repro` argument.
3. Tap **1) Play 440 Hz** — a 440 Hz tone starts looping through `AVAudioPlayer`
   in an active `playback` session; the route is `BluetoothA2DP`.
4. Wait 2 s, then tap **3) Repro**.
5. Watch the timed `STEP …` lines in the app, or read `Documents/stall_repro.log`.

Control experiment: tap **4) Control** instead — it stops the player and calls
`setActive:NO` before the identical switch.

## Expected results

Each `AVAudioSession` call returns within a few milliseconds; the whole
playback → voice-chat reconfiguration takes well under 50 ms, and the first
input buffer arrives immediately after `AVAudioEngine.start()`.

## Actual results

Four cold launches on the same device/headphones (ms):

| call | run 1 | run 2 | run 3 | run 4 |
|---|---|---|---|---|
| `setCategory` | 1974.7 | 4776.9 | 1937.6 | 1853.1 |
| `setMode(voiceChat)` | 445.6 | 421.4 | 455.1 | 455.5 |
| `inputNumberOfChannels` (getter) | 1795.1 | 1848.2 | 1829.6 | 7269.4 |
| `outputNumberOfChannels` (getter) | 7714.8 | 324.2 | 2238.1 | 4948.3 |
| `setPreferredSampleRate` | 2253.3 | 2313.6 | 2381.3 | 2283.9 |
| `setPreferredIOBufferDuration` | 2233.6 | 2270.7 | 4935.8 | 2157.6 |
| `setPreferredInputNumberOfChannels` | 2204.0 | 7717.8 | 2218.1 | 2221.2 |
| `setPreferredOutputNumberOfChannels` | 4856.5 | 2319.3 | 4842.7 | 7717.6 |
| `setActive` | 0.2 | 0.2 | 0.3 | 0.2 |
| **total** | **23478.3** | **21992.7** | **20839.0** | **28907.3** |
| first input buffer after capture start | 20872.4 | 19039.1 | 19088.2 | 18281.0 |

Two further cold launches of the same build took 32345.2 ms and 32354.7 ms
(first input buffer 37633.9 ms and 23572.2 ms).

Control (player stopped and session deactivated before the identical switch):
1.7 / 0.5 / 0.4 / 0.7 / 0.9 / 0.4 / 0.7 / 0.3 / 81.2 ms, total **87.2 ms**, first input
buffer 662.2 ms.

Route before: `out:BluetoothA2DPOutput (spatial=1, ch=2)`.
Route after: `in:BluetoothHFP (ch=1), out:BluetoothHFP (spatial=1, ch=2)`.

**iOS's own hang detector flags it.** An Instruments "Time Profiler" recording of
the same build reports, on the main thread:

```
Hang         587.32 ms
Severe Hang  41.02 s      <- covers switch -> configuration -> first input buffer
Hang         817.67 ms
```

Main-thread samples captured inside the stall:

```
avas::client::SessionCore::setCategory(NSString*, NSString*, AVAudioSessionRouteSharingPolicy, unsigned long)
avas::client::SessionCore::setCategory(NSString*, unsigned long, NSError* __autoreleasing*)
-[AVAudioSession setCategory:withOptions:error:]

avas::client::SessionCore::GetProperty_DefaultToZero<unsigned int>(NSString*, bool) const
avas::client::KVOProperty<unsigned int>::UpdateIfDirty(...)
-[AVAudioSession inputNumberOfChannels]

avas::client::SessionCore::SetProperty(NSString*, id<NSSecureCoding>, bool) const
-[AVAudioSession setPreferredInputNumberOfChannels:error:]
```

i.e. the app is waiting in a synchronous round trip to the audio daemon, and even
*reading* `inputNumberOfChannels` / `outputNumberOfChannels` blocks for seconds.

## Additional notes

- The exact option bits are not the trigger: with `options = 237` (adding
  `allowBluetoothA2DP` and `overrideMutedMicrophoneInterruption`) the same
  sequence took **36.2 s** on the same build (setCategory 4680.1 ms,
  setMode 5616.7 ms, getters 1097.8 / 2229.5 ms, setPreferred
  4892.5 / 7670.9 / 5122.6 / 4915.6 ms). What matters is that another AudioUnit
  is still rendering at the moment of the switch.
- Spatial Audio eligibility gates the severity, not the existence, of the bug.
  With neither `LSApplicationCategoryType = public.app-category.games` nor
  `LSSupportsGameMode`, Spatial Audio is unavailable for the app in Control
  Center and the total drops to 1835–2047 ms over 8 runs — still ~21× the
  87 ms control, and `setCategory`/`setMode` still take ~0.9–1.0 s each.
  With `LSSupportsGameMode` alone the result is bimodal: 3 of 4 runs take
  4.65–4.76 s (`setMode` alone ~3.75 s), the fourth looks like the keyless case.
  Only with both keys do the channel getters and `setPreferred*` calls also
  block for 1.8–7.7 s, giving the 20–32 s total. Declaring
  `AVGameBypassSystemSpatialAudio = YES` removes the symptom entirely.
- Impact in a shipped game: a single "start voice chat" action freezes the main
  thread for tens of seconds and audio is unusable for the whole window.

## Attachments

1. `stall_repro.log` — per-call timings, three runs + control
2. `stall_profiler.trace` — Time Profiler + hang detection + main-thread stacks
3. `hangs.xml` — exported hang table
4. sysdiagnose (`sysdiagnose_*`)
5. screen recording (Control Center showing Spatial Audio on, app frozen)
6. Minimal repro project source (AVFoundation only, one view controller)
