<p align="center">
  <img src="assets/app-icon.png" width="128" alt="MeetingRecorder icon">
</p>

<h1 align="center">MeetingRecorder</h1>

<p align="center">A macOS menu bar app that records your meetings: everyone else (from your Mac's audio) and you (from the microphone).</p>

<p align="center">
  <img src="docs/preferences-general.png" width="480" alt="Preferences">
</p>

## Features

- Records both sides of any call (Zoom, Meet, Teams, a browser tab…) with no extra audio drivers
- Removes speaker echo, so you can take calls without headphones
- Keeps recording when you plug in or unplug headphones
- One-click start/stop from the menu bar, or a global hotkey (⌘⇧R)
- Scriptable: start and stop from the Terminal, Shortcuts or an AI agent

## Install

Requires macOS 15+ on Apple Silicon and the Xcode Command Line Tools.

```bash
brew install meson ninja
git clone https://github.com/Junyi-99/agent-meetingrecorder.git
cd agent-meetingrecorder
./build.sh                      # the first build takes a few minutes (builds WebRTC and ffmpeg)
open build/MeetingRecorder.app
```

The first time you record, macOS asks for **Microphone** and **System Audio Recording** access. Allow both.

## Use

1. Click the microphone icon in the menu bar and choose **Start Recording** (or press ⌘⇧R).
2. The icon turns red while recording.
3. Choose **Stop Recording** when the meeting ends.

Recordings are saved to `~/Documents/MeetingRecordings/<date_time>/`:

| File | What it is |
|---|---|
| `mixed.m4a` | The meeting, both sides. Usually all you need. |
| `raw/` | Separate tracks for you and the other side, and a `session.json` with details. |

Preferences (⌘,) let you change the hotkey, language, echo cancellation and more.

## Automation

The app binary doubles as a command-line tool:

```bash
mr=/Applications/MeetingRecorder.app/Contents/MacOS/MeetingRecorder   # or build/MeetingRecorder.app/…

dir=$($mr start --wait)          # starts recording (launching the app if needed), prints the folder
$mr stop --wait                  # returns once the recording is saved; exit 0 if it is complete or recovered
$mr status                       # JSON: idle / recording / saving, and the latest recording

$mr aec --system call.caf --mic me.caf -o me_clean.wav    # remove speaker echo from a mic track
$mr mix --system call.caf --mic me_clean.wav -o meeting.m4a
```

Results (a folder or file path, or JSON) go to stdout; messages and progress go to stderr.
Exit codes: `0` ok, `1` failed, `2` bad usage, `3` timed out. `$mr help` lists everything.
`open "meetingrecorder://start"` and `…://stop` work too, without waiting.

**Run After Saving** (Preferences › Agent) runs a command of your choice after each recording, e.g. a transcription script, with the recording folder as `$1`. Its progress and exit status appear in `raw/session.json` under `after_save`.

To save recordings somewhere else:

```bash
defaults write com.junyi.MeetingRecorder recordingsFolder -string ~/Meetings
```

## License

[MIT](LICENSE). Echo cancellation uses [webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) (BSD); icons from [Tabler Icons](https://tabler.io/icons) (MIT).

The app bundles [FFmpeg](https://ffmpeg.org) (LGPL-2.1) as a separate helper, `Contents/Helpers/ffmpeg`, for mixing. It is built from unmodified source by `scripts/build-ffmpeg.sh`, which records the exact configure line in `Contents/Resources/ffmpeg/BUILDINFO` next to the license; see [ffmpeg.org/legal.html](https://ffmpeg.org/legal.html).
