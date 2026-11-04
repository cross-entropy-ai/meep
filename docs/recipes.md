# Recipes

Commands for **Run After Saving** (Preferences › Agent). Meep runs `<command> "<recording folder>"` with `zsh -lc` inside the folder, and logs its output to `raw/after-save.log`; `raw/after-save.json` and `meep status --json` show whether it finished.

## Transcribe

```sh
/opt/homebrew/bin/moop -s meeting -o "$1/transcript.txt"
```

Each recording gets a `transcript.txt` with speaker labels. This uses [moop](https://github.com/cross-entropy-ai/moop) (`brew install cross-entropy-ai/tap/moop`, then `moop login`). Add `--hotwords @$HOME/hotwords.txt` so names and jargon come out right.

## Transcribe, then summarize with an agent

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
