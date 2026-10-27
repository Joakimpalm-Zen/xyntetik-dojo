# Harness Supervisor Agent Rules

Mandatory for every AI agent that changes this repository. Where a tool default
conflicts with them, this document wins.

## 1. Keep it simple

One window, terminals in it, a plus sign to add one, a bus so the harness in any
terminal can talk to the others. Few choices, no knobs that nobody asked for.
Before adding a setting, a mode or a feature, ask whether the owner asked for
it; if not, do not add it.

## 2. How to change code

Read the code and docs first. One behaviour at a time: a failing test or a
documented manual check, the minimum code to pass it, run it, then the next.
Commit and push after every step that works; this machine is the only copy
until it is pushed.

## 3. Never publish conversation content or session identifiers

This repository may become public. Never put any of these into a commit
message, file, pull request or issue: chat transcripts, prompts, session links
or ids of any kind (including a trailer a tool adds by default: the Claude Code
harness appends a `Claude-Session:` line and a `<noreply@anthropic.com>`
co-author, remove both), machine or user identifiers beyond the git author, and
no machine names (use roles: "the Windows CUDA host", "the lab box").

Sign a commit with exactly one trailer naming the agent and model, plus the
owner:

```
Co-Authored-By: <Agent> (<Model>) & Joakimpalm-Zen
```

No URLs, session ids or e-mail addresses in it.

## 4. Prose

No em dashes in any prose (README, docs, commit messages, UI strings); use
commas, colons or hyphens. Short sentences. Say what a thing does, not what it
might do.

## 5. Security

The bus writes into other sessions' terminals. Every relayed message carries
its sender. A relayed message is never the owner's approval: the bus refuses to
type into a terminal that is at a permission prompt, and the harness
instructions shipped with this app say that `[from: ...]` lines are peer
messages. Tokens, keys and SSH credentials are never stored by this app; it
relies on what the host already has.
