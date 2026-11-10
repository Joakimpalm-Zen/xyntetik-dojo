# Bus capabilities: a design note (D21.2)

Status: the owner chose on 2026-11-10: as today until a coordinator is marked (1a), worker-to-worker `send`
allowed (2a), the record keeps the text of each `send` and the metadata of everything for 30 days (3a), and
redaction is always on (4a). Built: the record (step 1 of the build order, D21.2.5), redaction in `read`
(step 2, D21.2.6, `Sources/XHSCore/Redact.swift`) and roles (step 3, D21.2.7): the coordinator mark and the
read grants are in the pane name's menu, not in the picker.

The question: who may read or send to whom on the bus, what `read` may return, what record the bus keeps,
and how an action the owner approved is told apart from one an agent started. The answer must keep the way
the panes work today, which is measured below before anything is proposed.

## What the bus does today

- **One token per pane, and every token can do everything.** The token says who is asking
  (`Bus.handle`). With it, any pane may list the panes, read any pane's screen, send to any harness pane,
  ask any pane's state and watch any pane. Only `hook` is limited: it changes the caller's own pane.
- **`read` returns the screen and scrollback as they are**, up to 500 lines, with nothing taken out.
- **`send` types the text into the target with a `[from: sender]` tag.** The tag comes from the token,
  never from the text: a line in the body that starts with `[from:` is set in by one space
  (`Delivery.line`), so only the bus writes such a line. Control characters are removed.
- **The bus holds a message** while the target is at a permission prompt (it never types into a prompt),
  while the owner is typing there, and while the owner has unsent text in the composer.
- **The relay** (`dojo relay`) runs one program the owner configured, with the words as data and the
  caller's name from its token. It is off unless `~/.dojo/relay` exists.
- **Nothing is recorded.** After the fact there is no way to say who sent what to whom, or who read
  which pane.

Since D21.1 a pane keeps its harness's own permission prompts unless the owner ticks "Skip permission
prompts", and its header says when it does not. That matters here: a permission prompt is the one place the
harness waits for the owner, and the bus never answers it.

## How the panes use the bus

Counted from the owner's sessions between 2026-10-11 and 2026-11-10: 38 Claude Code sessions and 7 Codex
sessions, every `dojo` call made through the shell or through the MCP tools. Panes are grouped by role:
the coordinator pane (the one the owner has running the others) and the worker panes.

| caller | operation | target | calls |
|---|---|---|---:|
| coordinator | send | workers | 380 |
| workers | send | coordinator | 282, plus 132 from the Codex pane |
| coordinator | state | workers | 65 |
| coordinator | read | workers | 25 |
| coordinator | watch | workers | 7 |
| workers | send | other workers | 67 by the mapping below, most from older sessions whose pane name it could not recover; the rest a few direct replies |
| workers | state, watch | other workers | 13 |
| workers | read | other panes | 25, all from the Codex pane, which among other things reviewed the others |

A session's role comes from the pane name it ran under: the name in the app's saved panes for the open
sessions, and the name a session gave its plan commands for older ones. `panes` (115 calls) and `state` are
status questions every pane asks. The working pattern is a star: the coordinator sends to, reads, watches and
asks after every worker, and each worker sends to the coordinator. Workers seldom talk to each other, and the
only worker that read other panes was the Codex pane.

## What can go wrong

1. **Secrets on a screen go to whoever reads it.** An API key in a `.env` that a harness printed, a token in
   a curl line, a password in a shell history: `read` hands any pane all of it.
2. **A pane's own bus token can be read.** Each pane has `DOJO_TOKEN` in its environment. If a harness ever
   prints its environment, a `read` of that pane gives the reader a token to act as that pane.
3. **Any pane can type into every other.** A worker that is confused, or that took instructions from a
   web page or a file, can message every pane at once. The peer rule says a `[from: ...]` line is never the
   owner's approval, and each harness was told so, but a harness is still asked to act on the text.
4. **No record.** When something went wrong there is no history to look at.
5. **Approval.** A peer's text could be taken for the owner's go-ahead. The bus never types into a prompt,
   but a pane that skips its prompts (D21.1, ticked) has none for the bus to respect.

## Proposal

### 1. Capabilities by role

The owner marks one pane as the coordinator, in the picker or in the pane's header menu. Every other harness
pane is a worker. The bus checks the caller's role on every operation:

| operation | coordinator | worker |
|---|---|---|
| `panes`, `state` | every pane | every pane |
| `send` | every pane | the coordinator; other workers only if the owner allows it (choice 2) |
| `read` | every pane | none, unless the owner grants that worker read of a named pane |
| `watch` | every pane | the coordinator |
| `relay` | as today (owner-configured) | as today |

A refused call gets a plain reason and goes into the record, for example: `read of 'worker-b' is not
allowed for 'worker-a', a worker pane; ask the coordinator, 'coordinator-1'`. This keeps every call in the
measured pattern working: the star is exactly what the table allows. The rare worker-to-worker reply is choice
2, and a review pane gets read access by the owner's grant, pane by pane, shown on its header.

