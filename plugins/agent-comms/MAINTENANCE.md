# Maintaining agent-comms v2

The marketplace repository is canonical source. Claude's selected versioned
cache is the immutable runtime store. Codex and the public CLI resolve through
one pointer:

```text
~/.local/share/agent-comms/current -> ~/.claude/plugins/cache/.../<version>
~/.local/bin/agent-comms          -> current/bin/agent-comms
~/.codex/skills/agent-comms       -> current/skills/agent-comms
```

`claude-review`, `codex-review`, `install-codex`, and a public `lib.sh` are v1
artifacts. V2 removes them.

## Install

Bootstrap the marketplace, then run its mutable lifecycle binary:

```text
claude plugin marketplace add klaidliadon <repo>
<marketplace>/plugins/agent-comms/bin/agent-comms install
```

`install` is idempotent. Under one exclusive update lock it asks Claude to
install/update the selected plugin, verifies both marketplace and cache
manifests, runs parser/adapter smoke checks, atomically renames `current`, wires
the CLI and Codex skill through that pointer, removes owned v1 links, and runs
`doctor`. Failure restores the old pointer and links.

Claude's plugin selection changes before the local activation transaction and
its CLI exposes no rollback operation. If later validation fails, agent-comms
restores `current` and its links, then `doctor` reports the selected/current
mismatch. Fix the release or marketplace state and rerun idempotent `install`;
do not repoint either side by hand.

## Update and diagnose

```text
agent-comms update --check
agent-comms update
agent-comms doctor
agent-comms doctor --channel C --dir <absolute-channel-dir>
```

An independent `claude plugin update` may advance Claude without taking the
agent-comms lock. The next generation-1 launch fails closed because global
`doctor` compares `claude plugin list --json`, `current`, marketplace bytes,
the public CLI, and Codex skill. Run `agent-comms install` to reconcile.

Channels pin `release`, `digest`, `protocol`, and an absolute immutable
`release_root`. Updating `current` changes only new channels. Existing commands
dispatch to the pinned root; a missing old release is an error, never a fallback
to `current`. V2 has no pruning command.

## Runtime progress supervision

Each channel pins `semantic_timeout`, defaulting to 300 seconds and capped at
3600. The launcher enforces it only while its runtime owns the floor. A
current-generation `continue` or `over` message resets the clock; status,
heartbeat, raw runtime output, and activity ticks do not. Acquiring the floor
starts a fresh clock, while yielding pauses enforcement. The default progress
budget is eight 512-byte frames; launcher instructions cap each normal
checkpoint at 256 bytes.

Until the runtime lands its first current-generation frame, the launcher uses a
separate 120-second deadline, configurable through the positive integer
`AGENT_COMMS_FIRST_FRAME_TIMEOUT` and clamped to the session semantic limit.
Expiry appends `first-frame-timeout` with `transport=unconfirmed`, terminates
the runtime, and exits 124. This diagnoses launch-environment transport failures
without waiting for the mid-turn semantic deadline.
If a runtime exits while it owns the floor without landing that first frame,
the launcher instead appends `first-frame-exit`; a reported child status of zero
is converted to exit 70 so missing transport participation cannot pass.

The 300-second default is the maximum interval between evidence-bearing
updates, not a total review deadline. Larger values are explicit per-session
overrides for workloads that cannot expose a smaller meaningful boundary.
Consecutive byte-identical progress bodies are rejected so a canned liveness
signal cannot extend semantic supervision.

Expiry appends `semantic-timeout`, terminates the runtime, and makes the
launcher exit 124 even when the child reports a different status. A replacement
control keeps the open turn number but resets both the receive deadline and the
new launcher's semantic deadline. Protocol inspection failure is fail-closed:
the launcher records `semantic-supervision-failed` when possible and exits
nonzero.
Terminal peer control terminates the runtime immediately; it does not leave a
reviewer running after the channel is closed.

`launch` requires the reviewed repository as `--root` even when the channel
uses a separate `--dir`. Claude launch rejects channels under
`CLAUDE_CONFIG_DIR` (normally `~/.claude`) because the host protects that tree
from Bash writes even when it is passed through `--add-dir`. Claude receives
600-second foreground Bash defaults so the 540-second receive window cannot be
silently backgrounded by the host. `launcher-ready` means adapter/transport
readiness only. The model must publish its own first `continue` checkpoint
before repository inspection. The bootstrap discloses the exact body and
command and tells the model to verify the pinned path and session arguments
from the prompt itself, without a filesystem probe before the checkpoint.
Later progress bodies are agent-written and must carry new evidence. Claude
`--safe-mode`, `--bare`, and
`CLAUDE_CODE_SAFE_MODE=1` are
rejected because they remove the protocol instruction substrate. Every
generation reruns global installation drift verification before model work.

## Runtime activity

`launch` forces Claude `stream-json` or Codex `--json` output and fails before
model work when the installed adapter lacks that capability. It publishes a
generation-scoped feed at:

```text
D/.activity/C/<agent>.<generation>.log
```

The feed records at most one sanitized sample per active 30-second window:
`ts`, `seq`, event count, structural event types, and structural content-block
types. It records no message text, reasoning, tool input/output, or byte count:
at most 120 lines per active hour and zero peer-model turns. Files share the
comms directory's retention lifecycle.

Raw structured output exists only in a mode-`0600` spool unlinked before the
runtime starts. It has no pathname while populated but can reach page cache or
backing storage; this is not protection from local forensic access. Sampling
and feed-write failures are fail-open after startup and never replace the
runtime exit status.

## V1 migration

Finish or explicitly stop every v1 channel before installing v2. V1 has no
release root, checksum, generation fence, or safe resume packet and cannot be
upgraded in place. Start a new v2 channel after installation.

## Build a release

Every changed bundle gets a new version. Never reuse an installed version.

1. Set the same version in `.claude-plugin/plugin.json`, the literal
   `--client-release` in `SKILL.md`, `CLIENT_RELEASE` in `bin/launch.sh`, and
   every release-pinned test fixture. Sweep the prior version across the whole
   plugin and require zero remaining matches.
2. Generate and inspect the deterministic manifest:

   ```text
   agent-comms release manifest
   ```

3. Run:

   ```text
   claude plugin validate plugins/agent-comms
   bash plugins/agent-comms/test/run.sh
   bash plugins/agent-comms/test/e2e.sh
   bash plugins/agent-comms/test/flock-hammer.sh
   ```

4. Review the committed implementation through agent-comms in both launch
   directions with strict cost caps.
5. On a clean branch, run `agent-comms release check`, then
   `agent-comms release publish`.

For v2.0.4 the immutable tag is `agent-comms--v2.0.4`. `publish` rechecks the
bundle, creates and pushes that unmoving tag, refreshes the marketplace,
performs the normal update transaction, and runs post-activation `doctor`.
Rollback moves only `current`; a bad published tag is never moved or reused.
