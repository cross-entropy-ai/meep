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
brew install ffmpeg meson ninja
git clone https://github.com/Junyi-99/agent-meetingrecorder.git
cd agent-meetingrecorder
./build.sh                      # the first build takes a few minutes
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

```bash
open "meetingrecorder://start"
open "meetingrecorder://stop"
```

For everything else, see **Preferences › Agent**, or run:

```bash
build/MeetingRecorder.app/Contents/MacOS/MeetingRecorder --help
```

**Run After Saving** (Preferences › Agent) runs a command of your choice after each recording, e.g. a transcription script, with the recording folder as `$1`.

## License

[MIT](LICENSE). Echo cancellation uses [webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) (BSD); icons from [Tabler Icons](https://tabler.io/icons) (MIT).
