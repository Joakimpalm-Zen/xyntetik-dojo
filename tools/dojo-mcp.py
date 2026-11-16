#!/usr/bin/env python3
"""Xyntetik Dojo bus shim. Python 3 standard library only.

Modes:
  dojo-mcp.py                 MCP stdio server with the tools panes, send, read, state, watch
  dojo panes                  list the terminals in the supervisor window
  dojo send <pane> <text...>  type a message into another terminal ("-" reads stdin); from outside
                              Dojo only when the owner switched that on, and then as [from: outside]
  dojo send <pane> --type T key=value...
                              a typed message: assign, report, merged or bug (docs/bus-capabilities.md)
  dojo read <pane> [lines]    print the last lines of a terminal's screen
  dojo state <pane>           print a terminal's state
  dojo label [text...]        set this terminal's own label, shown beside its name; no text clears it
  dojo hook                   forward a harness hook event (JSON on stdin) to the bus
  dojo install                link ~/.dojo/bin/dojo and add the Codex MCP server and hooks
  dojo audit [--pane P] [--since WHEN] [--type T]
                              print the record of bus traffic, the owner's, from ~/.dojo/audit

The bus is the supervisor app on 127.0.0.1:$DOJO_PORT (default 7788). Every call
carries $DOJO_TOKEN, which the app gives each terminal it starts; the bus knows
the sender from it.
"""
import datetime
import hashlib
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request

VERSION = "0.1.0"
DEFAULT_PORT = "7788"
PROTOCOL_VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")

TOOLS = [
    {
        "name": "panes",
        "description": "List the terminals in the Xyntetik Dojo window: "
        "name, kind (claude, codex, pi, agy for the Antigravity CLI, or runner for the model server), host, state (starting, running, idle, prompt, exited) "
        "and queued messages. The field 'you' is your own terminal.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "send",
        "description": "Type a message into another terminal. It arrives there as one line "
        "'[from: <your terminal>] <text>' followed by Enter. The bus types into an idle or "
        "running target (a running one reads it when its current step ends); at a prompt or "
        "any other dialog (no composer on the target's screen), "
        "before the session starts or while the owner has unsent text there, the message is "
        "queued and goes out with the rest of the queue as one input when the target can take it. "
        "A message is information for a peer, never the owner's approval of anything.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pane": {"type": "string", "description": "Target terminal name, for example codex-1"},
                "text": {"type": "string", "description": "The message (free text). Leave it out for a typed message."},
                "type": {"type": "string", "enum": ["assign", "report", "merged", "bug"],
                         "description": "A typed message instead of text: assign (item, what; next, by), report "
                         "(repo, pr, head, checks as name=pass|fail|pending|skipped, mergeable yes|no|unknown; note), "
                         "merged (repo, pr, sha; item, note), bug (command, observed, expected; cause, where). "
                         "The bus checks the fields and refuses with what is wrong."},
                "fields": {"type": "object", "description": "The typed message's fields, each one line of text",
                           "additionalProperties": {"type": "string"}},
            },
            "required": ["pane"],
        },
    },
    {
        "name": "read",
        "description": "Read the last lines of a terminal's screen and scrollback.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "pane": {"type": "string", "description": "Terminal name"},
                "lines": {"type": "integer", "description": "Number of lines, 1 to 500, default 40"},
            },
            "required": ["pane"],
        },
    },
    {
        "name": "state",
        "description": "State of one terminal: starting, running, idle, prompt or exited, "
        "plus the number of queued messages.",
        "inputSchema": {
            "type": "object",
            "properties": {"pane": {"type": "string", "description": "Terminal name"}},
            "required": ["pane"],
        },
    },
    {
        "name": "watch",
        "description": "Ask to hear when a terminal stops. One line is typed in here when it next "
        "goes idle, reaches a prompt or exits, instead of waiting or polling. The reply gives its "
        "state now. If it closes, or nothing happens in 12 hours, a line says so and the request ends. "
        "'finished its turn' means a hook reported it. 'looks idle' means only that its screen has been "
        "still for 15 seconds with no such report: the turn may still be going, so read the pane or watch again.",
        "inputSchema": {
            "type": "object",
            "properties": {"pane": {"type": "string", "description": "Terminal name"}},
            "required": ["pane"],
        },
    },
]
TOOL_NAMES = {t["name"] for t in TOOLS}


class BusError(Exception):
    pass


