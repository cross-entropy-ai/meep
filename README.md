# MeetingRecorder

A macOS menu bar app that does one thing: **record meetings**. It captures what your Mac plays (the other participants) and your microphone (you) as separate, time-aligned tracks, removes speaker echo from the mic, and saves a loudness-matched mix.

Transcription, summaries and the rest are left to other tools: the output is plain files plus a JSON manifest, and the app can be driven by URLs, a CLI and a post-save hook.

## Features

- **System audio + microphone** via a Core Audio process tap (no virtual audio device, no Screen Recording permission)
- **Echo cancellation** so speaker playback doesn't leak into your track: WebRTC AEC3 after stopping, or Apple Voice Processing in real time
- **Survives device changes**: plugging in or removing headphones/AirPods restarts the affected track; files stay continuous and aligned
- **Crash-safe**: capture is written as PCM and finished on the next launch if the app dies mid-meeting
- **Agent friendly**: `meetingrecorder://start|stop`, `--status` (JSON), `--help`, and a "Run After Saving" shell hook
- Global hotkey (default ⌘⇧R), launch at login, English / 简体中文 UI

## Requirements

- macOS 14.2 or later, Apple Silicon
- Xcode Command Line Tools (no Xcode needed)
- `brew install ffmpeg meson ninja` (meson/ninja are only used to build WebRTC once)

## Build

```bash
./build.sh                      # first run also builds WebRTC AEC3 into vendor/ (a few minutes)
open build/MeetingRecorder.app
```

`build.sh` signs with your first "Apple Development" identity if you have one (so macOS permissions survive rebuilds), otherwise ad-hoc. Override with `SIGN_IDENTITY=...`.

On first recording macOS asks for two permissions:

| Permission | Used for |
|---|---|
| Microphone | your voice |
| System Audio Recording Only (Privacy & Security › Screen & System Audio Recording) | what the Mac plays |

## Usage

Click the menu bar icon › **Start Recording**, or press the hotkey. The icon turns red while recording (orange while a disconnected device is being recovered) and shows a spinner while saving.

**Preferences** (⌘,):

- **General**: Start at Login, Hotkey, Language, Show Menu Bar Icon, Show Recording Time, Echo Cancellation, Open Folder After Saving
- **Agent**: URL scheme, CLI, Run After Saving
- **About**: version, links, update check

With the menu bar icon hidden, it still appears while recording; open the app again to get to Preferences.

## Output

```
~/Documents/MeetingRecordings/<yyyy-MM-dd_HHmmss>/
├── mixed.m4a          system audio + microphone, each normalized to -20 LUFS
└── raw/
    ├── system.caf     what the Mac played (other participants), AAC 48 kHz stereo
    ├── mic.caf        microphone (you), AAC 48 kHz mono
    ├── mic_aec.caf    microphone with speaker echo removed (WebRTC mode)
    └── session.json   status, timing, interruptions, mix gains, warnings
```

All tracks start at the same moment: sample *N* of every file is the same instant. Gaps (device switches, a tap that is silent while nothing plays) are filled with silence. About 90 MB per hour.

`session.json` `status`: `recording`, `saving`, `complete`, `recovered` (interrupted but every track came back), `incomplete` (a track was still down at stop), `recovered_after_crash`. Interruption reasons are fixed codes: `default_input_changed`, `default_output_changed`, `input_device_removed`, `output_device_removed`, `route_changed`, `mic_stalled`, `system_stalled`, `start_failed`.

## For agents and scripts

```bash
open "meetingrecorder://start"        # launches the app if needed
open "meetingrecorder://stop"
open "meetingrecorder://preferences"  # also /general, /agent, /about

B=/path/to/MeetingRecorder.app/Contents/MacOS/MeetingRecorder
$B --help
$B --status          # {"state": "idle|recording|saving", "current": {...}, "latest": {"dir", "mixed", ...}}
$B --aec <dir>       # re-run echo cancellation → raw/mic_aec.caf
$B --remix <dir>     # re-mix → mixed.m4a
$B --login-item on|off|status
```

Typical flow: `start` → … → `stop` → poll `--status` until `state` is `idle` → read `latest.mixed`.

Or set **Preferences › Agent › Run After Saving** to a command (e.g. a transcription script). It runs in a login shell after every save with the recording folder as `$1` and in `$MEETINGRECORDER_DIR`; output goes to `raw/after-save.log`.

Settings live in the `com.junyi.MeetingRecorder` defaults domain: `echoCancellation` (`off|apple|webrtc`), `language` (`system|en|zh`), `showMenuBarIcon`, `showElapsedTime`, `openFolderAfterSaving`, `afterSaveCommand`.

## Echo cancellation

Measured on MacBook Pro speakers at 50% volume, mic level while the other side is talking:

| Mode | Echo in mic track | Trade-off |
|---|---|---|
| Off | −27 dB | Use with headphones |
| Apple Voice Processing | ≈ −57 dB | Real time. Lowers other apps' volume by ~7 dB; mic starts ~2 s late and drops ~1.7 s on device switches |
| WebRTC AEC3 (default) | ≈ −52 dB | Runs after stopping (~40× real time). Your voice is attenuated 1–8 dB while both sides talk |

WebRTC uses `system.caf` as the echo reference, so it only needs the two recorded tracks.

## How it works

| File | Role |
|---|---|
| `Sources/RecordingSession.swift` | One recording: starts both tracks, watches devices, 1 s watchdog, restarts with backoff, writes session.json |
| `Sources/SystemAudioRecorder.swift` | Process tap → private aggregate device → IOProc |
| `Sources/MicRecorder.swift` | AVAudioEngine input, optional Apple voice processing |
| `Sources/TrackWriter.swift` | Continuous PCM file per track: format conversion, silence padding on the session clock |
| `Sources/Finalizer.swift` | After stop: echo cancellation → mix → AAC → delete PCM; crash recovery |
| `Sources/EchoCanceller.swift`, `Native/webrtc_aec.*` | WebRTC AEC3 via a small C wrapper |
| `Sources/Mixer.swift` | EBU R128 loudness matching and mixing (ffmpeg) |
| `Sources/Agent.swift` | Run After Saving, `--status`, `--help` |
| `Sources/PreferencesWindow.swift`, `Settings.swift`, `L10n.swift`, `HotKey.swift`, `MenuBarIcons.swift` | UI |
| `scripts/build-webrtc.sh` | Builds [webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) as one static library |

Why capture is PCM: AAC in CAF needs a packet table written when the file is closed, so a crash leaves it unreadable. PCM CAF is readable at any point; it is encoded to AAC after stopping.

## Known limitations

- Device switching was tested with simulated devices (aggregate devices created and removed), not with real Bluetooth headsets.
- Double talk was tested by mixing in a synthetic voice; not tested in Apple mode.
- Tracks follow their device clocks. Silence is inserted when a track falls behind by more than 50 ms, but samples are never dropped, so in long meetings tracks may drift by up to a few hundred ms.
- Apple Silicon only (`build.sh` targets arm64).

## Acknowledgements

- [webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) (BSD) for AEC3
- Menu bar icons from [Tabler Icons](https://tabler.io/icons) (MIT)

## License

[MIT](LICENSE)
