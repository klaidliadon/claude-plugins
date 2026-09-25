# klaidliadon/claude-plugins

Personal Claude Code plugin marketplace.

## Plugins

- **agent-comms**: two agent sessions (e.g. Claude as author, Codex as reviewer) iterate on an artifact through a shared file until they converge or hit an impasse.
- **codex-review**: run a Codex code review against a GitHub PR, specific files, or the local working tree.
- **design-proposal**: structure a decision-ready engineering design proposal.
- **gh-stack**: GitHub-native stacked pull requests via the `gh-stack` CLI extension: create, sync, navigate, and atomically merge PR stacks.
- **gh-workflow**: authoring GitHub PRs and issues, the gated review pipeline, chained-PR merge order, and code-review output.
- **git-cleanup**: audit local branches and worktrees against GitHub PR state, auto-clean safe ones, prompt on the rest, with `--all` sweep across `~/Workspace` and `--dry-run`. Slash command: `/git-cleanup`.
- **go-style**: Go style conventions.
- **land-pr**: drive an open GitHub PR until it is actually merged: rebase, green CI, address human and bot reviews, poll, merge. Slash command: `/land-pr`.
- **ridl-lsp**: RIDL language server for `.ridl` schema files.
- **service-skeleton**: Go backend service layout and where new code belongs.
- **writing-for-humans**: the house standard for human-facing prose, on two axes: readability and voice.

## Install

In Claude Code:

```
/plugin marketplace add klaidliadon/claude-plugins
/plugin install git-cleanup@klaidliadon
/plugin install ridl-lsp@klaidliadon
```

Updates: `/plugin marketplace update klaidliadon`.

## Layout

```
.claude-plugin/marketplace.json   # marketplace manifest
plugins/<name>/
  .claude-plugin/plugin.json      # plugin manifest
  commands/<cmd>.md               # slash commands (optional)
  skills/<skill>/SKILL.md         # skills (optional)
```
