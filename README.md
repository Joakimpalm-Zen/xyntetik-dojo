# Xyntetik Harness Supervisor

One window of terminals for agent harnesses: Claude Code, Codex and pi (on a local Runner model), on this Mac or over SSH. The app is also a message bus, so the harness in any terminal can list, read and message the others. Built with SwiftPM only; no Xcode needed.

## What it does

- One window with a grid of terminals. The plus button (or Cmd-T) adds one: pick Claude, Codex or pi. An optional host makes it remote (a Linux, Mac or Windows box over ssh). An optional folder is where the session starts (a repo root, a book folder); empty means your home folder. Hosts and folders you used before are one click away. An optional name replaces `claude-1`, `codex-1`, `pi-1`.
- It looks like a Xyntetik product: the site's colours in light and dark, the Ensō as the app icon and in the window. The icon is drawn by `packaging/make-icon.swift` at build time; no image file is checked in.
- Each pane is a real terminal (SwiftTerm and a pty). The harness sees an ordinary terminal.
- Each pane header shows the name, kind, host, model, queued messages and a state colour: grey starting, blue running, green idle, orange prompt, red exited.
- The app runs a bus on `127.0.0.1:7788`. Every harness in the window can call four operations: `panes`, `send`, `read` and `state`.

## Requirements

- macOS 14 or later. Built and tested on macOS 27 (Apple Silicon) with the Swift 6.4 Command Line Tools.
- `python3` on every host that runs a harness (the bus shim uses only the standard library).
- `claude`, `codex` and `pi` on your login shell's PATH, each already logged in.
- For pi: Runner's OpenAI-compatible server at `http://127.0.0.1:8080/v1` (`runner -m model.gguf --serve`).

## Build and run

```
make test    # swift test (46 tests) and the shim's Python tests (10)
make app     # build/XyntetikHarnessSupervisor.app, assembled by hand and ad-hoc signed
make run     # open the app
make smoke   # launch proof: one pane runs `echo ok`, the bus answers, the app quits (exit 0)
make smoke HOST=user@box   # the same, with the pane on that host over ssh
```

`XHS_PORT` overrides the bus port. There is no other setting. The only files the app keeps are `~/.xhs/hosts` and `~/.xhs/folders`, the hosts and start folders you used, latest first, one per line; edit or delete them by hand.

## First run

On start the app:

1. Copies `tools/xhs-mcp.py` and `tools/xhs-pi.ts` to `~/.xhs/` and links `~/.xhs/bin/xhs`.
2. If `~/.codex` exists and `~/.codex/config.toml` has no `[mcp_servers.xhs]`, appends the block in `tools/snippets/codex-config.toml`: the xhs MCP server and six state hooks. It does this once and never edits the file again. Delete the block by hand to remove it.

What needs you, once:

- **No permission prompts by default.** A Claude pane runs `claude --dangerously-skip-permissions` and a Codex pane runs `codex --yolo --dangerously-bypass-hook-trust` (no approvals, no sandbox, the six xhs state hooks trusted without a `/hooks` confirmation). That is the owner's choice for a supervised window; the harness in a pane can do anything your user can. Keep the window to work you would approve anyway.
- **Startup dialogs.** Claude and Codex may show their own first-run dialogs in the pane (folder trust, browser tools, an update offer). Answer them there. A pane turns `idle` when its harness reports that its session started.
- Codex shows one startup warning: command-line config overrides run it without the shared background server. The app passes the peer rule with `-c developer_instructions`, which causes it.

## Adding a pane

