"""Tests for tools/dojo-mcp.py: MCP stdio protocol over pipes, CLI mode, hook and install.

Run: python3 -m unittest discover -s tools -p 'test_*.py'
"""
import datetime
import hashlib
import http.server
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import tomllib
import unittest

SHIM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dojo-mcp.py")


class FakeBus:
    """Records requests; answers like the app's bus."""

    def __init__(self):
        self.requests = []
        self.relay_on = False
        bus = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                bus.requests.append((self.path, self.headers.get("X-Dojo-Token"), body))
                if self.headers.get("X-Dojo-Token") != "tok-1":
                    out, code = {"error": "unknown token"}, 401
                elif self.path == "/panes":
                    out, code = {"you": "claude-1", "panes": [
                        {"name": "claude-1", "kind": "claude", "host": "", "state": "idle", "queued": 0, "model": "",
                         "role": "coordinator"},
                        {"name": "codex-1", "kind": "codex", "host": "box", "state": "prompt", "queued": 1, "model": "",
                         "role": "worker"}]}, 200
                elif self.path == "/send":
                    out, code = {"pane": body["pane"], "delivered": False, "queued": 1, "state": "prompt",
                                 "note": "codex-1 is at a prompt; queued until it is idle."}, 200
                elif self.path == "/read":
                    out, code = {"pane": body["pane"], "state": "idle", "text": "line a\nline b"}, 200
                    if body["pane"] == "secretive":
                        out["text"], out["redacted"] = "key [redacted: github token]\n[dojo token]", 2
                elif self.path == "/state":
                    out, code = {"pane": body["pane"], "state": "idle", "queued": 0}, 200
                elif self.path == "/watch":
                    out, code = {"pane": body["pane"], "state": "running"}, 200
                elif self.path == "/relay" and bus.relay_on:
                    out, code = {"code": 3, "stdout": "said " + " ".join(body["args"]) + "\n", "stderr": "warned\n",
                                 "timedOut": False, "truncated": False}, 200
                elif self.path == "/hook":
                    out, code = None, 200
                else:
                    out, code = {"error": "no such operation"}, 404
                data = b"" if out is None else json.dumps(out).encode()
                self.send_response(code)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def load_shim():
    import importlib.util
    spec = importlib.util.spec_from_file_location("dojo_mcp", SHIM)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ShimTest(unittest.TestCase):
    def setUp(self):
        self.bus = FakeBus()
        self.env = dict(os.environ, DOJO_TOKEN="tok-1", DOJO_PORT=str(self.bus.port))

    def tearDown(self):
        self.bus.close()

    def cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        saved = dict(os.environ)
        os.environ.update(self.env)
        try:
            return load_shim().cli(list(argv), out=out, err=err), out.getvalue(), err.getvalue()
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_a_typed_send_carries_its_type_and_fields(self):
        # D21.5: dojo send <pane> --type T key=value..., a value with spaces in quotes as the shell gives it
        code, out, _ = self.cli("send", "codex-1", "--type", "report", "repo=xyntetik-dojo", "pr=92", "head=e07bd8a",
                                "checks=ci=pass,hygiene=pass", "mergeable=yes", "note=two words")
        self.assertEqual(code, 0)
        path, _, body = self.bus.requests[-1]
        self.assertEqual(path, "/send")
        self.assertEqual(body, {"pane": "codex-1", "type": "report", "fields": {
            "repo": "xyntetik-dojo", "pr": "92", "head": "e07bd8a", "checks": "ci=pass,hygiene=pass",
            "mergeable": "yes", "note": "two words"}})
        self.assertTrue(out.startswith("codex-1: queued"))

    def test_a_typed_send_needs_key_value_words(self):
        code, _, err = self.cli("send", "codex-1", "--type", "bug", "just words")
        self.assertEqual(code, 2)
        self.assertIn("key=value", err)
        code, _, err = self.cli("send", "codex-1", "--type")
        self.assertEqual(code, 2)
        self.assertIn("usage: dojo send <pane> --type", err)
        self.assertFalse(any(r[0] == "/send" for r in self.bus.requests))

    def test_the_send_tool_takes_a_type_and_fields(self):
        m = load_shim()
        self.assertEqual(m.tool_payload("send", {"pane": "p", "type": "merged", "fields": {"repo": "r", "pr": 92, "sha": "abcdef1"}}),
                         {"pane": "p", "type": "merged", "fields": {"repo": "r", "pr": "92", "sha": "abcdef1"}})
        self.assertEqual(m.tool_payload("send", {"pane": "p", "text": "hi"}), {"pane": "p", "text": "hi"})
        with self.assertRaises(ValueError):
            m.tool_payload("send", {"pane": "p", "type": "bug", "fields": "not an object"})
        send = next(t for t in m.TOOLS if t["name"] == "send")
        self.assertEqual(send["inputSchema"]["properties"]["type"]["enum"], ["assign", "report", "merged", "bug"])
        self.assertEqual(send["inputSchema"]["required"], ["pane"])

    def test_send_says_why_a_message_waits(self):
        code, out, _ = self.cli("send", "codex-1", "hello")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["codex-1: queued (state prompt, queued 1)",
                                            "  codex-1 is at a prompt; queued until it is idle."])

    def test_relay_sends_the_words_and_gives_back_what_the_program_said(self):
        self.bus.relay_on = True
        code, out, err = self.cli("relay", "claim", "a b", "--flag")
        self.assertEqual((code, out, err), (3, "said claim a b --flag\n", "warned\n"))
        self.assertEqual(self.bus.requests[-1][2], {"args": ["claim", "a b", "--flag"]})

    def test_relay_with_no_config_is_refused_like_any_unknown_operation(self):
        code, out, err = self.cli("relay", "claim")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("bus refused (404)", err)

    def test_read_says_when_the_bus_took_secrets_out(self):
        code, out, err = self.cli("read", "secretive")
        self.assertEqual((code, out), (0, "key [redacted: github token]\n[dojo token]\n"))
        self.assertIn("The bus took 2 secrets out of this text", err)
        code, out, err = self.cli("read", "codex-1")
        self.assertEqual((code, err), (0, ""))
        res = self.mcp([{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                         "params": {"name": "read", "arguments": {"pane": "secretive"}}}])
        content = res[0]["result"]["content"]
        self.assertEqual(content[0]["text"], "key [redacted: github token]\n[dojo token]")
        self.assertIn("took 2 secrets out", content[1]["text"])

    def test_relay_needs_words(self):
        code, _, err = self.cli("relay")
        self.assertEqual(code, 2)
        self.assertIn("usage:", err)

    def mcp(self, messages, env=None):
        proc = subprocess.Popen([sys.executable, SHIM], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                env=env or self.env, text=True)
        out, _ = proc.communicate("".join(m if isinstance(m, str) else json.dumps(m) + "\n" for m in messages),
                                  timeout=20)
        self.assertEqual(proc.returncode, 0)
        return [json.loads(line) for line in out.splitlines()]

    def test_initialize_list_and_call(self):
        replies = self.mcp([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "send", "arguments": {"pane": "codex-1", "text": "hello"}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "read", "arguments": {"pane": "codex-1", "lines": 5}}},
            {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "nope", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 6, "method": "resources/list"},
            "this is not json\n",
            {"jsonrpc": "2.0", "id": 7, "method": "ping"},
        ])
        by_id = {r.get("id"): r for r in replies}
        self.assertEqual(len(replies), 8)  # the notification gets no reply
        init = by_id[1]["result"]
        self.assertEqual(init["protocolVersion"], "2025-06-18")
        self.assertIn("tools", init["capabilities"])
        self.assertEqual(init["serverInfo"]["name"], "dojo")
        names = [t["name"] for t in by_id[2]["result"]["tools"]]
        self.assertEqual(names, ["panes", "send", "read", "state", "watch"])
        for t in by_id[2]["result"]["tools"]:
            self.assertEqual(t["inputSchema"]["type"], "object")
        sent = by_id[3]["result"]
        self.assertFalse(sent["isError"])
        self.assertEqual(json.loads(sent["content"][0]["text"])["state"], "prompt")
        self.assertEqual(by_id[4]["result"]["content"][0]["text"], "line a\nline b")
        self.assertEqual(by_id[5]["error"]["code"], -32602)
        self.assertEqual(by_id[6]["error"]["code"], -32601)
        self.assertEqual(by_id[None]["error"]["code"], -32700)
        self.assertEqual(by_id[7]["result"], {})
        self.assertEqual(self.bus.requests[0], ("/send", "tok-1", {"pane": "codex-1", "text": "hello"}))
        self.assertEqual(self.bus.requests[1], ("/read", "tok-1", {"pane": "codex-1", "lines": 5}))

    def test_unknown_protocol_version_gets_latest(self):
        reply = self.mcp([{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}}])
        self.assertEqual(reply[0]["result"]["protocolVersion"], "2025-11-25")

    def test_without_token_no_tools_and_calls_fail(self):
        env = dict(self.env)
        env.pop("DOJO_TOKEN")
        replies = self.mcp([
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "panes", "arguments": {}}},
        ], env=env)
        self.assertEqual(replies[0]["result"]["tools"], [])
        self.assertTrue(replies[1]["result"]["isError"])
        self.assertIn("DOJO_TOKEN", replies[1]["result"]["content"][0]["text"])
        self.assertEqual(self.bus.requests, [])

    def test_bus_refusal_is_a_tool_error(self):
        env = dict(self.env, DOJO_TOKEN="wrong")
        replies = self.mcp([{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "panes", "arguments": {}}}], env=env)
        self.assertTrue(replies[0]["result"]["isError"])
        self.assertIn("401", replies[0]["result"]["content"][0]["text"])
        # A refusal names the tool and the arguments the call carried.
        replies = self.mcp([{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "state", "arguments": {"name": "codex-1"}}}], env=env)
        self.assertIn('tool state called with {"name": "codex-1"}', replies[0]["result"]["content"][0]["text"])

    def run_cli(self, *args, stdin="", env=None):
        return subprocess.run([sys.executable, SHIM, *args], input=stdin, capture_output=True, text=True,
                              env=env or self.env, timeout=20)

    def test_cli(self):
        r = self.run_cli("send", "codex-1", "hello", "there")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "codex-1: queued (state prompt, queued 1)\n"
                                   "  codex-1 is at a prompt; queued until it is idle.\n")
        self.assertEqual(self.bus.requests[-1][2], {"pane": "codex-1", "text": "hello there"})
        r = self.run_cli("send", "codex-1", "-", stdin="from stdin\n")
        self.assertEqual(self.bus.requests[-1][2]["text"], "from stdin\n")
        r = self.run_cli("panes")
        self.assertIn("* claude-1", r.stdout)
        self.assertIn("(coordinator)", r.stdout.splitlines()[0])
        self.assertIn("(worker)", r.stdout.splitlines()[1])
        self.assertIn("codex-1", r.stdout)
        self.assertIn("box", r.stdout)
        r = self.run_cli("read", "codex-1", "2")
        self.assertEqual(r.stdout, "line a\nline b\n")
        r = self.run_cli("state", "codex-1")
        self.assertEqual(r.stdout, "codex-1 idle queued=0\n")
        r = self.run_cli("watch", "codex-1")
        self.assertEqual(r.stdout, "codex-1 is running now; a line comes here when it next stops\n")
        self.assertEqual(self.bus.requests[-1][:1] + (self.bus.requests[-1][2],), ("/watch", {"pane": "codex-1"}))
        r = self.run_cli("bogus")
        self.assertEqual(r.returncode, 2)

    def test_cli_invoked_as_dojo_without_args_prints_usage(self):
        tmp = tempfile.mkdtemp()
        try:
            link = os.path.join(tmp, "dojo")
            os.symlink(SHIM, link)
            r = subprocess.run([sys.executable, link], capture_output=True, text=True, env=self.env, timeout=20)
            self.assertEqual(r.returncode, 2)
            self.assertIn("usage: dojo", r.stderr)
        finally:
            shutil.rmtree(tmp)

    def test_hook_forwards_and_never_fails(self):
        event = {"hook_event_name": "Stop", "session_id": "s"}
        r = self.run_cli("hook", stdin=json.dumps(event))
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        self.assertEqual(self.bus.requests[-1], ("/hook", "tok-1", event))
        env = dict(self.env, DOJO_PORT="1")  # nothing listens there
        r = self.run_cli("hook", stdin="not json", env=env)
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def test_install(self):
        home = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(home, ".dojo"))
            os.makedirs(os.path.join(home, ".codex"))
            shutil.copy(SHIM, os.path.join(home, ".dojo", "dojo-mcp.py"))
            config = os.path.join(home, ".codex", "config.toml")
            with open(config, "w") as f:
                f.write('model = "x"\n[hooks.state]')
            env = dict(self.env, HOME=home)
            for _ in range(2):
                r = self.run_cli("install", env=env)
                self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(os.readlink(os.path.join(home, ".dojo", "bin", "dojo")), "../dojo-mcp.py")
            with open(config) as f:
                text = f.read()
            self.assertEqual(text.count("[mcp_servers.dojo]"), 1)
            parsed = tomllib.loads(text)
            self.assertEqual(parsed["model"], "x")
            self.assertEqual(parsed["mcp_servers"]["dojo"]["env_vars"], ["DOJO_TOKEN", "DOJO_PORT", "DOJO_PANE"])
            for event in ("SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "Interrupt"):
                self.assertIn("hook", parsed["hooks"][event][0]["hooks"][0]["command"])
            r = subprocess.run([os.path.join(home, ".dojo", "bin", "dojo")], capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 2)
        finally:
            shutil.rmtree(home)

    def test_install_on_windows_writes_sh_wrappers(self):
        mod = load_shim()
        home = tempfile.mkdtemp()
        try:
            os.makedirs(os.path.join(home, ".dojo"))
            shutil.copy(SHIM, os.path.join(home, ".dojo", "dojo-mcp.py"))
            out = io.StringIO()
            for _ in range(2):
                self.assertEqual(mod.install(home=home, out=out, windows=True), 0)
            bin_dir = os.path.join(home, ".dojo", "bin")
            for name in ("dojo", "python3"):
                path = os.path.join(bin_dir, name)
                self.assertFalse(os.path.islink(path))
                with open(path) as f:
                    text = f.read()
                self.assertTrue(text.startswith("#!/bin/sh\n"), text)
                self.assertIn(sys.executable.replace("\\", "/"), text)
                self.assertNotIn("\r", text)
            env = dict(self.env, HOME=home, PATH=bin_dir + os.pathsep + os.environ.get("PATH", ""))
            r = subprocess.run(["sh", os.path.join(bin_dir, "python3"), "-c", "import sys; print(sys.version_info[0])"],
                               capture_output=True, text=True, env=env)
            self.assertEqual((r.returncode, r.stdout.strip()), (0, "3"), r.stderr)
            r = subprocess.run(["sh", os.path.join(bin_dir, "dojo")], capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertIn("usage:", r.stderr)
            r = subprocess.run(["sh", os.path.join(bin_dir, "dojo"), "panes"], capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("* claude-1", r.stdout)
        finally:
            shutil.rmtree(home)

    def test_install_follows_the_shells_home(self):
        """A Windows host whose bash HOME is not the Windows profile: install finds itself under HOME,
        where remote-setup put it, not where a native Python's expanduser points."""
        mod = load_shim()
        home, profile = tempfile.mkdtemp(), tempfile.mkdtemp()
        saved = {k: os.environ.get(k) for k in ("HOME", "USERPROFILE")}
        try:
            os.makedirs(os.path.join(home, ".dojo"))
            shutil.copy(SHIM, os.path.join(home, ".dojo", "dojo-mcp.py"))
            os.environ["HOME"], os.environ["USERPROFILE"] = home, profile
            out = io.StringIO()
            self.assertEqual(mod.install(out=out, windows=True), 0, out.getvalue())
            self.assertTrue(os.path.exists(os.path.join(home, ".dojo", "bin", "dojo")))
            self.assertFalse(os.path.exists(os.path.join(profile, ".dojo")))
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
            shutil.rmtree(home)
            shutil.rmtree(profile)

    def test_codex_snippet_matches_install_block(self):
        mod = load_shim()
        with open(os.path.join(os.path.dirname(SHIM), "snippets", "codex-config.toml")) as f:
            self.assertEqual(f.read(), mod.codex_block().lstrip("\n"))



class ServerRobustness(unittest.TestCase):
    def test_bad_arguments_get_errors_and_the_server_lives_on(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("dojo_mcp_srv", SHIM)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        lines = [
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "read", "arguments": {"pane": "x", "lines": [5]}}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "send", "arguments": "{\"pane\": \"x\"}"}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": ["send"]}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "read", "arguments": {"pane": "x", "lines": 1e400}}},
            {"jsonrpc": "2.0", "id": 5, "method": "ping"},
        ]
        out = io.StringIO()
        mod.serve(stdin=io.StringIO("".join(json.dumps(l) + "\n" for l in lines)), stdout=out)
        replies = [json.loads(l) for l in out.getvalue().splitlines()]
        self.assertEqual([r["id"] for r in replies], [1, 2, 3, 4, 5])
        for r in replies[:4]:
            self.assertIn("error", r, r)
            self.assertIn(r["error"]["code"], (-32602, -32603), r)
        self.assertEqual(replies[4].get("result"), {})


class OldNameMigration(unittest.TestCase):
    OLD = """[projects."/x"]
trust_level = "trusted"

# Xyntetik Harness Supervisor: bus tools and state hooks (added by "xhs install")
[mcp_servers.xhs]
command = "sh"
args = ["-c", "exec python3 \\"$HOME/.xhs/xhs-mcp.py\\""]
env_vars = ["XHS_TOKEN", "XHS_PORT", "XHS_PANE"]

[[hooks.SessionStart]]
[[hooks.SessionStart.hooks]]
type = "command"
command = "python3 \\"$HOME/.xhs/xhs-mcp.py\\" hook"
timeout = 5

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "python3 \\"$HOME/.xhs/xhs-mcp.py\\" hook"
timeout = 5

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = "say done"
timeout = 5

[features]
x = true
"""

    def test_install_replaces_the_old_block_and_keeps_the_rest(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("dojo_mcp", SHIM)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".dojo"))
            shutil.copy(SHIM, os.path.join(home, ".dojo", "dojo-mcp.py"))
            os.makedirs(os.path.join(home, ".codex"))
            config = os.path.join(home, ".codex", "config.toml")
            with open(config, "w") as f:
                f.write(self.OLD)
            out = io.StringIO()
            self.assertEqual(mod.install(home=home, out=out, windows=False), 0)
            text = open(config).read()
            self.assertNotIn("xhs", text)
            self.assertNotIn("Harness Supervisor", text)
            self.assertIn('[projects."/x"]', text)
            self.assertIn("say done", text)
            parsed = tomllib.loads(text)
            self.assertEqual(list(parsed["mcp_servers"]), ["dojo"])
            self.assertEqual(parsed["features"], {"x": True})
            self.assertEqual(len(parsed["hooks"]["Stop"]), 2)
            self.assertEqual(len(parsed["hooks"]["Interrupt"]), 1)
            self.assertEqual(open(config + ".before-dojo").read(), self.OLD)
            self.assertIn("removed the old xhs block", out.getvalue())
            # A second install leaves the file alone.
            out = io.StringIO()
            mod.install(home=home, out=out, windows=False)
            self.assertEqual(open(config).read(), text)

    MIXED = (
        "# my fast profile\r\n"
        "[profiles.fast]\r\n"
        "model = \"x\"\r\n"
        "\r\n"
        "# Xyntetik Harness Supervisor: bus tools and state hooks (added by \"xhs install\")\r\n"
        "[mcp_servers.xhs]\r\n"
        "command = \"sh\"\r\n"
        "args = [\"-c\", \"exec python3 \\\"$HOME/.xhs/xhs-mcp.py\\\"\"]\r\n"
        "\r\n"
        "[mcp_servers.xhs.env]\r\n"
        "X = \"1\"\r\n"
        "\r\n"
        "[[hooks.Stop]]\r\n"
        "[[hooks.Stop.hooks]]\r\n"
        "type = \"command\"\r\n"
        "command = \"python3 \\\"$HOME/.xhs/xhs-mcp.py\\\" hook\"\r\n"
        "timeout = 5\r\n"
        "[[hooks.Stop.hooks]]\r\n"
        "type = \"command\"\r\n"
        "command = \"say done\"\r\n"
        "timeout = 5\r\n"
        "\r\n"
        "# the owner's own table\r\n"
        "  [features]\r\n"
        "  x = true\r\n"
    )

    def test_table_lines_inside_strings_and_inline_comments_on_the_header(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("dojo_mcp4", SHIM)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        tricky = (
            '[notes]\n'
            'example = """\n'
            'an example that mentions\n'
            '[mcp_servers.xhs]\n'
            'in a string\n'
            '"""\n'
            "\n"
            '# Xyntetik Harness Supervisor: bus tools and state hooks (added by "xhs install")\n'
            '[mcp_servers.xhs]  # the old one\n'
            'command = "sh"\n'
            'args = ["-c", "exec python3 \\"$HOME/.xhs/xhs-mcp.py\\""]\n'
            "\n"
            "[[hooks.Stop]]\n"
            "[[hooks.Stop.hooks]]\n"
            'type = "command"\n'
            'command = "python3 \\"$HOME/.xhs/xhs-mcp.py\\" hook"\n'
            "timeout = 5\n"
        )
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".dojo"))
            shutil.copy(SHIM, os.path.join(home, ".dojo", "dojo-mcp.py"))
            os.makedirs(os.path.join(home, ".codex"))
            config = os.path.join(home, ".codex", "config.toml")
            with open(config, "w") as f:
                f.write(tricky)
            self.assertEqual(mod.install(home=home, out=io.StringIO(), windows=False), 0)
            text = open(config).read()
            parsed = tomllib.loads(text)
            self.assertIn("[mcp_servers.xhs]\nin a string", parsed["notes"]["example"], "the string is untouched")
            self.assertEqual(list(parsed["mcp_servers"]), ["dojo"], "the real old table, inline comment and all, is gone")
            self.assertNotIn("xhs-mcp.py", text)

    def test_a_top_level_multiline_string_that_names_the_old_table_survives(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("dojo_mcp5", SHIM)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        top = (
            'developer_instructions = """\n'
            'When asked about the bus, mention that the old table was\n'
            '[mcp_servers.xhs]\n'
            'and is gone now.\n'
            '"""\n'
            "\n" + self.OLD[self.OLD.index("# Xyntetik"):]
        )
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".dojo"))
            shutil.copy(SHIM, os.path.join(home, ".dojo", "dojo-mcp.py"))
            os.makedirs(os.path.join(home, ".codex"))
            config = os.path.join(home, ".codex", "config.toml")
            with open(config, "w") as f:
                f.write(top)
            self.assertEqual(mod.install(home=home, out=io.StringIO(), windows=False), 0)
            parsed = tomllib.loads(open(config).read())
            self.assertIn("[mcp_servers.xhs]\nand is gone now.", parsed["developer_instructions"])
            self.assertEqual(list(parsed["mcp_servers"]), ["dojo"])

    def test_an_escaped_triple_quote_does_not_end_the_string(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("dojo_mcp6", SHIM)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        top = (
            'developer_instructions = """\n'
            'Quote blocks look like \\""" in this file.\n'
            'An example table:\n'
            '[notes.example]\n'
            'x = 1\n'
            '"""\n'
            "\n" + self.OLD[self.OLD.index("# Xyntetik"):]
        )
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".dojo"))
            shutil.copy(SHIM, os.path.join(home, ".dojo", "dojo-mcp.py"))
            os.makedirs(os.path.join(home, ".codex"))
            config = os.path.join(home, ".codex", "config.toml")
            with open(config, "w") as f:
                f.write(top)
            self.assertEqual(mod.install(home=home, out=io.StringIO(), windows=False), 0)
            parsed = tomllib.loads(open(config).read())
            self.assertIn("[notes.example]\nx = 1", parsed["developer_instructions"])
            self.assertNotIn("notes", parsed)
            self.assertEqual(list(parsed["mcp_servers"]), ["dojo"])

    def test_migration_ignores_quote_sequences_in_comments_and_other_strings(self):
        mod = load_shim()
        samples = [
            'model = "x" # a triple quote """\n',
            "note = 'a triple quote \"\"\" is literal'\n",
            'note = "three apostrophes \'\'\' are ordinary text"\n',
            'note = """A literal \'\'\' inside a basic string.\nStill text.\n"""\n',
            'note = """\n# Xyntetik Harness Supervisor is part of this value.\n"""\n',
            'matrix = [\n [1, 2], # """\n [3, 4]\n]\n',
        ]
        for sample in samples:
            with self.subTest(sample=sample):
                original = sample + self.OLD
                expected = tomllib.loads(original)
                migrated = tomllib.loads(mod.without_old_block(original) + mod.codex_block())
                for key, value in tomllib.loads(sample).items():
                    self.assertEqual(migrated.get(key), value)
                self.assertEqual(list(migrated["mcp_servers"]), ["dojo"])
                self.assertEqual(migrated["projects"], expected["projects"])

    def test_install_uses_real_tables_and_preserves_the_original_backup(self):
        mod = load_shim()
        for spelling in ("[mcp_servers.xhs]", '[mcp_servers."xhs"]'):
            with self.subTest(spelling=spelling), tempfile.TemporaryDirectory() as home:
                root = os.path.join(home, ".dojo")
                os.makedirs(root)
                shutil.copy(SHIM, os.path.join(root, "dojo-mcp.py"))
                os.makedirs(os.path.join(home, ".codex"))
                config = os.path.join(home, ".codex", "config.toml")
                original = ('developer_instructions = """\n'
                            '[mcp_servers.xhs] and [mcp_servers.dojo] are examples.\n'
                            '"""\n' + self.OLD.replace("[mcp_servers.xhs]", spelling))
                with open(config, "w") as f:
                    f.write(original)
                for _ in range(2):
                    self.assertEqual(mod.install(home=home, out=io.StringIO(), windows=False), 0)
                    with open(config) as f:
                        parsed = tomllib.loads(f.read())
                    self.assertEqual(list(parsed["mcp_servers"]), ["dojo"])
                    with open(config + ".before-dojo") as f:
                        self.assertEqual(f.read(), original)

    def test_unicode_escaped_table_keys_do_not_consume_neighboring_tables(self):
        mod = load_shim()
        original = ('[mcp_servers.xhs]\ncommand = "sh"\n'
                    '[features."\\U00000078"]\nenabled = true\n'
                    '[projects."a]b"]\ntrust_level = "trusted"\n')
        migrated = tomllib.loads(mod.without_old_block(original) + mod.codex_block())
        self.assertEqual(migrated["features"], tomllib.loads(original)["features"])
        self.assertEqual(migrated["projects"], tomllib.loads(original)["projects"])
        escaped_old = '[mcp_servers."\\U00000078hs"]\ncommand = "sh"\n'
        self.assertNotIn("xhs", tomllib.loads(mod.without_old_block(escaped_old) + mod.codex_block())["mcp_servers"])

    def test_top_level_settings_before_the_old_block_survive(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("dojo_mcp3", SHIM)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        top = 'model = "gpt-x"\napproval_policy = "never"\n\n' + self.OLD[self.OLD.index("# Xyntetik"):]
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".dojo"))
            shutil.copy(SHIM, os.path.join(home, ".dojo", "dojo-mcp.py"))
            os.makedirs(os.path.join(home, ".codex"))
            config = os.path.join(home, ".codex", "config.toml")
            with open(config, "w") as f:
                f.write(top)
            self.assertEqual(mod.install(home=home, out=io.StringIO(), windows=False), 0)
            parsed = tomllib.loads(open(config).read())
            self.assertEqual(parsed["model"], "gpt-x")
            self.assertEqual(parsed["approval_policy"], "never")
            self.assertEqual(list(parsed["mcp_servers"]), ["dojo"])

    def test_a_mixed_hook_group_subtables_comments_and_line_endings_survive(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("dojo_mcp2", SHIM)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".dojo"))
            shutil.copy(SHIM, os.path.join(home, ".dojo", "dojo-mcp.py"))
            os.makedirs(os.path.join(home, ".codex"))
            config = os.path.join(home, ".codex", "config.toml")
            with open(config, "w", newline="") as f:
                f.write(self.MIXED)
            self.assertEqual(mod.install(home=home, out=io.StringIO(), windows=False), 0)
            with open(config, newline="") as f:
                text = f.read()
            parsed = tomllib.loads(text)
            self.assertEqual(list(parsed["mcp_servers"]), ["dojo"])
            self.assertNotIn("xhs", text)
            self.assertEqual([h["hooks"][0]["command"] for h in parsed["hooks"]["Stop"] if "say done" in h["hooks"][0]["command"]], ["say done"])
            self.assertEqual(len(parsed["hooks"]["Stop"]), 2, "the owner's Stop hook and ours")
            self.assertIn("# my fast profile\r\n[profiles.fast]", text)
            self.assertIn("# the owner's own table\r\n  [features]", text)
            self.assertEqual(parsed["features"], {"x": True}, "an indented table after the old block survives")
            self.assertIn("\r\n", text, "line endings kept")
            with open(config + ".before-dojo", "rb") as f:
                self.assertEqual(f.read(), self.MIXED.encode())



