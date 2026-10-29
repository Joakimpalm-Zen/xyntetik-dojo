#!/usr/bin/env python3
"""The mechanical half of AGENTS.md, for the hygiene workflow and `make test`.

    check-hygiene.py --files                       # the tracked tree: prose and personal details
    check-hygiene.py --range BASE..HEAD [--text FILE ...]   # commit messages and pull request text
    check-hygiene.py --self-test

Commits: a Co-Authored-By trailer, when present, is exactly `Co-Authored-By: <Agent> (<Model>) &
Joakimpalm-Zen` and there is one; no Claude-Session line, no e-mail address, no session URL or id, no
em dash. Tree: no em dash in Markdown or in Sources (quoted program output in tests and tools may carry
one); no home path, personal address, private network address, machine name or user name anywhere.
"""
import re
import subprocess
import sys

OWNER = "Joakimpalm-Zen"
TRAILER = re.compile(r"^Co-Authored-By: [^()\n]+ \([^()\n]+\) & " + re.escape(OWNER) + r"$")
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
SESSION = re.compile(r"claude\.ai/\S*|/session/|Claude-Session:|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
EM_DASH = "—"
# Nothing personal: home paths with a user name, private network addresses, the owner's own addresses,
# and machine or user names that belong to the owner's desk, not to this program.
PERSONAL = [
    (re.compile(r"/Users/(?!me\b)[A-Za-z]"), "a home path with a user name"),
    (re.compile(r"/c/Users/(?!me\b)[A-Za-z]"), "a Windows home path with a user name"),
    (re.compile(r"\b(?:192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b"), "a private network address"),
    (re.compile(r"@(?:hotmail|gmail|outlook|icloud)\.", re.I), "a personal e-mail address"),
    (re.compile(r"\b(?:zenzombie|zen@|mainbox|blackwell|galaxa|strata)\b", re.I), "a machine or user name"),
]
PROSE_SUFFIXES = (".md",)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def check_message(text, where):
    problems = []
    trailers = [l for l in text.splitlines() if l.startswith("Co-Authored-By:")]
    if len(trailers) > 1:
        problems.append(f"{where}: {len(trailers)} Co-Authored-By trailers, one is the rule")
    for t in trailers:
        if not TRAILER.match(t):
            problems.append(f"{where}: trailer not in the form 'Co-Authored-By: <Agent> (<Model>) & {OWNER}': {t}")
    body = "\n".join(l for l in text.splitlines() if not l.startswith("Co-Authored-By:"))
    if SESSION.search(text):
        problems.append(f"{where}: a session id, session URL or Claude-Session line")
    if EMAIL.search(body):
        problems.append(f"{where}: an e-mail address")
    if EM_DASH in text:
        problems.append(f"{where}: an em dash")
    return problems


def check_range(rng):
    problems = []
    for sha in git("rev-list", "--no-merges", rng).split():
        text = git("log", "-1", "--format=%B", sha)
        problems += check_message(text, sha[:10])
    return problems


def check_files():
    problems = []
    for path in git("ls-files").split("\n"):
        if not path:
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, IsADirectoryError):
            continue
        prose = path.endswith(PROSE_SUFFIXES) or path.startswith("Sources/")
        for n, line in enumerate(text.splitlines(), 1):
            if prose and EM_DASH in line:
                problems.append(f"{path}:{n}: an em dash")
            for pattern, what in PERSONAL:
                if pattern.search(line):
                    problems.append(f"{path}:{n}: {what}")
    return problems


def self_test():
    ok = True
    good = "A change\n\nCo-Authored-By: Claude Code (Fable 5.1) & Joakimpalm-Zen\n"
    ok &= check_message(good, "good") == []
    ok &= any("form" in p for p in check_message("x\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n", "bad"))
    ok &= any("one is the rule" in p for p in check_message(good + "Co-Authored-By: Codex (gpt) & Joakimpalm-Zen\n", "two"))
    ok &= any("session" in p for p in check_message("x\n\nClaude-Session: 123\n", "session"))
    ok &= any("session" in p for p in check_message("see https://claude.ai/code/session/abc\n", "url"))
    ok &= any("e-mail" in p for p in check_message("mail me at someone@example.com\n", "mail"))
    ok &= any("em dash" in p for p in check_message("a — b\n", "dash"))
    ok &= check_message("plain words, no trailer\n", "plain") == []
    for sample, what in [("/Users/someone/x", "home"), ("192.168.1.9", "network"), ("a@hotmail.com", "e-mail"), ("ZENZOMBIE", "name")]:
        ok &= any(p.search(sample) for p, _ in PERSONAL) or print("missed", what) or False
    ok &= not any(p.search("/Users/me/repo") or p.search('home: "/c/Users/me"') for p, _ in PERSONAL)
    print("check-hygiene self-test", "ok" if ok else "FAILED")
    return 0 if ok else 1


def main(argv):
    if "--self-test" in argv:
        return self_test()
    problems = []
    if "--files" in argv:
        problems += check_files()
    if "--range" in argv:
        problems += check_range(argv[argv.index("--range") + 1])
    for i, a in enumerate(argv):
        if a == "--text":
            problems += check_message(open(argv[i + 1], encoding="utf-8").read(), argv[i + 1])
    for p in problems:
        print(p)
    print("check-hygiene", "ok" if not problems else f"{len(problems)} problem(s)")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