def bus_call(op, payload, timeout=10):
    token = os.environ.get("DOJO_TOKEN", "")
    if not token:
        raise BusError("not inside Xyntetik Dojo: DOJO_TOKEN is not set")
    port = os.environ.get("DOJO_PORT", DEFAULT_PORT)
    req = urllib.request.Request(
        "http://127.0.0.1:%s/%s" % (port, op),
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-Dojo-Token": token},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail).get("error", detail)
        except ValueError:
            pass
        raise BusError("bus refused (%d): %s" % (e.code, detail))
    except (urllib.error.URLError, OSError) as e:
        raise BusError("bus not reachable on 127.0.0.1:%s: %s" % (port, e))
    return json.loads(body.decode("utf-8")) if body else {}


def outside_token_file():
    return os.path.join(os.path.expanduser("~"), ".dojo", "outside-token")


def outside_send(pane, text, timeout=10):
    """D15 (b): `dojo send` from a program outside Dojo. Only while the owner has switched the outside
    route on (~/.dojo/outside), when the app keeps its token and port in ~/.dojo/outside-token. The line
    arrives as [from: outside]: the route names the sender, never this program."""
    try:
        with open(outside_token_file(), encoding="utf-8") as f:
            info = json.load(f)
        token, port = str(info["token"]), int(info["port"])
    except (OSError, ValueError, KeyError, TypeError):
        raise BusError("not inside Xyntetik Dojo: DOJO_TOKEN is not set, and sending from outside is off "
                       "(see Sending from outside Dojo in the guide)")
    req = urllib.request.Request(
        "http://127.0.0.1:%d/outside/send" % port,
        data=json.dumps({"pane": pane, "text": text}).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-Dojo-Outside-Token": token},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail).get("error", detail)
        except ValueError:
            pass
        raise BusError("bus refused (%d): %s" % (e.code, detail))
    except (urllib.error.URLError, OSError) as e:
        raise BusError("bus not reachable on 127.0.0.1:%d: %s" % (port, e))
    return json.loads(body.decode("utf-8")) if body else {}


# ---------------------------------------------------------------- MCP server

def redaction_note(count):
    """What `read` says when the bus took secrets out of the screen it returns (D21.2)."""
    return "The bus took %d secret%s out of this text (tokens and keys show as [dojo token] or [redacted: ...])." % (
        count, "" if count == 1 else "s")


def tool_payload(name, args):
    if not isinstance(args, dict):
        raise ValueError("arguments must be an object, got %s" % type(args).__name__)
    if name == "panes":
        return {}
    if name == "send":
        if args.get("type") is not None:
            fields = args.get("fields") or {}
            if not isinstance(fields, dict):
                raise ValueError("fields must be an object")
            return {"pane": str(args.get("pane", "")), "type": str(args["type"]),
                    "fields": {str(k): str(v) for k, v in fields.items()}}
        return {"pane": str(args.get("pane", "")), "text": str(args.get("text", ""))}
    if name == "read":
        return {"pane": str(args.get("pane", "")), "lines": int(args.get("lines", 40) or 40)}
    return {"pane": str(args.get("pane", ""))}


def handle(msg):
    """Return the JSON-RPC response for one message, or None for notifications."""
    if not isinstance(msg, dict):
        return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}}
    method = msg.get("method")
    mid = msg.get("id")
    if mid is None:
        return None
    params = msg.get("params") or {}
    if method == "initialize":
        asked = params.get("protocolVersion")
        version = asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]
        result = {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "dojo", "version": VERSION},
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS if os.environ.get("DOJO_TOKEN") else []}
    elif method == "tools/call":
        name = params.get("name")
        if name not in TOOL_NAMES:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "Unknown tool: %s" % name}}
        arguments = params.get("arguments") or {}
        try:
            payload = tool_payload(name, arguments)
        except (TypeError, ValueError, OverflowError) as e:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "Invalid arguments for %s: %s" % (name, e)}}
        try:
            out = bus_call(name, payload)
            if name == "read":
                text = out.get("text", "")
            else:
                text = json.dumps(out, indent=2)
            content = [{"type": "text", "text": text}]
            if name == "read" and out.get("redacted"):
                content.append({"type": "text", "text": redaction_note(out["redacted"])})
            result = {"content": content, "isError": False}
        except (BusError, ValueError) as e:
            # The arguments as received, so a refusal says what the call carried.
            text = "%s (tool %s called with %s)" % (e, name, json.dumps(arguments, sort_keys=True)[:300])
            result = {"content": [{"type": "text", "text": text}], "isError": True}
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found: %s" % method}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def serve(stdin=sys.stdin, stdout=sys.stdout):
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            reply = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        else:
            try:
                reply = handle(msg)
            except Exception as e:  # a server that dies takes all its tools with it for the session
                mid = msg.get("id") if isinstance(msg, dict) else None
                reply = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": "Internal error: %s" % e}}
        if reply is not None:
            stdout.write(json.dumps(reply) + "\n")
            stdout.flush()


# ---------------------------------------------------------------- install

CODEX_BLOCK = '''
# Xyntetik Dojo: bus tools and state hooks (added by "dojo install")
[mcp_servers.dojo]
command = "sh"
args = ["-c", "exec python3 \\"$HOME/.dojo/dojo-mcp.py\\""]
env_vars = ["DOJO_TOKEN", "DOJO_PORT", "DOJO_PANE"]
'''
CODEX_HOOK_EVENTS = ("SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt")
CODEX_HOOK = '''
[[hooks.%s]]
[[hooks.%s.hooks]]
type = "command"
command = "python3 \\"$HOME/.dojo/dojo-mcp.py\\" hook"
timeout = %d
'''