class AuditTest(unittest.TestCase):
    """dojo audit reads ~/.dojo/audit as the app writes it: JSON lines, each with the hash of the one before."""

    def setUp(self):
        self.m = load_shim()
        self.home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.home)
        self.folder = os.path.join(self.home, ".dojo", "audit")
        os.makedirs(self.folder)

    def write(self, day, entries, prev="0" * 64):
        """Writes the entries as the app would, chained from `prev`; returns the last line's hash."""
        with open(os.path.join(self.folder, day + ".jsonl"), "wb") as fh:
            for e in entries:
                line = json.dumps(dict(e, prev=prev), sort_keys=True, separators=(",", ":")).encode()
                fh.write(line + b"\n")
                prev = hashlib.sha256(line).hexdigest()
        return prev

    def run_audit(self, *argv, now=None):
        out, err = io.StringIO(), io.StringIO()
        code = self.m.audit(list(argv), out, err, home=self.home, now=now)
        return code, out.getvalue(), err.getvalue()

    def test_prints_every_line_with_a_sends_text_and_checks_the_chain(self):
        last = self.write("2026-11-09", [
            {"time": "2026-11-09T22:00:00.000Z", "op": "open", "pane": "claude-1", "kind": "claude", "posture": "prompts"},
        ])
        self.write("2026-11-10", [
            {"time": "2026-11-10T14:35:12.250Z", "op": "send", "from": "claude-1", "pane": "codex-1",
             "outcome": "delivered", "chars": 20, "text": "please review\nthe diff"},
            {"time": "2026-11-10T14:35:13.000Z", "op": "read", "from": "codex-1", "pane": "claude-1", "outcome": "ok",
             "lines": 40},
            {"time": "2026-11-10T14:36:00.000Z", "op": "pane-state", "pane": "codex-1", "state": "running",
             "was": "prompt", "owner_keys": True},
        ], prev=last)
        code, out, err = self.run_audit()
        self.assertEqual(code, 0, err)
        self.assertEqual(out.splitlines(), [
            "2026-11-09 22:00:00Z open         claude-1 (kind claude, posture prompts)",
            "2026-11-10 14:35:12Z send         claude-1 -> codex-1 delivered (chars 20)",
            "    please review",
            "    the diff",
            "2026-11-10 14:35:13Z read         codex-1 -> claude-1 ok (lines 40)",
            "2026-11-10 14:36:00Z pane-state   codex-1 (owner_keys true, state running, was prompt)",
        ])

    def test_by_type(self):
        # D21.5: the record keeps a typed send's type and fields beside its text; --type picks them out
        self.write("2026-11-10", [
            {"time": "2026-11-10T10:00:00.000Z", "op": "send", "from": "a", "pane": "b", "outcome": "delivered", "text": "free"},
            {"time": "2026-11-10T11:00:00.000Z", "op": "send", "from": "a", "pane": "b", "outcome": "delivered",
             "type": "report", "fields": {"repo": "r", "pr": "1"}, "text": "report r #1\n  repo: r\n  pr: 1"},
        ])
        code, out, err = self.run_audit("--type", "report")
        self.assertEqual(code, 0, err)
        self.assertEqual(out.splitlines(), [
            "2026-11-10 11:00:00Z send         a -> b delivered (type report)",
            "    report r #1",
            "      repo: r",
            "      pr: 1",
        ])

    def test_by_pane_and_by_time(self):
        self.write("2026-11-10", [
            {"time": "2026-11-10T10:00:00.000Z", "op": "send", "from": "a", "pane": "b", "outcome": "delivered", "text": "x"},
            {"time": "2026-11-10T13:00:00.000Z", "op": "deliver", "pane": "c", "senders": ["a"], "messages": 1},
            {"time": "2026-11-10T14:00:00.000Z", "op": "panes", "from": "c", "outcome": "ok"},
        ])
        _, out, _ = self.run_audit("--pane", "b")
        self.assertEqual(len(out.splitlines()), 2)  # the send and its text
        _, out, _ = self.run_audit("--pane", "a")
        self.assertIn("deliver", out)               # a sender of a delivery
        now = datetime.datetime(2026, 11, 10, 14, 30, tzinfo=datetime.timezone.utc).timestamp()
        _, out, _ = self.run_audit("--since", "2h", now=now)
        self.assertEqual([l.split()[2] for l in out.splitlines()], ["deliver", "panes"])
        _, out, _ = self.run_audit("--since", "2026-11-10T13:30")
        self.assertEqual([l.split()[2] for l in out.splitlines()], ["panes"])
        code, _, err = self.run_audit("--since", "yesterday")
        self.assertEqual(code, 2)
        self.assertIn("--since takes", err)

    def test_a_removed_or_changed_line_breaks_the_chain(self):
        self.write("2026-11-10", [
            {"time": "2026-11-10T10:00:00.000Z", "op": "panes", "from": "a", "outcome": "ok"},
            {"time": "2026-11-10T10:00:01.000Z", "op": "send", "from": "a", "pane": "b", "outcome": "delivered", "text": "x"},
            {"time": "2026-11-10T10:00:02.000Z", "op": "panes", "from": "a", "outcome": "ok"},
        ])
        path = os.path.join(self.folder, "2026-11-10.jsonl")
        with open(path, "rb") as fh:
            lines = fh.read().split(b"\n")
        with open(path, "wb") as fh:
            fh.write(b"\n".join([lines[0], lines[2], b""]))
        code, out, err = self.run_audit()
        self.assertEqual(code, 1)
        self.assertIn("2026-11-10.jsonl:2: the chain breaks here", err)
        self.assertEqual(len(out.splitlines()), 2)  # what is there is still shown
        with open(path, "wb") as fh:
            fh.write(b"\n".join([lines[0], lines[1].replace(b'"x"', b'"y"'), lines[2], b""]))
        code, _, err = self.run_audit()
        self.assertEqual(code, 1)
        self.assertIn("2026-11-10.jsonl:3: the chain breaks here", err)

    def test_no_record_yet(self):
        shutil.rmtree(self.folder)
        code, out, err = self.run_audit()
        self.assertEqual((code, out), (0, ""))
        self.assertIn("no bus record", err)

    def test_the_cli_runs_it_without_a_bus(self):
        self.write("2026-11-10", [{"time": "2026-11-10T10:00:00.000Z", "op": "panes", "from": "a", "outcome": "ok"}])
        env = dict(os.environ, HOME=self.home)
        env.pop("DOJO_TOKEN", None)
        r = subprocess.run([sys.executable, SHIM, "audit"], capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("panes", r.stdout)


if __name__ == "__main__":
    unittest.main()
