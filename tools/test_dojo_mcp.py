"""Tests for tools/dojo-mcp.py: MCP stdio protocol over pipes, CLI mode, hook and install.

Run: python3 -m unittest discover -s tools -p 'test_*.py'
"""
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
                        {"name": "claude-1", "kind": "claude", "host": "", "state": "idle", "queued": 0, "model": ""},
                        {"name": "codex-1", "kind": "codex", "host": "box", "state": "prompt", "queued": 1, "model": ""}]}, 200
                elif self.path == "/send":
                    out, code = {"pane": body["pane"], "delivered": False, "queued": 1, "state": "prompt"}, 200
                elif self.path == "/read":
                    out, code = {"pane": body["pane"], "state": "idle", "text": "line a\nline b"}, 200
                elif self.path == "/state":
                    out, code = {"pane": body["pane"], "state": "idle", "queued": 0}, 200
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
        self.assertEqual(names, ["panes", "send", "read", "state"])
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
        self.assertEqual(r.stdout, "codex-1: queued (state prompt, queued 1)\n")
        self.assertEqual(self.bus.requests[-1][2], {"pane": "codex-1", "text": "hello there"})
        r = self.run_cli("send", "codex-1", "-", stdin="from stdin\n")
        self.assertEqual(self.bus.requests[-1][2]["text"], "from stdin\n")
        r = self.run_cli("panes")
        self.assertIn("* claude-1", r.stdout)
        self.assertIn("codex-1", r.stdout)
        self.assertIn("box", r.stdout)
        r = self.run_cli("read", "codex-1", "2")
        self.assertEqual(r.stdout, "line a\nline b\n")
        r = self.run_cli("state", "codex-1")
        self.assertEqual(r.stdout, "codex-1 idle queued=0\n")
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

    def test_codex_snippet_matches_install_block(self):
        mod = load_shim()
        with open(os.path.join(os.path.dirname(SHIM), "snippets", "codex-config.toml")) as f:
            self.assertEqual(f.read(), mod.codex_block().lstrip("\n"))



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


if __name__ == "__main__":
    unittest.main()