def codex_block():
    # Codex allows an Interrupt hook at most 3 seconds and warns at startup about more.
    return CODEX_BLOCK + "".join(CODEX_HOOK % (e, e, 3 if e == "Interrupt" else 5) for e in CODEX_HOOK_EVENTS)


WRAPPER = "#!/bin/sh\n%s\nexec \"%s\" %s\"$@\"\n"


def write_wrapper(path, python, script_args="", prelude=""):
    """A small sh script (for MSYS2's sh) that runs this Python with the given arguments first."""
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(WRAPPER % (prelude, python.replace("\\", "/"), script_args))
    os.chmod(path, 0o755)


# The app was called Harness Supervisor and its command "xhs" until 2026-10-29. A Codex config that still
# carries that block gets it replaced: the MCP server table, the marker comment and every hook stanza
# that ran the old shim go, the new block is appended, and the file as it was is kept beside it.
OLD_MARKER = "# Xyntetik Harness Supervisor"
OLD_SERVER = "[mcp_servers.xhs]"
OLD_SCRIPT = "xhs-mcp.py"


def toml_stanzas(text, strip_old_marker=False):
    """Return normalized table headers and their original source lines, including the root stanza."""
    # Keep source lines intact, but recognize tables only outside strings, comments and arrays.
    # A lexical scan matters here: counting triple quotes also counts examples and inline comments.
    def scan(line, quote, depth):
        i = 0
        while i < len(line):
            c = line[i]
            if quote:
                if quote[0] == '"' and c == "\\":
                    i += 2
                    continue
                if line.startswith(quote, i):
                    i += len(quote)
                    if len(quote) == 3:
                        # A multiline closing delimiter may include one or two trailing quotes.
                        for _ in range(2):
                            if i < len(line) and line[i] == quote[0]:
                                i += 1
                    quote = None
                else:
                    i += 1
            elif c == "#":
                break
            elif c in "\"'":
                quote = c * 3 if line.startswith(c * 3, i) else c
                i += len(quote)
            else:
                if c in "[{":
                    depth += 1
                elif c in "]}":
                    depth -= 1
                i += 1
        return quote, depth

    key = r"(?:[A-Za-z0-9_-]+|\"(?:\\.|[^\"\\])*\"|'[^']*')"
    table = re.compile(r"\s*(\[\[?)\s*(" + key + r"(?:\s*\.\s*" + key + r")*)\s*(\]\]?)\s*(?:#.*)?$")

    def table_header(line):
        match = table.fullmatch(line.rstrip("\r\n"))
        if not match or len(match[1]) != len(match[3]):
            return None
        parts = []
        for part in re.findall(key, match[2]):
            if part.startswith("'"):
                part = part[1:-1]
            elif part.startswith('"'):
                # TOML basic keys share JSON escapes and also allow eight-digit Unicode escapes.
                # Decode left to right so an escaped backslash before U remains literal text.
                decoded, i = [], 1
                escapes = {"b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r", '"': '"', "\\": "\\"}
                while i < len(part) - 1:
                    if part[i] != "\\":
                        decoded.append(part[i])
                        i += 1
                        continue
                    code = part[i + 1]
                    if code in "uU":
                        width = 4 if code == "u" else 8
                        decoded.append(chr(int(part[i + 2:i + 2 + width], 16)))
                        i += 2 + width
                    else:
                        decoded.append(escapes[code])
                        i += 2
                part = "".join(decoded)
            parts.append(part if re.fullmatch(r"[A-Za-z0-9_-]+", part) else json.dumps(part))
        return match[1] + ".".join(parts) + match[3]

    stanzas, pending, quote, depth = [], [], None, 0
    for line in text.splitlines(keepends=True):
        outside = quote is None and depth == 0
        h = table_header(line) if outside else None
        if h is not None:
            stanzas.append((h, pending + [line]))
            pending = []
            continue
        if outside and (line.lstrip().startswith("#") or not line.strip()):
            if not (strip_old_marker and line.lstrip().startswith(OLD_MARKER)):
                pending.append(line)
            continue
        if not stanzas:
            stanzas.append(("", []))
        stanzas[-1][1].extend(pending)
        pending = []
        stanzas[-1][1].append(line)
        quote, depth = scan(line, quote, depth)
    if pending:
        if not stanzas:
            stanzas.append(("", []))
        stanzas[-1][1].extend(pending)

    return stanzas


def without_old_block(text):
    """Remove the old bus tables and hook groups while preserving every other source line."""
    stanzas = toml_stanzas(text, strip_old_marker=True)

    def header(st):
        return st[0]

    def old_child(st):
        return header(st).startswith("[[hooks.") and header(st).endswith(".hooks]]") and OLD_SCRIPT in "".join(st[1])

    drop = set()
    for i, st in enumerate(stanzas):
        h = header(st)
        if h == OLD_SERVER or h.startswith(OLD_SERVER[:-1] + "."):
            drop.add(i)
        elif old_child(st):
            drop.add(i)
        elif h.startswith("[[hooks.") and not h.endswith(".hooks]]"):
            # The group's children follow it; the group goes only if every child is old.
            children = []
            for j in range(i + 1, len(stanzas)):
                if header(stanzas[j]).startswith(h[:-2] + ".hooks]]"):
                    children.append(j)
                else:
                    break
            if children and all(old_child(stanzas[j]) for j in children):
                drop.add(i)
    kept = [l for i, st in enumerate(stanzas) if i not in drop for l in st[1]]
    return "".join(kept)


