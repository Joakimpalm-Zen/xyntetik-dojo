# D43 Composer Sweep Fixtures (`sweep-2026-11-17`)

Recorded against real `claude` (`2.1.326`) and `codex` (`0.169.0`) processes in a neutral pty (`cwd` in `/tmp`, no model calls made, Enter never pressed on a prompt), scrubbed of plan names with no personal data.

## Provenance Notes

- **Claude Code alternate-screen vs primary-screen:** `Sources/XHSCore/Launch.swift` strips inherited `CLAUDE*` variables (`CLAUDE_CODE_NO_FLICKER` included) before starting a pane and passes no fullscreen flag, so primary-screen Claude Code is a real Dojo configuration whenever the user's shell profile or `~/.claude.json` does not enable fullscreen/no-flicker mode. In `manifest.json`, `mode: "alt"` recordings forced `CLAUDE_CODE_NO_FLICKER=1` during capture, while `mode: "primary"` (`claude-60x14-plain-primary-s650`, `claude-80x14-plain-primary-s650`) ran without it on the primary screen.
- **Codex `mode: "inline"`:** Describes the inline composer layout without alternate-screen scrolling chrome; the Codex PTY streams themselves still use `DECSET 1049`.
- **Paste markers:** Captures use bracketed paste (`\e[200~...\e[201~`) matching `Delivery.bytes` with `[from: probe] ` prefixes. Three passing single-line captures keep a trailing space inside `.txt` before `Delivery.sanitize` trimming.
