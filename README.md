<p align="center">
  <a href="https://xyntetik.com">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="packaging/readme/header-dark.svg">
      <img src="packaging/readme/header-light.svg" alt="Xyntetik Dojo" width="300">
    </picture>
  </a>
</p>

<p align="center">
  <b>One window for your coding agents, and a bus so they can talk.</b>
</p>

<p align="center">
  <a href="https://xyntetik.com">xyntetik.com</a> ·
  <a href="https://github.com/Joakimpalm-Zen/xyntetik-runner">Xyntetik Runner</a> ·
  <a href="#how-harnesses-talk">How harnesses talk</a> ·
  <a href="#safety-rules">Safety rules</a>
</p>

Running several coding agents at once means a desk full of terminals and you
as the messenger between them. Dojo puts Claude Code, Codex and
pi (on a local Runner model) in one window, on this Mac or over SSH, and gives
every one of them four small tools to list, read and message the others. You
watch, you type, you stay in charge.

- **One window.** A grid of real terminals (SwiftTerm, a pty each, drawn on the GPU). Press plus: Claude, Codex, pi or Runner, a host if it is remote, a folder to start in, a name if `claude-1` is not it. Rename later from the header.
- **They talk, you see it.** A harness runs `dojo send codex-1 "review the diff"` and the line lands in that terminal as typed input, tagged with its sender in the Xyntetik green. A busy pane reads it when its current step ends; a pane at a prompt gets it queued.
- **Never over your shoulder.** The bus never answers a prompt, never sends your half-written text, and every message carries its sender from the pane's token, not from the text.
- **A local model, fitted.** A Runner pane fetches Xyntetik Runner if needed, asks it about seven models from the first 16 MiB of each, and serves the largest whose resident weights fit in half of this Mac's RAM, wired in, for the pi panes.
- **Small on purpose.** SwiftPM only, no Xcode. One port, two text files of recent hosts and folders, nothing else kept. Apache 2.0.