def install(home=None, out=sys.stdout, windows=None):
    # The shell's HOME, where remote-setup put this script and where every pane looks ("$HOME/.dojo").
    # On POSIX that is what expanduser reads anyway; a native Windows Python reads USERPROFILE instead,
    # which a host can point HOME away from (MSYS2's own /home, say), so HOME wins when it is set.
    home = home or os.environ.get("HOME") or os.path.expanduser("~")
    windows = sys.platform == "win32" if windows is None else windows
    dojo_dir = os.path.join(home, ".dojo")
    script = os.path.join(dojo_dir, "dojo-mcp.py")
    if not os.path.exists(script):
        out.write("dojo install: put this script at %s first\n" % script)
        return 1
    os.chmod(script, 0o755)
    bin_dir = os.path.join(dojo_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    link = os.path.join(bin_dir, "dojo")
    if os.path.lexists(link):
        os.remove(link)
    if windows:
        # No symlinks without privileges, and "python3" is the Microsoft Store stub there. The harness line
        # puts ~/.dojo/bin first on PATH, so these two scripts give MSYS2's sh a python3 and an dojo that work.
        write_wrapper(os.path.join(bin_dir, "python3"), sys.executable)
        write_wrapper(link, sys.executable, '"$(dirname "$0")/../dojo-mcp.py" ', '[ $# -eq 0 ] && set -- help')
        out.write("dojo install: %s and %s (Windows: sh wrappers around %s)\n" % (link, os.path.join(bin_dir, "python3"), sys.executable))
    else:
        os.symlink("../dojo-mcp.py", link)
        out.write("dojo install: %s\n" % link)
    codex_dir = os.path.join(home, ".codex")
    if os.path.isdir(codex_dir):
        config = os.path.join(codex_dir, "config.toml")
        text = ""
        if os.path.exists(config):
            with open(config, encoding="utf-8", newline="") as f:
                text = f.read()
        headers = {header for header, _ in toml_stanzas(text)}
        if any(h == OLD_SERVER or h.startswith(OLD_SERVER[:-1] + ".") for h in headers):
            if not os.path.exists(config + ".before-dojo"):
                shutil.copy2(config, config + ".before-dojo")  # preserve the first backup, byte for byte
            text = without_old_block(text)
            with open(config, "w", encoding="utf-8", newline="") as f:
                f.write(text)
            out.write("dojo install: removed the old xhs block from %s (the file as it was: %s.before-dojo)\n" % (config, config))
        if "[mcp_servers.dojo]" in headers:
            out.write("dojo install: %s already has [mcp_servers.dojo], left as is\n" % config)
        else:
            with open(config, "a", encoding="utf-8") as f:
                if text and not text.endswith("\n"):
                    f.write("\n")
                f.write(codex_block())
            out.write("dojo install: added the dojo MCP server and hooks to %s\n" % config)
    install_agy(home, out, windows)
    return 0


# ---------------------------------------------------------------- agy's plugin (D38)
# agy takes hooks and MCP servers only from files, never from its command line (its --settings has no key
# for them), so "dojo install" gives it Dojo's plugin: the state hooks and the bus in one unit, which the
# owner can switch off or remove with agy plugin disable / uninstall. The owner's pick on 2026-11-16. The
# route lives in `register_agy_plugin`: the fallback (agy mcp add and a hooks.json entry) goes there.

AGY_HOOK_COMMAND = 'python3 "$HOME/.dojo/dojo-mcp.py" hook agy'


def agy_plugin_files(home):
    """The plugin's files: its manifest, its hooks (agy 1.5.9's hooks.json: one named hook, flat lists for the
    events without a tool, a matcher group for the tool events) and the bus as its MCP server. agy runs a
    hook with sh, which expands $HOME, and starts an MCP server itself, which expands nothing: the server's
    path is written out for this home."""
    handler = {"type": "command", "command": AGY_HOOK_COMMAND, "timeout": 5}
    hooks = {"dojo": {
        "SessionStart": [handler],
        "PreInvocation": [handler],
        # The question alone: agy stops a tool whose PreToolUse hook answers without a decision (a live run
        # on 2026-11-16 had the dojo tool refused so), and Dojo has no say over any other tool.
        "PreToolUse": [{"matcher": "ask_question", "hooks": [handler]}],
        "PostToolUse": [{"matcher": "*", "hooks": [handler]}],
        "Stop": [handler],
    }}
    return {
        "plugin.json": {"name": "dojo", "version": "1.0.0",
                        "description": "Xyntetik Dojo: the bus tools and the pane's state hooks. Does nothing outside a Dojo pane."},
        "hooks.json": hooks,
        "mcp_config.json": {"mcpServers": {"dojo": {"command": "python3", "args": [os.path.join(home, ".dojo", "dojo-mcp.py")]}}},
    }


def write_agy_plugin(folder, home):
    """Writes the plugin for `home` into `folder` (made or replaced) and returns it."""
    os.makedirs(folder, exist_ok=True)
    for name, content in agy_plugin_files(home).items():
        with open(os.path.join(folder, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(content, indent=2) + "\n")
    return folder


def find_agy(home):
    """agy on the PATH, or where its installer puts it; the app's own PATH is the system's alone."""
    found = shutil.which("agy")
    if found:
        return found
    local = os.path.join(home, ".local", "bin", "agy")
    return local if os.access(local, os.X_OK) else None


def register_agy_plugin(agy, folder):
    """The install route, in one place: agy copies the plugin into its config and records it (agy plugin
    install replaces an earlier copy, and keeps the owner's enabled or disabled choice)."""
    import subprocess
    env = dict(os.environ, BROWSER="/usr/bin/true")
    return subprocess.run([agy, "plugin", "install", folder], capture_output=True, text=True, env=env, timeout=60,
                          stdin=subprocess.DEVNULL)


def install_agy(home, out, windows):
    # Only where agy is set up: its folder in this home. A test's home has none, so no test reaches an agy.
    if not os.path.isdir(os.path.join(home, ".gemini")):
        return
    if windows:
        # agy runs hooks and its status line with cmd.exe there, where "$HOME" is not a variable.
        out.write("dojo install: agy on Windows is not supported by Dojo yet; no plugin installed\n")
        return
    agy = find_agy(home)
    if not agy:
        out.write("dojo install: agy was not found (PATH, ~/.local/bin); its plugin is not installed\n")
        return
    folder = write_agy_plugin(os.path.join(home, ".dojo", "agy", "dojo"), home)
    # The app runs this at every start: agy is asked only when its copy is not this plugin.
    installed = os.path.join(home, ".gemini", "config", "plugins", "dojo")
    if all(read_text(os.path.join(installed, name)) == read_text(os.path.join(folder, name)) for name in agy_plugin_files(home)):
        out.write("dojo install: agy already has Dojo's plugin (%s)\n" % installed)
        return
    try:
        done = register_agy_plugin(agy, folder)
    except Exception as e:
        out.write("dojo install: agy plugin install failed: %s\n" % e)
        return
    if done.returncode == 0:
        out.write("dojo install: agy plugin install %s (the bus and the state hooks for agy panes)\n" % folder)
    else:
        out.write("dojo install: agy plugin install %s failed (%d): %s\n" % (folder, done.returncode,
                                                                           (done.stderr or done.stdout).strip()[:200]))


# ---------------------------------------------------------------- the record (D21.2)
# The app writes one JSON line per bus operation to ~/.dojo/audit/<day>.jsonl, each with the SHA-256 of
# the line before it in "prev". `dojo audit` reads the files directly: the record is not a bus route.

AUDIT_DAY = re.compile(r"^\d{4}-\d{2}-\d{2}\.jsonl$")
# A typed message's fields are in its text, the card as delivered; the type stays in the line.
AUDIT_SHOWN = ("time", "prev", "op", "from", "pane", "outcome", "text", "fields")


def audit_folder(home=None):
    return os.path.join(home or os.path.expanduser("~"), ".dojo", "audit")


def audit_since(text, now=None):
    """30m, 2h, 3d, or a date or time (UTC unless it says otherwise), as a unix time."""
    m = re.fullmatch(r"(\d+)([mhd])", text)
    if m:
        return (now if now is not None else time.time()) - int(m.group(1)) * {"m": 60, "h": 3600, "d": 86400}[m.group(2)]
    try:
        when = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        raise ValueError("--since takes 30m, 2h, 3d, or a date or time such as 2026-11-10T14:00")
    if when.tzinfo is None:
        when = when.replace(tzinfo=datetime.timezone.utc)
    return when.timestamp()


def audit_entries(folder):
    """Every line, oldest first, and where the chain breaks. The first line of the oldest file is where the
    check starts: the files before it may have been deleted after 30 days."""
    entries, problems, prev = [], [], None
    names = sorted(n for n in os.listdir(folder) if AUDIT_DAY.match(n)) if os.path.isdir(folder) else []
    for name in names:
        with open(os.path.join(folder, name), "rb") as fh:
            raw_lines = fh.read().split(b"\n")
        for number, raw in enumerate(raw_lines, 1):
            if not raw:
                continue
            try:
                entry = json.loads(raw.decode("utf-8"))
            except ValueError:
                entry = None
            if not isinstance(entry, dict):
                problems.append("%s:%d: not a record line" % (name, number))
            elif prev is not None and entry.get("prev") != prev:
                problems.append("%s:%d: the chain breaks here: a line before it was removed or changed" % (name, number))
            prev = hashlib.sha256(raw).hexdigest()
            if isinstance(entry, dict):
                entries.append(entry)
    return entries, problems


def audit_text(entry):
    """One entry as text: time, operation, who to whom, outcome, the other fields, then a send's text."""
    when = entry.get("time", "")
    when = when[:10] + " " + when[11:19] + "Z" if len(when) >= 19 else when
    who = entry.get("from")
    pane = entry.get("pane")
    route = "%s -> %s" % (who, pane) if who and pane else (who or pane or "")
    rest = ", ".join("%s %s" % (k, ",".join(v) if isinstance(v, list) else json.dumps(v) if isinstance(v, bool) else v)
                     for k, v in sorted(entry.items()) if k not in AUDIT_SHOWN)
    line = " ".join(x for x in (when, "%-12s" % entry.get("op", "?"), route, entry.get("outcome", ""),
                                "(%s)" % rest if rest else "") if x)
    text = entry.get("text")
    if isinstance(text, str):
        line += "\n" + "\n".join("    " + t for t in text.split("\n"))
    return line


def audit(argv, out, err, home=None, now=None):
    pane, since, kind, i = None, None, None, 0
    while i < len(argv):
        if argv[i] == "--pane" and i + 1 < len(argv):
            pane, i = argv[i + 1], i + 2
        elif argv[i] == "--type" and i + 1 < len(argv):
            kind, i = argv[i + 1], i + 2
        elif argv[i] == "--since" and i + 1 < len(argv):
            try:
                since = audit_since(argv[i + 1], now)
            except ValueError as e:
                err.write("dojo: %s\n" % e)
                return 2
            i += 2
        else:
            err.write("usage: dojo audit [--pane NAME] [--since 30m|2h|3d|DATE] [--type assign|report|merged|bug]\n")
            return 2
    folder = audit_folder(home)
    entries, problems = audit_entries(folder)
    if not entries and not problems:
        err.write("dojo: no bus record in %s yet\n" % folder)
        return 0
    for entry in entries:
        if kind and entry.get("type") != kind:
            continue
        if pane and pane not in (entry.get("from"), entry.get("pane"), entry.get("to")) \
                and pane not in (entry.get("senders") or []):
            continue
        if since is not None:
            try:
                stamp = datetime.datetime.fromisoformat(entry.get("time", "").replace("Z", "+00:00")).timestamp()
            except ValueError:
                stamp = None
            if stamp is not None and stamp < since:
                continue
        out.write(audit_text(entry) + "\n")
    for p in problems:
        err.write("dojo: %s\n" % p)
    return 1 if problems else 0


# ---------------------------------------------------------------- agy's hooks (D38)
# The Antigravity CLI (agy 1.5.9) has six hook events and sends camelCase JSON: hookEventName,
# conversationId, modelName, lastUserInput, invocationNum. Read off its bundled hooks.md and a probe on
# 2026-11-16. The bus knows Claude Code's words, so the events it uses are posted in those. agy has no
# event for a permission ask or a question: a dialog is seen on the screen only.

AGY_RULE_VARIABLE = "DOJO_PEER_RULE"


def agy_hook(event, env):
    """What to post to the bus for one of agy's hook events (None: nothing), and what to print to agy."""
    name = event.get("hookEventName")
    posted = None
    if name in ("SessionStart", "PostToolUse", "Stop"):
        posted = {"hook_event_name": name}
    elif name == "PreToolUse":
        # agy's question dialog sets no tool_confirmation_pending (a pty probe on 2026-11-16): its tool is
        # seen here, before it runs. The next model call (PreInvocation) says the answer is in.
        tool = event.get("toolCall") if isinstance(event.get("toolCall"), dict) else {}
        posted = {"hook_event_name": "PermissionRequest" if tool.get("name") == "ask_question" else "PostToolUse"}
    elif name == "PreInvocation":
        # Before every model call. The first of a turn (invocationNum 0, which protojson may leave out) is the
        # prompt the turn answers; a later one follows tool calls, and says only that work goes on.
        if not event.get("invocationNum"):
            posted = {"hook_event_name": "UserPromptSubmit"}
            if isinstance(event.get("lastUserInput"), str):
                posted["prompt"] = event["lastUserInput"]
        else:
            posted = {"hook_event_name": "PostToolUse"}
    if posted is not None:
        if isinstance(event.get("conversationId"), str):
            posted["session_id"] = event["conversationId"]
        if isinstance(event.get("modelName"), str):
            posted["model"] = event["modelName"]
    reply = {}
    if name == "PreToolUse" and posted and posted["hook_event_name"] == "PermissionRequest":
        # An answer without a decision stops the tool: the question is let through, as agy would. Never any
        # other tool: the plugin asks about the question alone, and an allow here would skip the owner's
        # permission prompt. Should another tool come, the answer stays empty, which stops it.
        reply = {"decision": "allow"}
    # The pane's peer rule, as a system step at the start of the conversation: agy takes no system prompt on
    # its command line. Only in a pane, where the launch line set the variable.
    rule = env.get(AGY_RULE_VARIABLE)
    if name == "SessionStart" and rule and env.get("DOJO_TOKEN"):
        reply = {"injectSteps": [{"systemMessage": {"systemMessage": rule}}]}
    return posted, reply


# agy has no hook for a permission ask, but its status-line command gets the session's state on every
# change, at most every 300 ms (agy docs, cli/statusline): tool_confirmation_pending while a tool
# confirmation dialog shows (left out otherwise), and agent_state. An agy pane runs this command for its
# session only (Launcher.agySettings). It reports the state in the bus's words and prints the pane's line.
AGY_RUNNING_STATES = ("working", "tool_use", "reviewing")


def agy_status_event(data):
    """The bus's word for the state a status-line payload shows; None when it says nothing about the turn
    (initializing, authenticating, error, a state a later agy brings)."""
    if data.get("tool_confirmation_pending") is True:
        return "PermissionRequest"
    state = data.get("agent_state")
    if state == "idle":
        return "Stop"
    if state in AGY_RUNNING_STATES:
        return "PostToolUse"
    return None


def _get(d, *path):
    for key in path:
        if not isinstance(d, dict) or key not in d:
            return None
        d = d[key]
    return d


def _tokens(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return None
    return "%.0fk" % (n / 1000) if n >= 1000 else str(int(n))


def _left(bucket):
    try:
        return "%.0f%%" % (max(0.0, min(1.0, float(bucket["remaining_fraction"]))) * 100)
    except (TypeError, ValueError, KeyError):
        return None


def _reset_hhmm(bucket):
    """The local time a quota bucket resets, from reset_time or else reset_in_seconds."""
    import datetime as dt
    value = bucket.get("reset_time") if isinstance(bucket, dict) else None
    if isinstance(value, str) and value.strip():
        try:
            when = dt.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
            if when.tzinfo is None:
                when = when.replace(tzinfo=dt.timezone.utc)
            return when.astimezone().strftime("%H:%M")
        except ValueError:
            pass
    try:
        secs = float(bucket.get("reset_in_seconds")) if isinstance(bucket, dict) else None
        return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=secs)).astimezone().strftime("%H:%M")
    except (TypeError, ValueError, OverflowError):
        return None


def agy_status_line(data):
    """One plain line, in the order and words of the Claude Code panes' line: usage, context, model,
    effort. Anything missing reads n/a."""
    five, week = _get(data, "quota", "gemini-5h"), _get(data, "quota", "gemini-weekly")
    five_left = _left(five) if isinstance(five, dict) else None
    week_left = _left(week) if isinstance(week, dict) else None
    reset = (_reset_hhmm(five) if isinstance(five, dict) else None) or "n/a"
    usage = "Usage: 5h %s, resets at %s · %s" % (five_left + " left" if five_left else "n/a", reset,
                                                  "week " + week_left + " left" if week_left else "week n/a")
    size, pct = _get(data, "context_window", "context_window_size"), _get(data, "context_window", "used_percentage")
    try:
        used = _tokens(float(size) * float(pct) / 100) if size and pct is not None else None
    except (TypeError, ValueError):
        used = None
    ctx = "Ctx: %s / %s" % (used, _tokens(size)) if used is not None and _tokens(size) else "Ctx: n/a"
    name = _get(data, "model", "display_name")
    effort = _get(data, "model", "effort")
    effort = effort.strip().upper() if isinstance(effort, str) and effort.strip() else "n/a"
    return " | ".join([usage, ctx, "Model: %s" % (name if isinstance(name, str) and name else "n/a"), "Thinking: " + effort])


def agy_status_record(token):
    """Where a pane's status line keeps what it last told the bus: one file per pane, by its token."""
    import tempfile
    return os.path.join(tempfile.gettempdir(), "dojo-agy-status-" + hashlib.sha256(token.encode()).hexdigest()[:16])


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def agy_statusline_cli(stdin, out):
    """`dojo statusline agy`: agy shows what this prints, so it prints the line whatever happens. Outside a
    pane it only prints."""
    data = {}
    try:
        parsed = json.loads(stdin.read(1 << 20) or "{}")
        data = parsed if isinstance(parsed, dict) else {}
    except Exception:
        pass
    try:
        event = agy_status_event(data)
        token = os.environ.get("DOJO_TOKEN")
        if event and token:
            # agy runs this about every 300 ms, idle or not (a pty probe): the bus hears only a change. It
            # also keeps a question at prompt, which the status line cannot see, until the next model call.
            seen = agy_status_record(token)
            if read_text(seen) != event:
                bus_call("hook", {"hook_event_name": event}, timeout=1)
                with open(seen, "w") as f:
                    f.write(event)
    except Exception:
        pass
    out.write(agy_status_line(data) + "\n")
    out.flush()
    return 0


def agy_hook_cli(stdin, out):
    """`dojo hook agy`: agy waits for every hook and reads one JSON object from it, so it gets one whatever
    happens here. Outside a pane, nothing is posted and nothing is injected."""
    reply = {}
    try:
        event = json.loads(stdin.read(1 << 20) or "{}")
        if isinstance(event, dict):
            posted, reply = agy_hook(event, os.environ)
            if posted is not None and os.environ.get("DOJO_TOKEN"):
                bus_call("hook", posted, timeout=1)
    except Exception:
        pass
    out.write(json.dumps(reply) + "\n")
    out.flush()
    return 0


# ---------------------------------------------------------------- CLI

USAGE = """usage: dojo panes | send <pane> <text...> | send <pane> - (text on stdin) | read <pane> [lines] | state <pane> | watch <pane> | label [text...] | relay <words...> | hook | install | audit [--pane P] [--since WHEN]"""


def cli(argv, out=sys.stdout, err=sys.stderr, stdin=sys.stdin):
    if not argv:
        err.write(USAGE + "\n")
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "hook" and rest == ["agy"]:
        return agy_hook_cli(stdin, out)
    if cmd == "statusline" and rest == ["agy"]:
        return agy_statusline_cli(stdin, out)
    if cmd == "hook":
        try:
            event = json.loads(stdin.read(1 << 20) or "{}")
            bus_call("hook", event, timeout=1)  # the loopback bus answers in milliseconds; Codex allows 3 s
        except Exception:
            pass
        return 0
    if cmd == "install":
        return install(out=out)
    if cmd == "audit":
        return audit(rest, out, err)
    try:
        if cmd == "panes" and not rest:
            res = bus_call("panes", {})
            for p in res.get("panes", []):
                mark = "*" if p.get("name") == res.get("you") else " "
                # D21.2: once the owner marks a coordinator, the agents say which they are
                role = " (%s)" % p["role"] if p.get("role") else ""
                # D15: what the pane says it is working on, last so the columns before it stay put
                label = " label=%s" % p["label"] if p.get("label") else ""
                out.write("%s %-12s %-6s %-14s %-8s queued=%s %s%s%s\n" % (
                    mark, p.get("name"), p.get("kind"), p.get("host") or "local",
                    p.get("state"), p.get("queued", 0), p.get("model") or "", role, label))
            return 0
        if cmd == "label":
            res = bus_call("label", {"text": " ".join(rest)})
            out.write("%s: %s\n" % (res.get("pane"), "label " + res["label"] if res.get("label") else "no label"))
            return 0
        if cmd == "send" and rest[1:2] == ["--type"] and len(rest) < 3:
            err.write("usage: dojo send <pane> --type assign|report|merged|bug key=value...\n")
            return 2
        if cmd == "send" and len(rest) >= 3 and rest[1] == "--type":
            # D21.5: dojo send <pane> --type report repo=... pr=... (each value one word, or quoted by the shell)
            fields = {}
            for word in rest[3:]:
                if "=" not in word:
                    err.write("dojo: a typed message takes key=value words, not %r\n" % word)
                    return 2
                key, value = word.split("=", 1)
                fields[key] = value
            res = bus_call("send", {"pane": rest[0], "type": rest[2], "fields": fields})
        elif cmd == "send" and len(rest) >= 2:
            text = stdin.read() if rest[1:] == ["-"] else " ".join(rest[1:])
            # Outside a pane: the owner's outside route, if switched on (D15 b), free text only;
            # a typed message above always needs a pane's token.
            if os.environ.get("DOJO_TOKEN"):
                res = bus_call("send", {"pane": rest[0], "text": text})
            else:
                res = outside_send(rest[0], text)
        if cmd == "send" and len(rest) >= 2:
            out.write("%s: %s (state %s, queued %s)\n" % (
                rest[0], "delivered" if res.get("delivered") else "queued",
                res.get("state"), res.get("queued", 0)))
            # Why it waits, or what happens to it now: a bare "queued" left senders guessing (D18).
            if res.get("note"):
                out.write("  %s\n" % res["note"])
            return 0
        if cmd == "read" and 1 <= len(rest) <= 2:
            lines = int(rest[1]) if len(rest) == 2 else 40
            res = bus_call("read", {"pane": rest[0], "lines": lines})
            out.write(res.get("text", "") + "\n")
            if res.get("redacted"):
                err.write("dojo: %s\n" % redaction_note(res["redacted"]))
            return 0
        if cmd == "relay" and rest:
            res = bus_call("relay", {"args": rest}, timeout=30)  # the bus allows the program 20 s
            out.write(res.get("stdout", ""))
            err.write(res.get("stderr", ""))
            if res.get("timedOut"):
                err.write("dojo: the relayed command ran out of time and was stopped\n")
            if res.get("truncated"):
                err.write("dojo: the relayed command's output was cut short\n")
            return res.get("code", 1)
        if cmd == "state" and len(rest) == 1:
            res = bus_call("state", {"pane": rest[0]})
            out.write("%s %s queued=%s\n" % (rest[0], res.get("state"), res.get("queued", 0)))
            return 0
        if cmd == "watch" and len(rest) == 1:
            res = bus_call("watch", {"pane": rest[0]})
            out.write("%s is %s now; a line comes here when it next stops\n" % (rest[0], res.get("state")))
            return 0
    except (BusError, ValueError) as e:
        err.write("dojo: %s\n" % e)
        return 1
    err.write(USAGE + "\n")
    return 2


def main():
    # Windows reads and writes pipes as cp1252 unless told otherwise; the bus speaks UTF-8.
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    invoked_as = os.path.basename(sys.argv[0])
    if len(sys.argv) > 1 or invoked_as == "dojo":
        sys.exit(cli(sys.argv[1:]))
    serve()


if __name__ == "__main__":
    main()