Press plus, pick Claude, Codex or pi. Leave the host empty for this Mac. A pane starts in the folder you give (type it, press Choose, or click a recent one), or in your home directory; on a host the folder is on that host, as you would type it there. It runs in your login shell (`$SHELL -l -i`), so PATH is the one your terminal has. A pane never inherits `CLAUDE*` variables from the process that opened the app (so `make run` from inside a Claude Code session does not make the pane's Claude a child session). Close a pane with its x button; that ends the harness.

A local pi pane first asks Runner for its models (`GET /v1/models`), starts pi with the first one and shows it in the header. If Runner does not answer, the pane says so and pi is not started.

## Remote panes

Set up a host once, with one command from this repository:

```
tar -C tools -cf - xhs-mcp.py xhs-pi.ts | ssh user@box 'mkdir -p ~/.xhs && tar -C ~/.xhs -xf - && python3 ~/.xhs/xhs-mcp.py install'
```

(`make remote-setup HOST=user@box` runs the same.) It puts the shim and the pi extension in `~/.xhs` on that host, links `xhs`, and adds the Codex entries there if Codex is installed. Nothing else runs on the remote host.

Then press plus and enter `user@box` as the host (or click it under Recent once you have used it). The app first asks the host which shell it runs commands in (`ssh host 'echo %OS%'`), then runs:

```
ssh -t -R 7788:127.0.0.1:7788 user@box '<harness in the remote login shell>'
```

The harness runs in the remote login shell (`$SHELL -l -i`), so it needs to be on the PATH that shell sets. The reverse tunnel lets the shim on the remote host reach the bus at `127.0.0.1:7788` there. The remote host's own keys, logins and tokens are used; the app stores none. Use key-based SSH; a password prompt shows up in the pane. A remote pi uses the Runner on that host.

### Windows hosts

A Windows host with OpenSSH Server and MSYS2 at `C:\msys64` works the same way. The probe sees cmd.exe answer `Windows_NT`, and the pane then runs the same harness command in MSYS2's bash (`bash.exe -l`, with your Windows PATH inherited, so `claude` and `codex` are found where you installed them). The command travels to cmd.exe as base64, so none of its quotes, pipes or percent signs are seen by cmd.exe.

`make remote-setup HOST=user@winbox` detects Windows too. There, `xhs install` writes two small sh scripts in `~/.xhs/bin` instead of a symlink: `xhs`, and a `python3` that runs the Python it was installed with (on Windows, `python3` on PATH is usually the Microsoft Store stub). The harness line puts `~/.xhs/bin` first on PATH, so the MCP shim and hooks find a working `python3`.

Verified: a pane on a Windows 11 host over ssh (`make smoke HOST=...`), the remote setup there, and Claude Code on that host reaching the bus through the tunnel. Codex on a Windows host is not verified: its config hooks call `python3 "$HOME/.xhs/xhs-mcp.py" hook`, which depends on the shell Codex uses for hook commands there.

Two remote panes on the same host share the forwarded port: the first pane's tunnel serves both (ssh warns about the second forward). If the first pane closes, the second loses the bus until you reopen it.

## How harnesses talk

The four operations, as MCP tools for Claude and Codex (`mcp__xhs__panes` and so on) and as the `xhs` command for pi and any shell in a pane:

```
xhs panes                         # name, kind, host, state, queued, model; * marks you
xhs send codex-1 "please review the diff in src/bus.rs"
xhs read claude-1 60              # last 60 lines of claude-1's screen
xhs state pi-1
```

`send` types `[from: <your pane>] <text>` into the target terminal and presses Enter, so the target harness gets it as typed input. Ask any harness to do it in plain words: "send codex-1 a summary of what you changed".

| Harness | Bus tools | State | Peer rule |
|---|---|---|---|
| Claude Code | `--mcp-config` at launch | hooks via `--settings` at launch: SessionStart as a command hook (`xhs hook`; Claude Code runs no http hooks for that event), http hooks for UserPromptSubmit, PermissionRequest, PostToolUse, Stop, Notification (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `elicitation_dialog`) | `--append-system-prompt` |
| Codex | `[mcp_servers.xhs]` in `~/.codex/config.toml` | command hooks in the same file (`xhs hook`): SessionStart, UserPromptSubmit, PermissionRequest, PostToolUse, Stop, Interrupt | `-c developer_instructions` |
| pi | the `xhs` command (pi has no MCP by design; it runs `xhs` with its bash tool). The pane passes `--tools read,bash,edit,write`, so a `defaultTools` setting of yours cannot leave it without bash | the `xhs-pi.ts` extension: session_start, agent_start, agent_settled, ui_prompt_start, ui_prompt_end | `--append-system-prompt` |

The pi extension also registers Runner as pi's `runner` provider.

## Safety rules

- **A relayed message never answers a prompt.** The bus types only into a pane that is `idle`. A pane at a permission prompt or question dialog (`prompt`), busy (`running`) or not yet started (`starting`) gets the message queued. Queued messages go out one at a time, each when the pane turns idle again.
- **A lost Stop does not hold messages forever.** A turn can end without a Stop hook (Codex at its usage limit did). A `running` pane whose screen has not changed for 15 seconds is idle again; every harness animates a spinner while it works. A pane at a `prompt` is never timed out.
- **Every message carries its sender.** The sender is taken from the calling pane's token, not from the message text. The `[from: <name>]` tag shows in the Xyntetik green wherever a harness paints it: the pane colours it on the way from the harness to the screen.
- **No control characters.** The bus strips escape sequences and other control characters. Where the harness supports bracketed paste, a message arrives as one paste; otherwise line breaks become spaces.
- **The owner comes first.** The bus holds messages for a pane you typed into in the last 3 seconds.
- **Peer messages are not approval.** Each harness is told at launch that `[from: ...]` lines are messages from other sessions, to weigh as information and never as the owner's approval.
- **Local and token-checked.** The bus listens on the loopback interface only. Each pane gets a random token for this run of the app; every bus request needs one.
- The app stores no keys, tokens or SSH credentials.

To install the peer rule permanently as well (for sessions started outside the app):

| Snippet | Where it goes |
|---|---|
| `tools/snippets/CLAUDE.md-snippet.md` | `~/.claude/CLAUDE.md` or a project's `CLAUDE.md` |
| `tools/snippets/codex-AGENTS.md-snippet.md` | `~/.codex/AGENTS.md` or a project's `AGENTS.md` |
| `tools/snippets/pi-APPEND_SYSTEM.md` | `~/.pi/agent/APPEND_SYSTEM.md` |

`tools/snippets/claude-settings.json` and `tools/snippets/claude-mcp.json` are exactly what the app passes to Claude at launch (tests keep them equal). You do not need to install them. A by-hand equivalent of the MCP part is `claude mcp add --scope user xhs -- sh -c 'exec python3 "$HOME/.xhs/xhs-mcp.py"'`; the tools only work in a pane, where `XHS_TOKEN` is set.

## What was verified, and what needs a human

Verified without a human:

- `swift test`, 42 tests: the bus operations, the `[from: ...]` prefix, refusal and queueing at a prompt, one message per idle, the owner-typing hold, control-character stripping, the HTTP server over loopback, the local and ssh command lines (parsed back by a real POSIX shell), and the snippets equal to what the app passes.
- Python tests, 9: the shim speaking MCP (initialize, tools/list, tools/call, errors) over pipes, the CLI, `xhs hook` and `xhs install`.
- `make smoke`: the bundled app opens a pane running `echo ok`, sees `ok` on its screen, gets an answer from its own bus, and quits with exit code 0.
- Probes against a stand-in bus (not part of the test suite), on this Mac:
  - Claude Code 2.1.311: `claude -p` with the app's `--settings` and `--mcp-config` POSTed hook events with the pane token, and the xhs `panes` tool reached the bus.
  - Codex 0.163.0: command hooks receive `XHS_TOKEN` (hook trust bypassed for the probe only), and the shim gets `XHS_TOKEN` through `env_vars` and reaches the bus.
  - pi 0.85.1 and 1.4.0, with the app's exact launch line: the extension registers Runner's models and picks the one given; it reports session start, prompt submit and settle; a message typed as bracketed paste plus Enter arrives as one multi-line user message. With pi 1.4.0 the extension's five events still fire; a 0.6B model on Runner answered a `[from: claude-1]` line on its own screen rather than with `xhs send`, so the pane spells the command out in pi's launch prompt.

Needs a human click-through:

- The window: adding and closing panes, the grid, header colours, the picker, dark mode switching.
- Claude, Codex and pi panes messaging each other in the real window, including a message queued at a real permission prompt.
- The first-run Codex config append and the hook-trust bypass taking effect.
- A remote pane over SSH with the reverse tunnel, and a real Runner.

## Not built

- Remembering the layout: panes are not restored on restart, because restarting harnesses unasked is worse than an empty window.
- Resizing, reordering or tabbing panes.
- Attaching to a session that was started outside the app (in a web terminal or on another screen). A pane is a session the app starts.
- A full activity heuristic for state: hooks carry the state, and the only heuristic is the 15 second still-screen rule that recovers a `running` pane from a lost Stop.
- A settings window or preferences file.

## Files

- `Sources/XHSCore/`: the bus, HTTP server, hook mapping, message delivery and launch commands. No UI; all tested.
- `Sources/XHSApp/`: the window (SwiftUI and AppKit, SwiftTerm panes). View state uses ObservableObjects because `@State` is a macro whose plugin ships only with Xcode.
- `tools/xhs-mcp.py`: the shim (MCP server, `xhs` command, `xhs hook`, `xhs install`). `tools/xhs-pi.ts`: the pi extension.
- `tools/snippets/`: peer-rule paragraphs and the hook and MCP config. `tools/remote-setup.sh`: the one-time install on an ssh host, POSIX or Windows.
- `packaging/Info.plist`, `packaging/make-icon.swift` (the icon), `Makefile`. `Sources/XHSApp/Theme.swift` holds the brand colours and the Ensō.
- `Package.swift` passes the swift-testing macro plugin path to the test target. Without it, test builds with the Command Line Tools fail on about every other run.

## Troubleshooting

- Red banner "The bus could not listen": another copy is running, or the port is taken. Quit the other copy or set `XHS_PORT`.
- A pane stays `starting`: a startup dialog waits for you, or the harness has not reported its session start yet. Your first prompt in that pane clears it (its Stop makes it `idle`).
- `/resume` in a pane lists other sessions than your terminal does: Claude Code lists sessions per folder, so give the pane the same start folder.
- A pane turns red at once: the harness is not on your login shell's PATH (the pane shows the error), or the ssh connection failed.
- A remote pane says `ssh: connect to host ... No route to host` while the host is up: macOS Local Network privacy. Allow the app under System Settings, Privacy & Security, Local Network (the app asks the first time it connects; a rebuilt app may ask again).
- A Windows pane shows `bash.exe is not recognized`: MSYS2 is not at `C:\msys64`. The app looks only there.
- `xhs: not inside Xyntetik Harness Supervisor`: `XHS_TOKEN` is set only in panes the app started.
- A pi pane answers on its own screen instead of over the bus, and says it has no tools: the model is not calling tools. The pane launches pi with its four tools; a small model may still ignore them.
