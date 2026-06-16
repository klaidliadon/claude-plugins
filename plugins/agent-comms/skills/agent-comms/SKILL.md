---
name: agent-comms
description: Use when two agent sessions (e.g. Claude as author, Codex as reviewer) need to autonomously iterate on an artifact — passing messages through a shared file, debating findings, and converging without the human relaying between two chats. Trigger when the user says "review this with Codex until you agree", "have the two of you iterate", "join channel X as reviewer", or "agent-comms".
---

# agent-comms — autonomous 2-party review loop

Two roles share one channel file, driven by a single `agent-comms` command. It
ships in this plugin's `bin/`, which Claude Code adds to `$PATH` while the plugin
is enabled — so call it by bare name: `agent-comms <subcommand>`.

> **Other hosts (e.g. Codex CLI):** run `agent-comms install-codex` once. It links
> the skill into `~/.codex/skills/` and prints the `export PATH=…` line to add the
> `bin/` to PATH there too. After that, the commands below work identically.

## Spawning the Codex reviewer (author session)

To launch Codex non-interactively as the reviewer, **always use the `codex-review`
wrapper** (ships in this plugin's `bin/`):

```
codex-review --prompt-file <reviewer-prompt.txt>
```

It feeds the prompt on **stdin** and disables Codex's sandbox.

> **⚠️ VERY IMPORTANT — never call `codex exec` directly for this.** `codex exec`
> reads stdin even when handed a positional prompt, so a backgrounded
> `codex exec "$(cat prompt.txt)"` hangs forever on `Reading additional input
> from stdin...` instead of reviewing. And the child must run with its sandbox
> off, or it can't read the repo / run `agent-comms` (nested-sandbox gotcha —
> the outer host also sandboxes the child). `codex-review` handles both; raw
> `codex exec` invites silent stalls.

## Setup
- Channel `C` and the two participant names are agreed with the human.
- Both sessions must resolve the same comms dir. Resolution precedence:
  `--dir DIR` > `--root DIR` > `$AGENT_COMMS_ROOT` > git repo root > `$PWD`.
  Prefer the **flags** so each command line starts with `agent-comms` (no env
  prefix → a single permission allowlist rule covers every call):
  - `--root <abs repo root>` → channel at `<root>/tmp/agent-comms/` (the default).
  - `--dir <abs dir>` → channel at `<dir>/` exactly (cross-repo / shared dir).
  Pass the same flag in BOTH sessions and on EVERY call. Verify with
  `agent-comms path --channel C [--root … | --dir …]` — never `/tmp`.

## Commands

**Invoke atomically.** Every call must START with the literal `agent-comms`, as
its own command — no `H=$(agent-comms …)` capture, no `printf … | agent-comms`
pipe, no `;`/`&&` chaining. Those break both the `Bash(agent-comms *)` allow rule
(prefix match) and any compound-command guard. The flags below exist so you never
need a pipe or a captured hash.

- Send: `agent-comms send --channel C --from <me> [--tag <wire-tag>] [--body-file <f>] [--review-ref|--approve-ref|--converged-ref <artifact>]`
  - Body: pass `--body-file <f>` (write the body with your editor first). Stdin
    still works as a fallback, but the pipe form trips the guards above.
  - Ref tags: `--review-ref/--approve-ref/--converged-ref <artifact>` hash the
    artifact IN-PROCESS and set the wire tag — no separate `hash` step, no `$()`,
    and the tag always matches the bytes on disk. The computed `tag=H` is echoed
    to stderr for audit. Mutually exclusive with `--tag`; use `--tag` for literal
    tags like `stopped-reason=impasse`.
- Recv (blocks): `agent-comms recv --channel C --me <me>`
  - prints peer message(s), or `__TIMEOUT__` (exit 2) if none within the window.
- Transcript: `agent-comms transcript --channel C`
- Hash an artifact (manual check / reviewer snapshot): `agent-comms hash <file>` → sha256

Pin `--root <abs repo root>` (or `--dir`) on EVERY call — see Setup; omitting it
resolves the channel from cwd's git root and silently splits the channel.

## Wire tags (canonical, hyphenated — never a space)
- `review-ref=H` (driver), `approve-ref=H` (reviewer),
- `converged-ref=H` (driver-only, terminal, success),
- `stopped-reason=impasse|stall|silence|circuit-breaker` (driver-only, terminal).

## Findings ledger (in message bodies)
Each review point: ID (`F1`…), severity (Critical/Important/Suggestion),
status (open/resolved/contested). Only Critical/Important block convergence.
Progress = a finding added, resolved, or given materially new evidence.

## Loop — Driver (author)
1. Edit the artifact and write the message body to a file.
2. `agent-comms send … --review-ref <artifact> --body-file <body>` (the bin hashes
   the artifact and tags `review-ref`; no manual hash, no `$()`).
3. `agent-comms recv` and BLOCK.
4. For each finding: fix (→resolved) or rebut WITH NEW EVIDENCE (→contested);
   edit the artifact if it changed.
5. If a terminal condition holds → send the driver-only terminal tag and STOP
   (terminal sends are exempt from the recv-after-send rule). Else go to 2.

## Loop — Reviewer
1. `agent-comms recv` and BLOCK.
2. Snapshot the artifact and review it.
3. Raise/update findings, or `agent-comms send … --approve-ref <artifact>` (hashes
   the snapshot you reviewed and tags `approve-ref`).
4. `agent-comms recv` and BLOCK. **Two hard rules:**
   - **Terminal wins:** if a recv batch contains `converged-ref` or
     `stopped-reason`, EXIT immediately regardless of other frames.
   - **Timeout means wait:** on `__TIMEOUT__`, call `agent-comms recv` again; do
     NOT exit. Exit ONLY on a driver terminal message.

## Termination (driver decides, always releases the reviewer)
- **Converge:** no open/contested Critical/Important AND current artifact hash ==
  reviewer's last approve-ref → `converged-ref=H`, present result + transcript.
- **Impasse:** a Critical/Important finding stays contested after two rebuttals
  with no new evidence → `stopped-reason=impasse`, present BOTH positions to human.
- **Stall:** 3 exchanges with no progress → `stopped-reason=stall`.
- **Circuit breaker:** 25 exchanges → `stopped-reason=circuit-breaker`.
- **Silence:** recv `__TIMEOUT__` after 1–2 retries → `stopped-reason=silence`
  (sent durably so a late reviewer still exits), then surface to human.

## Hash discipline
`--review-ref/--approve-ref/--converged-ref` hash the artifact at send time, so a
ref tag always matches the bytes on disk at that moment. Reviewer approves the
snapshot it reviewed (send `--approve-ref` right after reviewing, before any edit).
Driver sends `--converged-ref <artifact>` only when no open/contested
Critical/Important remain AND the artifact is unchanged since the reviewer's
approve; if the driver edited after approval, the new hash won't match — keep looping.
