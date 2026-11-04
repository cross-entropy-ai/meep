<p align="center">
  <img src="assets/app-icon.png" width="128" alt="Meep icon">
</p>

<h1 align="center">Meep</h1>

<p align="center">A macOS menu bar app that records your meetings.</p>

<p align="center">
  <img src="docs/preferences-general.png" width="480" alt="Preferences">
</p>

## Features

- Records both sides of any call (Zoom, Meet, Teams, a browser tab…) with no extra audio drivers
- Removes speaker echo, so you can take calls without headphones
- Keeps recording when you plug in or unplug headphones
- One-click start/stop from the menu bar, or a global hotkey (⌃⌘R)
- Scriptable: start and stop from the Terminal, Shortcuts or an AI agent

## Install

Requires macOS 15+ on Apple Silicon.

```bash
brew trust --cask cross-entropy-ai/tap/meep    # Homebrew asks you to trust casks from other taps once
brew install --cask cross-entropy-ai/tap/meep
```

This installs `Meep.app` into `/Applications` and the `meep` command (see [Automation](#automation)). Upgrade with `brew upgrade --cask meep`, or download the zip from [Releases](https://github.com/cross-entropy-ai/meep/releases).

The first time you record, macOS asks for **Microphone** and **System Audio Recording** access. Allow both.

## Automation

```bash
meep start --wait    # start recording, print the recording folder
meep stop --wait     # stop, return once the recording is saved
meep status          # idle, recording or saving (--json for details)
meep help            # all commands and settings
```

**Run After Saving** (Preferences › Agent) runs a shell command after each recording is saved. Meep adds the recording folder to the end of the command (it is also in `$1` and `$MEEP_DIR`), so don't name it again. See [Recipes](#recipes).

## Recipes

Commands for **Run After Saving**. Meep runs `<command> "<recording folder>"` with `zsh -lc` inside the folder, and logs its output to `raw/after-save.log`; `raw/after-save.json` and `meep status --json` show whether it finished.

### Transcribe

```sh
/opt/homebrew/bin/moop -s meeting -o "$1/transcript.txt"
```

Each recording gets a `transcript.txt` with speaker labels. This uses [moop](https://github.com/cross-entropy-ai/moop) (`brew install cross-entropy-ai/tap/moop`, then `moop login`). Add `--hotwords @$HOME/hotwords.txt` so names and jargon come out right.

### Transcribe, then summarize with an agent

Several steps go in a script. Save this as `~/bin/meep-after-save`, run `chmod +x ~/bin/meep-after-save`, and set Run After Saving to `~/bin/meep-after-save`:

```sh
#!/bin/zsh -e
dir=$1
/opt/homebrew/bin/moop -q -s meeting -o "$dir/transcript.txt" "$dir"
prompt="Summarize this meeting in its own language: decisions, then action items with owner and due date. Markdown only."
~/.local/bin/claude -p "$prompt" < "$dir/transcript.txt" > "$dir/summary.md"
```

Each recording then gets a `summary.md` next to the transcript. For another agent, replace the last line:

| Agent | Last line |
| --- | --- |
| [Claude Code](https://code.claude.com/docs) | `~/.local/bin/claude -p "$prompt" < "$dir/transcript.txt" > "$dir/summary.md"` |
| [Codex](https://github.com/openai/codex) | `~/.bun/bin/codex exec --skip-git-repo-check -o "$dir/summary.md" "$prompt" < "$dir/transcript.txt" > /dev/null` |
| [pi](https://github.com/earendil-works/pi) | `~/.local/bin/pi -p "$prompt" < "$dir/transcript.txt" > "$dir/summary.md"` |

- **Use full paths.** The command reads `~/.zprofile` but not `~/.zshrc`, so tools installed with npm, bun, nvm or a curl script are usually not on its `PATH`. Find a tool's path with `command -v claude` in Terminal.
- Codex refuses to run outside a git repository without `--skip-git-repo-check`. A recording folder is not one.
- An agent must stay signed in. Claude Code's sign-in expires; for commands nobody watches, it suggests `claude setup-token`.
- The agent reads only the transcript. It cannot hear the recording.

## License

[MIT](LICENSE). Echo cancellation uses [webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) (BSD); icons from [Tabler Icons](https://tabler.io/icons) (MIT).

The app bundles [FFmpeg](https://ffmpeg.org) (LGPL-2.1) as a separate helper, `Contents/Helpers/ffmpeg`, for mixing. It is built from unmodified source by `scripts/build-ffmpeg.sh`, which records the exact configure line in `Contents/Resources/ffmpeg/BUILDINFO` next to the license; see [ffmpeg.org/legal.html](https://ffmpeg.org/legal.html).
