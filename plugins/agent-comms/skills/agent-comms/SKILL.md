---
name: agent-comms
description: Use when Claude and Codex must autonomously exchange progressive work, review an artifact until agreement, or resume an interrupted two-agent session without a human relaying messages.
---

# Agent Comms

Use one append-only, human-readable channel. `tail -f "$(agent-comms path …)"`
shows the whole exchange; hidden v2 headers, not visible separators or the word
`over`, are authoritative.

Release literal: `--client-release 2.0.0`. Never derive or change it at runtime.

## Start a review

Pick the reviewed repository's absolute root `R` and one absolute `--dir D`
writable by both runtime sandboxes. Pass `--dir D` on every command. Every
`launch` also requires `--root R`; this keeps the work tree independent from
the shared channel directory and the caller's current directory. For Claude,
`D` must be outside `CLAUDE_CONFIG_DIR` (normally `~/.claude`); that tree is
protected even with `--add-dir` and bypass mode, so launch rejects it before
spending a model turn.

1. Create the channel. The invoked immutable release pins its own version,
   digest, protocol, and root:

   ```text
   agent-comms init --channel C --session S --driver <me> --peer <peer> --dir D
   ```

2. Write a reviewer prompt beginning with a concrete one-line title. Launch the
   peer with the host's background-process facility:

   ```text
   agent-comms launch <claude|codex> --role reviewer --peer <me> \
     --channel C --generation 1 --prompt-file P \
     --client-release 2.0.0 --root R --dir D
   ```

3. Require `launcher-ready` before spending a model turn. This proves the
   transport and runtime adapter are ready; it is not a model-generated ACK:

   ```text
   agent-comms wait-ready --channel C --me <me> --peer <peer> \
     --generation 1 --dir D
   ```

4. Send the task with `--review-ref <artifact>`, then call `recv`.

## Walkie-talkie turns

Write each body to a file. A normal `send` ends with the visible
`---------- <sender> · over ----------` and yields the floor. `--continue`
emits `----------` and retains it.

```text
agent-comms send --channel C --from <me> --generation N \
  [--continue] [--review-ref|--approve-ref <artifact>] --body-file B --dir D
agent-comms recv --channel C --me <me> --generation N --dir D
```

`recv` returns one completed peer turn, coalescing progressive messages and
excluding heartbeats/status. Never poll after `--continue`; keep working.
Progress is capped at eight 512-byte fragments per turn. Send useful conclusions,
not tool logs or hidden reasoning.

When taking the floor, run the launcher's exact mandatory checkpoint command
before reading files. It uses a prebuilt bounded body, so the first model tool
call proves transport participation without spending tokens composing status.
Run the launcher's reusable checkpoint command after repository inspection,
after agreeing a plan, and after each commit or verification batch. Use work boundaries, not
elapsed-time guesses. Report the phase, concrete evidence, and next step or
blocker in at most 256 bytes. Skip inapplicable phases; never manufacture
updates.

The session defaults `semantic_timeout` to 300 seconds and permits at most 3600.
While an agent holds the floor, only one of its current-generation message
frames resets that clock; status, heartbeat, and activity ticks do not. The
launcher records `semantic-timeout`, terminates the runtime, and exits 124 when
the limit expires. The waiting peer may then resume it.

Claude launches with foreground Bash timeouts long enough for the default
590-second `recv`. Call `recv` synchronously again after a silence timeout;
never leave it running in the background.

Maintain findings as `F1…`, severity `Critical|Important|Suggestion`, and status
`open|resolved|contested`. Only unresolved Critical/Important findings block
approval.

## Tail activity without waking the peer

`launcher-ready` and `launching` publish `activity_ref=<absolute path>`. Humans
and external supervisors may tail it. `seq` advances at most once per active
30-second window and exposes no content or byte count. Activity never yields or
wakes `recv`; never relay it to the waiting model.

## Resume an interrupted peer

On `__TURN_TIMEOUT__`, stop the old launcher process, write a bounded handoff,
then fence and replace the current floor holder:

```text
agent-comms resume --channel C --from <driver> --generation <driver-gen> \
  --replace <peer> --body-file HANDOFF [--artifact-file ARTIFACT] --dir D
```

Launch the peer again with its incremented generation, `--root R`, and the same
pinned `--client-release 2.0.0`. Pass the current artifact when one exists. The
launcher verifies its hash and injects the original task body, task checksum,
handoff, and artifact checksum; never replay the full transcript or fall
forward to `current`. Late old-generation frames remain visible but are
excluded from delivery. Replacement keeps the open turn number but starts fresh
receive and semantic-progress deadlines.

## Finish

- Reviewer: `--approve-ref <artifact>` only for the exact reviewed bytes, then
  `recv` again.
- Driver convergence: send `--converged-ref <artifact>` with a body. This is a
  terminal control and releases the reviewer.
- Driver stop: send `--tag stopped-reason=impasse|stall|silence|circuit-breaker`.
- Stop after 25 exchanges, three no-progress exchanges, or two evidence-free
  rebuttals. Report both positions on impasse.

Run `agent-comms doctor` for global drift and
`agent-comms doctor --channel C --dir D` for pinned-session integrity. Do not
repair drift by hand; use `agent-comms install`.