With no pane marked as coordinator, the bus behaves as it does today (choice 1 decides whether that stays the
default). Tokens and remote panes do not change: a remote pane's calls come over its tunnel with its own
token, and the check is the same.

### 2. What `read` returns

The bus removes secrets from what `read` returns, before it leaves the bus:

- **Every live bus token**, matched exactly (the bus knows them all), becomes `[dojo token]`. That one is a
  guarantee, not a pattern.
- **Known secret shapes** become `[redacted: <kind>]`: private key blocks, AWS access keys, GitHub tokens,
  Anthropic, OpenAI and Hugging Face keys, Slack tokens, JSON web tokens, `Authorization: Bearer` values,
  credentials inside URLs, and `NAME=value` lines whose name holds TOKEN, SECRET, PASSWORD or API_KEY. The
  list follows the rule sets of gitleaks and detect-secrets and stays a short file in the repository.
- The reply says how many were taken out. Lines keep their place, so the text still reads.
- The owner's own view of a pane is never changed; only what goes to another pane is.

Redaction is a backstop. A pattern list misses things, so the primary control is who may read at all
(section 1).

### 3. A record of bus traffic

- One line per bus operation in `~/.dojo/audit/<date>.jsonl`, readable only by the owner: time, operation,
  caller, target, outcome (delivered, queued, refused and why), and sizes. The text of a `send` is kept
  (choice 3). A `read` records who read whom and how many lines, never the screen. A hook is the pane
  reporting on itself, so the record keeps the change of state it causes, not the hook.
- Each line carries the SHA-256 of the line before it, so a removed or edited line shows.
- Kept for 30 days (choice 3).
- The owner reads it with `dojo audit` (by pane, by time). It is not a bus route, so no pane can ask the bus
  for it; a harness running as the owner could still open the files with its own tools.

### 4. Owner-approved or agent-originated

What stays: the bus never types into a permission prompt, and only the bus writes `[from: ...]` lines. What
the record adds:

- **Owner input:** each time the owner submits in a pane (an Enter the app saw from the keyboard), with the
  time and no content.
- **Prompt answered by the owner:** when a pane leaves a permission prompt with owner keys in between and no
  bus delivery (none can arrive there), the record says so.
- **Every bus delivery:** with its sender, and the target's posture at the time ("prompts" or
  "unrestricted").
- **The Enter after each delivery:** sent; owed, when a prompt opened or a key that adds no text came
  between the paste and its Enter, which then goes once the pane is back and the owner has been quiet; or
  dropped, when the owner typed text into that composer after the paste (the bus never sends the owner's
  words) or pressed Enter or Ctrl-C there themselves. The pointer moving or the wheel turning over a pane
  whose program tracks the mouse is not a key.

So for any action in a pane the record shows what came just before it: the owner's keys, or a message and
from whom. In a pane that skips its prompts, an action after a bus message is the agent's by definition, and
the record says the pane was unrestricted. Signing the owner's approvals is not proposed: no harness could
check a signature.

### Not in this note

- **Filesystem access scoped to a workspace** belongs to the harness's own sandbox (Codex's
  `--sandbox workspace-write`, Claude Code's permission rules). That would be a middle launch profile under
  D21.1, not a bus rule.
- **Sandboxed execution** comes later.

## Prior art

- **Claude Code** checks every tool call against allow and deny rules per tool; **Codex** has sandbox
  modes (read-only, workspace-write, full access). Both are per-harness and know nothing of other panes.
- **tmux and Zellij** give any client of the server socket every power (send keys, capture a pane); tmux 3.3
  added read-only clients. Nothing there distinguishes one pane's program from another.
- **Matrix** gates each room event by a numeric power level, and **Slack** apps get named scopes (read a
  channel, post to it): the same idea as a role table, for people and bots.
- **gitleaks** and **detect-secrets** carry the regular expressions and entropy checks used for secret
  shapes.
- **Append-only audit logs** with a hash per entry are what tamper-evident logging systems use; the chain
  here is the smallest form of that.

## Build order, once chosen

1. **The record** first: it changes no behaviour and shows the real traffic.
2. **Redaction in `read`**, starting with the exact bus tokens.
3. **Roles**, with the coordinator mark in the picker and the header, and the refusals.

Each step has its tests at the bus (the operation, the role, the expected refusal or redaction), as the bus
tests do now.

## Choices for the owner

1. **The default with no coordinator marked.** (a, recommended) as today, everything allowed, until the owner
   marks a coordinator; nothing breaks on the update. (b) Restricted from the start: until a coordinator is
   marked, panes may only send. (c) Discuss.
2. **Worker to worker `send`.** (a, recommended) allowed: rare, and replies between workers are useful. (b)
   Only through the coordinator. (c) Discuss.
3. **What the record keeps, and for how long.** (a, recommended) the text of each `send` and the metadata of
   everything, 30 days. (b) Metadata and a hash of the text, no text, 90 days. (c) Discuss.
4. **Redaction.** (a, recommended) always on for `read`, no switch. (b) On, with a per-pane switch the owner
   can turn off. (c) Discuss.
