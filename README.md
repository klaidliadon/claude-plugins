# klaidliadon/claude-plugins

Personal Claude Code plugin marketplace.

## Plugins

- **git-cleanup** — Audit local branches and worktrees against GitHub PR state, auto-clean unambiguously safe branches, prompt on the rest. Conservative, stack-aware via sdf, with `--all` sweep across `~/Workspace` and `--dry-run`. Slash command: `/git-cleanup`.
- **ridl-lsp** — RIDL language server for `.ridl` schema files.

## Install

```sh
# Local (from this directory)
/plugin marketplace add /Users/aguerrieri/Workspace/klaidliadon/claude-plugins
/plugin install git-cleanup@klaidliadon
/plugin install ridl-lsp@klaidliadon

# Remote (once pushed)
/plugin marketplace add klaidliadon/claude-plugins
```

## Layout

```
.claude-plugin/marketplace.json   # marketplace manifest
plugins/<name>/
  .claude-plugin/plugin.json      # plugin manifest
  commands/<cmd>.md               # slash commands (optional)
  skills/<skill>/SKILL.md         # skills (optional)
```
