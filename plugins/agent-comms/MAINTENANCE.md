# Maintaining agent-comms

How the two sessions load this plugin, and how to ship a change to both.

## Canonical source and immutable runtime

- The marketplace clone (`~/.claude/plugins/marketplaces/klaidliadon/…`) is the
  canonical source.
- Claude Code installs that source into its immutable version-pinned cache
  (`~/.claude/plugins/cache/klaidliadon/agent-comms/<version>`).
- `agent-comms install-codex` verifies the cache against the marketplace, then
  links Codex's skill and stable commands to that exact cache directory.

`agent-comms doctor` compares the manifest version, a deterministic runtime
digest, and every link target. The reviewer wrappers run it before spawning a
child and refuse a split installation.

## Shipping a change

1. Edit under `plugins/agent-comms/`.
2. **Bump `version` in `.claude-plugin/plugin.json` on every change. Never
   reuse a version after any copy has been installed.**
3. Validate and test before merging:
   ```
   claude plugin validate plugins/agent-comms
   bash plugins/agent-comms/test/run.sh
   bash plugins/agent-comms/test/e2e.sh
   bash plugins/agent-comms/test/flock-hammer.sh
   ```
4. Commit, merge, push, then create and push the release tag:
   ```
   claude plugin tag plugins/agent-comms --push
   ```
5. Refresh and converge both runtimes:
   ```
   claude plugin marketplace update klaidliadon
   claude plugin update agent-comms@klaidliadon
   agent-comms install-codex
   agent-comms doctor
   ```

Stable, non-versioned link paths (`~/.local/bin/{agent-comms,claude-review,codex-review,lib.sh}`,
`~/.codex/skills/agent-comms`) mean a version bump never breaks the symlinks —
`install-codex` preflights every target before moving any link to the new cache.
