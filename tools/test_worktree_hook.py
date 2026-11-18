"""Tests for .githooks/pre-commit linked-worktree identity guard."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _git(repo, *args, check=True):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        capture_output=True,
        text=True,
    )


class WorktreeIdentityHookTests(unittest.TestCase):
    def test_linked_worktree_requires_worktree_email_and_main_is_unaffected(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = pathlib.Path(td)
            main = tmp / "main"
            main.mkdir()
            _git(main, "init")
            _git(main, "config", "user.name", "Owner")
            _git(main, "config", "user.email", "owner@example.com")
            _git(main, "config", "extensions.worktreeConfig", "true")
            _git(main, "config", "core.hooksPath", ".githooks")

            hooks = main / ".githooks"
            hooks.mkdir()
            hook = hooks / "pre-commit"
            shutil.copy2(ROOT / ".githooks" / "pre-commit", hook)
            hook.chmod(0o755)

            sub = main / "sub"
            sub.mkdir()
            (sub / "a.txt").write_text("init\n", encoding="utf-8")
            _git(main, "add", ".")
            _git(main, "commit", "--no-verify", "-m", "initial commit")

            wt = tmp / "wt-agent"
            _git(main, "worktree", "add", "-b", "agent-branch", str(wt))

            (wt / "note.txt").write_text("hello\n", encoding="utf-8")
            _git(wt, "add", "note.txt")
            bad = _git(wt, "commit", "-m", "should fail", check=False)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("git config --worktree user.name", bad.stderr)
            self.assertIn("git config --worktree user.email", bad.stderr)
            self.assertIn("AGENTS.md section 6", bad.stderr)
            self.assertEqual(_git(wt, "rev-list", "--count", "HEAD").stdout.strip(), "1")

            _git(wt, "config", "--worktree", "user.name", "Agent")
            _git(wt, "config", "--worktree", "user.email", "agent@example.invalid")
            good = _git(wt, "commit", "-m", "worktree identity commit", check=False)
            self.assertEqual(good.returncode, 0, good.stderr)
            self.assertEqual(
                _git(wt, "log", "-1", "--format=%an <%ae>").stdout.strip(),
                "Agent <agent@example.invalid>",
            )

            (main / "root.txt").write_text("main root\n", encoding="utf-8")
            _git(main, "add", "root.txt")
            self.assertEqual(_git(main, "commit", "-m", "main root commit", check=False).returncode, 0)

            (main / "sub" / "nested.txt").write_text("main sub\n", encoding="utf-8")
            _git(main / "sub", "add", "nested.txt")
            self.assertEqual(_git(main / "sub", "commit", "-m", "main sub commit", check=False).returncode, 0)
            self.assertEqual(
                _git(main, "log", "-1", "--format=%an <%ae>").stdout.strip(),
                "Owner <owner@example.com>",
            )


if __name__ == "__main__":
    unittest.main()
