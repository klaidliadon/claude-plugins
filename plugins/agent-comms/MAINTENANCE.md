# Maintaining agent-comms

How the two sessions load this plugin, and how to ship a change to both.

## Dual read model

- **Claude Code** reads the version-pinned plugin **cache**
  (`~/.claude/plugins/cache/…`).
- **Codex** reads the **marketplace clone**
  (`~/.claude/plugins/marketplaces/klaidliadon/…`) — wired in via
  `agent-comms install-codex`, which links the skill into `~/.codex/skills/`
  and the `bin/` onto Codex's `PATH`.

Because the two hosts read from different locations, a change isn't live for
both until each location is refreshed.

## Shipping a change

1. Edit under `plugins/agent-comms/` and commit + push.
2. **Bump `version` in `.claude-plugin/plugin.json` on every change** — the
   update commands below only detect a change when the version moves.
3. Refresh both reads:
   ```
   /plugin marketplace update klaidliadon   # refreshes the clone → Codex + linked bin
   /plugin update agent-comms               # refreshes Claude's cache
   ```

Stable, non-versioned link paths (`~/.local/bin/{agent-comms,lib.sh}`,
`~/.codex/skills/agent-comms`) mean a version bump never breaks the symlinks —
only the content behind them changes.