**On this page:** [Install](#install) · [Requirements](#requirements) · [Build and run](#build-and-run) · [First run](#first-run) · [Adding a pane](#adding-a-pane) · [Remote panes](#remote-panes) · [How harnesses talk](#how-harnesses-talk) · [Safety rules](#safety-rules) · [What was verified](#what-was-verified-and-what-needs-a-human) · [Not built](#not-built) · [Files](#files) · [Troubleshooting](#troubleshooting) · [License](#license)

<a id="what-it-does"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> What it does

- One window with a grid of terminals. The plus button (or Cmd-T) adds one: pick Claude, Codex or pi. An optional host makes it remote (a Linux, Mac or Windows box over ssh). An optional folder is where the session starts (a repo root, a book folder); empty means your home folder. Hosts and folders you used before are one click away. An optional name replaces `claude-1`, `codex-1`, `pi-1`; double-click a name in a pane header (or right-click it) to rename the pane later. Drag a pane's header onto another pane and the two swap places. The harness keeps its token, so its messages carry the new name and others reach it by the new name from then on; it was told its old name at launch, so it may still introduce itself by that.
- It looks like a Xyntetik product: the site's colours on a recycled-paper ground (the same by day and night; the system's dark mode does not darken it), the Ensō as the app icon and in the window. A harness paints its own colours; the one thing the pane changes on the way to the screen is a white background (the band behind a user message in a light theme), which becomes the paper shade. Claude Code and Codex pick their theme themselves; `/theme light` in a Claude pane suits the paper. The icon is drawn by `packaging/make-icon.swift` at build time; no image file is checked in.
- Each pane is a real terminal (SwiftTerm and a pty the pane runs itself, so every byte from the harness passes the pane on its way to the screen). The harness sees an ordinary terminal.
- Panes draw on the GPU (SwiftTerm's Metal renderer), so a harness repainting its whole screen keeps up with a plain terminal.
- Each pane header shows the name, kind, host, model, queued messages and a state colour: grey starting, blue running, green idle, orange prompt, red exited.
- The app runs a bus on `127.0.0.1:7788`. Every harness in the window can call four operations: `panes`, `send`, `read` and `state`.

<a id="install"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> Install

Three commands on a Mac with the Command Line Tools (`xcode-select --install` once):

```sh
git clone https://github.com/Joakimpalm-Zen/xyntetik-dojo.git
cd xyntetik-dojo
make install    # builds the app and puts it in /Applications; make run opens it from the build instead
```

Or let the agent you already have do it. Paste this into Claude Code, Codex or pi:

> Install Xyntetik Dojo on this Mac: clone https://github.com/Joakimpalm-Zen/xyntetik-dojo.git, run `make install` in it (it needs the Command Line Tools and python3; tell me if either is missing), then open /Applications/XyntetikDojo.app and tell me what it asked for on first run.

The first run copies its small tools to `~/.dojo` and, if you have Codex, adds its bus entry to `~/.codex/config.toml` once. Everything it keeps is listed under [Build and run](#build-and-run).

<a id="requirements"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> Requirements

- macOS 14 or later. Built and tested on macOS 27 (Apple Silicon) with the Swift 6.4 Command Line Tools.
- `python3` on every host that runs a harness (the bus shim uses only the standard library).
- `claude`, `codex` and `pi` on your login shell's PATH, each already logged in.
- For pi: [Xyntetik Runner](https://github.com/Joakimpalm-Zen/xyntetik-runner) serving a model at `http://127.0.0.1:8080/v1`. A Runner pane sets that up (next section); if you already run Runner, pi uses it as it is.

<a id="build-and-run"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> Build and run

```
make test    # swift test (65 tests), the shim's Python tests (10), the Runner pick test and the hygiene check of the tree
make app     # build/XyntetikDojo.app, assembled by hand and ad-hoc signed
make run     # open the app from build/
make install # copy the app to /Applications (replacing the one there) and open it
make smoke   # launch proof: two panes, swapped as a drag does it; a click focuses the first and typed keys come back from its shell; the bus answers; the app quits (exit 0)
make smoke HOST=user@box   # the same, with the pane on that host over ssh
```

`DOJO_PORT` overrides the bus port. There is no other setting. The only files the app keeps are `~/.dojo/hosts` and `~/.dojo/folders` (the hosts and start folders you used, latest first, one per line) and `~/.dojo/runner/` (Runner's binary, its roster copy, the 16 MiB model heads, the fits list and your model choice); edit or delete them by hand.

<a id="first-run"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> First run

On start the app:

1. Copies `tools/dojo-mcp.py`, `tools/dojo-pi.ts` and `tools/runner-start.sh` to `~/.dojo/` and links `~/.dojo/bin/dojo`.
2. If `~/.codex` exists and `~/.codex/config.toml` has no `[mcp_servers.dojo]`, appends the block in `tools/snippets/codex-config.toml`: the dojo MCP server and six state hooks. It does this once and never edits the file again. Delete the block by hand to remove it.

**Renamed on 2026-10-29.** The app was Xyntetik Harness Supervisor and its command `xhs` until then. The first run of Dojo moves `~/.xhs` to `~/.dojo` (hosts, folders, Runner and its files come along) and replaces the old block in `~/.codex/config.toml` with the new one, keeping the file as it was beside it as `config.toml.before-dojo`. On an ssh host, run `make remote-setup HOST=...` again and delete `~/.xhs` there. A peer-rule snippet you installed by hand says `xhs`; replace it with the new one.

What needs you, once:

- **No permission prompts by default.** A Claude pane runs `claude --dangerously-skip-permissions` and a Codex pane runs `codex --yolo --dangerously-bypass-hook-trust` (no approvals, no sandbox, the six dojo state hooks trusted without a `/hooks` confirmation). That is the owner's choice for a supervised window; the harness in a pane can do anything your user can. Keep the window to work you would approve anyway.
- **Startup dialogs.** Claude and Codex may show their own first-run dialogs in the pane (folder trust, browser tools, an update offer). Answer them there. A pane turns `idle` when its harness reports that its session started.
- Codex shows two startup warnings: command-line config overrides run it without the shared background server (the app passes the peer rule with `-c developer_instructions`), and `--dangerously-bypass-hook-trust` is on. Both are expected.

<a id="adding-a-pane"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> Adding a pane

Press plus, pick Claude, Codex or pi; the host, folder and name fields under them belong to that agent. Runner, the local model server, has its own section at the bottom with its state beside the button. Leave the host empty for this Mac. A pane starts in the folder you give (type it, press Choose, or click a recent one), or in your home directory. With a host set, the folder is on that host, typed as it is there; Choose and the recent folders are this Mac's, so they step aside. It runs in your login shell (`$SHELL -l -i`), so PATH is the one your terminal has. A pane never inherits `CLAUDE*` variables from the process that opened the app (so `make run` from inside a Claude Code session does not make the pane's Claude a child session). Close a pane with its x button; that ends the harness.

A local pi pane first asks Runner for its models (`GET /v1/models`), starts pi with the first one and shows it in the header. If Runner does not answer, the pane says so and pi is not started.

**Runner.** The picker says whether Runner is serving on this Mac and what. If it is not, add a Runner pane: it runs `tools/runner-start.sh`, which keeps nothing about versions or models of its own:

- The binary is `runner` on your PATH if you have one; else `~/.dojo/runner/runner`, downloaded from the latest release (checked against its `SHA256SUMS`) and replaced when the latest release moves on.
- The models are Runner's own roster, `docs/model-tiers.json` in its repository: the Tier 1 and Tier 2 text models, fetched on every start (a copy is kept for when the network is away). A model admitted there is a candidate here the next time a Runner pane starts; nothing in this app changes.
- Every roster file no larger than this Mac's RAM is asked about with `runner --info fit` on its first 16 MiB. A model fits when the weights that stay resident (the hot set for a Gemma E-series model, whose row-gathered token table is never resident; the whole file otherwise, a mixture of experts included) are within half of the RAM. All that fit are listed in the pane and in `~/.dojo/runner/fits`, largest resident weights first.
- The pane serves the model you chose, or else the largest that fits, wired into RAM (`--mlock`). Runner's own verdict counts the RAM free right now: when it says the model fits, its context (16384, 8192 or 4096) and cache setting are used; when it says the model pages, the model is served anyway at context 16384 with a q8 cache and the rest of the machine makes room (what an 8 GB Mac with harnesses open does with Bolt E4B).
- **Choosing.** Once a Runner pane has run on this Mac (the list comes from the last start, which is when the heads are read and `--info fit` asked), the picker lists the models that fit, one per line with the resident size and serve flags; the one serving or chosen is filled in. Click another and the Runner pane is replaced by one serving it, and that choice is kept in `~/.dojo/runner/model` for later Runner panes (delete the file to go back to the largest that fits).

Runner does not take a place in the grid: it lives in a strip along the bottom of the window, one line with its state (what is being picked or fetched, then the model it serves). Its log opens above the strip while Runner starts, so you see the verdicts and the download, and closes once the server listens; click the strip to open or hide it. The picker follows the same pane and offers one Runner pane at a time. The strip's close button stops Runner. A Runner pane is local; on a host, start Runner yourself. Messages are never sent to a Runner pane.

<a id="remote-panes"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> Remote panes

Set up a host once, with one command from this repository:

```
tar -C tools -cf - dojo-mcp.py dojo-pi.ts | ssh user@box 'mkdir -p ~/.dojo && tar -C ~/.dojo -xf - && python3 ~/.dojo/dojo-mcp.py install'
```

(`make remote-setup HOST=user@box` runs the same.) It puts the shim and the pi extension in `~/.dojo` on that host, links `dojo`, and adds the Codex entries there if Codex is installed. Nothing else runs on the remote host.

Then press plus and enter `user@box` as the host (or click it under Recent once you have used it). The app first asks the host which shell it runs commands in (`ssh host 'echo %OS%'`), then runs:

```
ssh -t -R 7788:127.0.0.1:7788 user@box '<harness in the remote login shell>'
```

The harness runs in the remote login shell (`$SHELL -l -i`), so it needs to be on the PATH that shell sets. The reverse tunnel lets the shim on the remote host reach the bus at `127.0.0.1:7788` there. The remote host's own keys, logins and tokens are used; the app stores none. Use key-based SSH; a password prompt shows up in the pane. A remote pi uses the Runner on that host.

### Windows hosts

A Windows host with OpenSSH Server and MSYS2 at `C:\msys64` works the same way. The probe sees cmd.exe answer `Windows_NT`, and the pane then runs the same harness command in MSYS2's bash (`bash.exe -l`, with your Windows PATH inherited, so `claude` and `codex` are found where you installed them). The command travels to cmd.exe as base64, so none of its quotes, pipes or percent signs are seen by cmd.exe.

`make remote-setup HOST=user@winbox` detects Windows too. There, `dojo install` writes two small sh scripts in `~/.dojo/bin` instead of a symlink: `dojo`, and a `python3` that runs the Python it was installed with (on Windows, `python3` on PATH is usually the Microsoft Store stub). The harness line puts `~/.dojo/bin` first on PATH, so the MCP shim and hooks find a working `python3`.

Verified: a pane on a Windows 11 host over ssh (`make smoke HOST=...`), the remote setup there, and Claude Code on that host reaching the bus through the tunnel. Codex on a Windows host is not verified: its config hooks call `python3 "$HOME/.dojo/dojo-mcp.py" hook`, which depends on the shell Codex uses for hook commands there.

Two remote panes on the same host share the forwarded port: the first pane's tunnel serves both (ssh warns about the second forward). If the first pane closes, the second loses the bus until you reopen it.

<a id="how-harnesses-talk"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> How harnesses talk

The four operations, as MCP tools for Claude and Codex (`mcp__dojo__panes` and so on) and as the `dojo` command for pi and any shell in a pane:

```
dojo panes                         # name, kind, host, state, queued, model; * marks you
dojo send codex-1 "please review the diff in src/bus.rs"
dojo read claude-1 60              # last 60 lines of claude-1's screen
dojo state pi-1
```

`send` types `[from: <your pane>] <text>` into the target terminal and presses Enter, so the target harness gets it as typed input. Ask any harness to do it in plain words: "send codex-1 a summary of what you changed".

| Harness | Bus tools | State | Peer rule |
|---|---|---|---|
| Claude Code | `--mcp-config` at launch | hooks via `--settings` at launch: SessionStart and PostModelSwitch as command hooks (`dojo hook`; Claude Code runs no http hooks for SessionStart; PostModelSwitch carries the new model for the header), http hooks for UserPromptSubmit, PermissionRequest, PostToolUse, Stop, Notification (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `elicitation_dialog`) | `--append-system-prompt` |
| Codex | `[mcp_servers.dojo]` in `~/.codex/config.toml` | command hooks in the same file (`dojo hook`): SessionStart, UserPromptSubmit, PermissionRequest, PostToolUse, Stop, Interrupt | `-c developer_instructions` |
| pi | the `dojo` command (pi has no MCP by design; it runs `dojo` with its bash tool). The pane passes `--tools read,bash,edit,write`, so a `defaultTools` setting of yours cannot leave it without bash, and `--tui-mode fullscreen`, so the composer sits at the bottom of the pane whatever your `tuiMode` setting says | the `dojo-pi.ts` extension: session_start, agent_start, agent_settled, ui_prompt_start, ui_prompt_end | `--append-system-prompt` |

The pi extension also registers Runner as pi's `runner` provider.

<a id="safety-rules"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> Safety rules

- **A relayed message never answers a prompt.** The bus types into a pane that is `idle` or `running`; a busy harness keeps the input in its own queue and reads it when its current step ends, sooner than the end of its turn. A pane at a permission prompt or question dialog (`prompt`) or not yet started (`starting`) gets the message queued. Whatever has queued goes out as one input, each message on its own line, the moment the pane can take it.
- **Your unsent text is never sent for you.** The bus holds a pane's queue while you have typed into it in the last 3 seconds and while unsent text sits in its composer (the header says "unsent text here"). Enter sends your text and releases the queue; Ctrl-C or Ctrl-U clearing it does the same. The hold counts keystrokes, so a word deleted at once can leave it on; Enter on the empty composer turns it off.
- **A fresh Codex pane is ready without a hello.** Codex sends SessionStart with the first prompt, not at startup, so the bus treats a `starting` Codex pane as idle once its screen shows the composer ("Ask Codex to do anything") and has been still for 3 seconds. A Codex startup dialog covers the composer, so the bus does not type into one. Claude and pi announce their start themselves.
- **A lost Stop does not hold messages forever.** A turn can end without a Stop hook (Codex at its usage limit did). A `running` pane whose screen has not changed for 15 seconds is idle again; every harness animates a spinner while it works. A pane at a `prompt` is never timed out.
- **Every message carries its sender.** The sender is taken from the calling pane's token, not from the message text; a `[from: ...]` tag a harness puts at the front of its own text is dropped, so the tag is never doubled or faked. The `[from: <name>]` tag shows in the Xyntetik green wherever a harness paints it: the pane colours it on the way from the harness to the screen.
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

`tools/snippets/claude-settings.json` and `tools/snippets/claude-mcp.json` are exactly what the app passes to Claude at launch (tests keep them equal). You do not need to install them. A by-hand equivalent of the MCP part is `claude mcp add --scope user dojo -- sh -c 'exec python3 "$HOME/.dojo/dojo-mcp.py"'`; the tools only work in a pane, where `DOJO_TOKEN` is set.

<a id="what-was-verified-and-what-needs-a-human"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> What was verified, and what needs a human

Verified without a human:

- `swift test`, 64 tests: the bus operations, the `[from: ...]` prefix, refusal and queueing at a prompt, delivery into a running pane and the queue as one input, the owner-typing and unsent-text holds, control-character stripping, the HTTP server over loopback, the local and ssh command lines (parsed back by a real POSIX shell), and the snippets equal to what the app passes.
- Python tests, 10: the shim speaking MCP (initialize, tools/list, tools/call, errors) over pipes, the CLI, `dojo hook` and `dojo install`.
- `sh tools/test_runner_start.sh`: the Runner pick against a stub runner and a stub Hub: the largest model with a FITS verdict wins, with the `--kv` setting the verdict names.
- `make smoke`: the bundled app opens a pane running `echo ok`, sees `ok` on its screen, gets an answer from its own bus, and quits with exit code 0.
- Probes against a stand-in bus (not part of the test suite), on this Mac:
  - Claude Code 2.1.311: `claude -p` with the app's `--settings` and `--mcp-config` POSTed hook events with the pane token, and the dojo `panes` tool reached the bus.
  - Codex 0.163.0: command hooks receive `DOJO_TOKEN` (hook trust bypassed for the probe only), and the shim gets `DOJO_TOKEN` through `env_vars` and reaches the bus.
  - pi 0.85.1 and 1.4.0, with the app's exact launch line: the extension registers Runner's models and picks the one given; it reports session start, prompt submit and settle; a message typed as bracketed paste plus Enter arrives as one multi-line user message. With pi 1.4.0 the extension's five events still fire; a 0.6B model on Runner answered a `[from: claude-1]` line on its own screen rather than with `dojo send`, so the pane spells the command out in pi's launch prompt, along with `curl -sL` for web pages (a small model's bare `curl -s` shows nothing on a redirect) and a preference for RSS feeds.

Needs a human click-through:

- The window: adding and closing panes, the grid, header colours, the picker, the paper ground under dark mode.
- Claude, Codex and pi panes messaging each other in the real window, including a message queued at a real permission prompt.
- The first-run Codex config append and the hook-trust bypass taking effect.
- A remote pane over SSH with the reverse tunnel, and a real Runner.

<a id="not-built"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> Not built

- Remembering the layout: panes are not restored on restart, because restarting harnesses unasked is worse than an empty window.
- Resizing or tabbing panes (dragging a header onto another pane swaps the two).
- Attaching to a session that was started outside the app (in a web terminal or on another screen). A pane is a session the app starts.
- A full activity heuristic for state: hooks carry the state, and the only heuristic is the 15 second still-screen rule that recovers a `running` pane from a lost Stop.
- A settings window or preferences file.

<a id="files"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> Files

- `Sources/XHSCore/`: the bus, HTTP server, hook mapping, message delivery and launch commands. No UI; all tested.
- `Sources/XHSApp/`: the window (SwiftUI and AppKit, SwiftTerm panes). View state uses ObservableObjects because `@State` is a macro whose plugin ships only with Xcode.
- `tools/dojo-mcp.py`: the shim (MCP server, `dojo` command, `dojo hook`, `dojo install`). `tools/dojo-pi.ts`: the pi extension.
- `tools/snippets/`: peer-rule paragraphs and the hook and MCP config. `tools/remote-setup.sh`: the one-time install on an ssh host, POSIX or Windows. `tools/check-hygiene.py`: the mechanical half of AGENTS.md (commit trailers, no session ids or addresses, no em dashes in prose, nothing personal in the tree), run by `make test` and by the `hygiene` workflow on every pull request; `.github/workflows/ci.yml` tests and bundles on macOS, on pull requests and once a week, with the SwiftPM build cached on the dependency lock. `tools/runner-start.sh`: find or fetch the latest Runner, read its roster, list what fits, serve the choice (`tools/test_runner_start.sh` checks it against a stub runner, Hub, GitHub and machine size, online and offline).
- `packaging/Info.plist`, `packaging/make-icon.swift` (the icon), `Makefile`. `Sources/XHSApp/Theme.swift` holds the brand colours and the Ensō.
- `Package.swift` passes the swift-testing macro plugin path to the test target. Without it, test builds with the Command Line Tools fail on about every other run.

<a id="troubleshooting"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> Troubleshooting

- Red banner "The bus could not listen": another copy is running, or the port is taken (the app waits five seconds for a copy that was just quit to let go of it first). Quit the other copy or set `DOJO_PORT`.
- A pane stays `starting`: a startup dialog waits for you, or the harness has not reported its session start yet. Your first prompt in that pane clears it (its Stop makes it `idle`).
- `/resume` in a pane lists other sessions than your terminal does: Claude Code lists sessions per folder, so give the pane the same start folder.
- A pane turns red at once: the harness is not on your login shell's PATH (the pane shows the error), or the ssh connection failed.
- A remote pane says `ssh: connect to host ... No route to host` while the host is up: macOS Local Network privacy. Allow the app under System Settings, Privacy & Security, Local Network (the app asks the first time it connects; a rebuilt app may ask again).
- A Windows pane shows `bash.exe is not recognized`: MSYS2 is not at `C:\msys64`. The app looks only there.
- Claude Code on a Windows host draws its prompt near the top of the pane rather than at the bottom. That is how it renders on a Windows console; the pane passes the right size (`make smoke HOST=...` prints it) and resizes reach the host.
- `dojo: not inside Xyntetik Dojo`: `DOJO_TOKEN` is set only in panes the app started.
- A pi pane answers on its own screen instead of over the bus, and says it has no tools: the model is not calling tools. The pane launches pi with its four tools; a small model may still ignore them.

<a id="license"></a>
## <img src="packaging/readme/section.svg" width="8" height="24" alt=""> License

[Apache 2.0](LICENSE). Built in Sweden by [Xyntetik](https://xyntetik.com).
