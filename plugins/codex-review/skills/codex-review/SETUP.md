# Setup Guide — Codex Review Skill

This guide walks through installing everything needed to run the
`codex-review` skill end-to-end. The skill asks Codex (via the OpenAI
Codex CLI, optionally through its Claude Code plugin) to review code.

## What you get

Three review modes, picked automatically from the prompt:

- **PR mode** — async. Reviews a GitHub PR in a throwaway worktree via the
  plugin's companion + broker. Tracked by `/codex:status` / `/codex:result`.
- **Files mode** — sync. Reviews specific files in the current repo with
  `codex exec`. Output returns in-turn.
- **Working tree mode** — sync. Reviews staged/unstaged or branch diff with
  `codex exec review`. Output returns in-turn.

The plugin + broker prerequisites below apply only to **PR mode**. Files and
working-tree modes need nothing beyond the `codex` CLI itself and the
sandbox settings in §3.

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| Claude Code | Host environment for the skill | https://claude.ai/code |
| Codex CLI (`codex`) | Does the actual review | `npm install -g @openai/codex` |
| `gh` | Fetch PR metadata | `brew install gh` |
| `node` (≥ 20) | Runs the plugin's companion + broker scripts | `brew install node` |
| `git` | Worktrees | ships with macOS |

## 1. Authenticate Codex CLI

```bash
codex login
```

Follow the browser flow. Credentials land in `~/.codex/auth.json`.

Smoke test:

```bash
codex --version
codex app-server --help   # should print usage
```

## 2. Install the Claude Code plugin

Inside Claude Code:

```
/plugin install codex@openai-codex
```

Then verify:

```
/codex:setup
```

This should report "Codex CLI is ready." If it complains about missing
runtime support, re-run `codex login` or upgrade `@openai/codex`.

## 3. Configure Claude Code sandbox (`~/.claude/settings.json`)

Merge these into your existing `sandbox` block — don't replace:

```json
{
  "sandbox": {
    "enabled": true,
    "enableWeakerNestedSandbox": true,
    "excludedCommands": ["codex"],
    "filesystem": {
      "allowRead":  ["~/.codex"],
      "allowWrite": ["~/.codex"]
    },
    "network": {
      "allowedDomains": [
        "chatgpt.com",
        "api.openai.com",
        "auth.openai.com"
      ]
    }
  }
}
```

Why each one matters:

- `enableWeakerNestedSandbox: true` — Codex uses `sandbox-exec` internally
  for its own tool runs. Nested inside Claude Code's sandbox that fails
  with "sandbox_apply: Operation not permitted" unless this is on.
- `excludedCommands: ["codex"]` — lets `codex` itself run outside the
  sandbox, so its own sandboxing works.
- `filesystem.allowRead/Write: ~/.codex` — Codex reads `auth.json`,
  writes session logs and `config.toml` overrides.
- `network.allowedDomains` — the three hosts the CLI uses for API + auth.

**Changes apply on Claude Code restart.** Settings aren't hot-reloaded.

## 4. Add allowlist entries

Append to `permissions.allow` in `~/.claude/settings.json`:

```json
[
  "Bash(gh *)",
  "Bash(git *)",
  "Bash(node /Users/<you>/.claude/plugins/*)",
  "Bash(ls *)",
  "Bash(jq *)",
  "Bash(mkdir -p *)",
  "Bash(find *)",
  "Bash(pkill *)"
]
```

The `find` and `pkill` entries are the non-obvious ones — they're what
the skill uses for step-5 broker cleanup. Without them you'll get
permission prompts mid-run.

Skip the `cd && node` anti-pattern: the skill invokes the companion with
`--cwd "$WT"` so the command matches your `Bash(node ...plugins/*)` entry
atomically.

## 5. Install the skill

Copy (or symlink) this directory to `~/.claude/skills/codex-review/`:

```
codex-review/
├── SKILL.md        # the skill itself
└── SETUP.md        # this file
```

Restart Claude Code. In a new session, ask:

> review PR 42

or similar — the skill triggers on prompts containing a PR number.

## 6. Smoke test

Pick a small open PR in a repo you have local:

```
review PR <N>
```

Expected flow:

1. Claude fetches PR metadata, creates a worktree at
   `/tmp/claude/codex-review/pr-<N>`.
2. Cleans up any stale `broker.json` for this worktree.
3. Launches `codex-companion.mjs review --background`.
4. Reports back: "review started, poll with `/codex:status`."
5. Result available via `/codex:result` when the turn completes
   (typically 2–8 min for real PRs).

If the first run fails with
`failed to load configuration: No such file or directory (os error 2)`,
see Pitfalls below.

## Architecture (read when debugging)

```
Claude Code (this session)
  └── Bash tool
       └── node codex-companion.mjs review --cwd <WT>
             │
             ├─(spawns, detached)─► app-server-broker.mjs  (per-worktree)
             │                           │
             │                           └─(spawns)─► codex app-server
             │                                             │
             │                                             └─ Runs review turn
             │                                                (reads diff, asks model)
             │
             └─(short-lived; registers job, exits)
```

State:

- Worktree: `/tmp/claude/codex-review/pr-<N>` (detached HEAD at PR head)
- Plugin state: `~/.claude/plugins/data/codex-openai-codex/state/<slug>-<hash>/`
  - `broker.json` — endpoint, PID, logFile of current broker
  - `jobs/<jobId>.json` — status of each review (running | completed | failed)
  - `jobs/<jobId>.log` — live companion stream
- Broker socket: `$TMPDIR/cxc-*/broker.sock`

`<slug>-<hash>` is derived from the worktree path; each worktree has its
own state dir, its own broker, its own socket. That's what makes parallel
reviews work.

## Known pitfalls (the ones that bit us)

### 1. Stale `broker.json` wedges the companion

**Symptom:** job status `failed`, `errorMessage: "failed to load configuration: No such file or directory (os error 2)"`, `broker.log` empty (0 bytes).

**Cause:** a previous broker died but its `broker.json` survived, pointing
at a dead Unix socket. The companion happily reuses it, every RPC fails.

**Fix (built into skill step 5):**

```bash
pkill -f "app-server-broker\.mjs.*--cwd ${WT_REAL}( |$)" 2>/dev/null || true
find ~/.claude/plugins/data/codex-openai-codex/state -maxdepth 2 -type f \
  -name broker.json -path "*/pr-<N>-*" -delete 2>/dev/null || true
```

### 2. `/tmp` vs `/private/tmp` symlink

**Symptom:** scoped `pkill` doesn't match its target broker; later runs
fail as in pitfall 1.

**Cause:** macOS `/tmp` is a symlink to `/private/tmp`. Depending on how
the broker was spawned, its argv records one or the other. `pkill -f`
matches text, not canonical paths.

**Fix:** compute `WT_REAL=$(readlink -f "$WT")` once after creating the
worktree, and use `$WT_REAL` both when launching the companion and in the
pkill match pattern.

### 3. Blanket `pkill -f 'app-server-broker\.mjs'` breaks parallel reviews

**Symptom:** starting a second review interrupts a first in-flight review
mid-turn; first one lands in `status: failed`.

**Cause:** the broker process is what actually runs the review. A blanket
pkill kills every broker system-wide.

**Fix:** scope the kill to just this worktree's broker via
`pkill -f "app-server-broker.*--cwd ${WT_REAL}( |$)"`. If you need the
blanket form (to recover from a global "refresh token already used" after
re-running `codex login`), do it manually outside the skill.

### 4. zsh errors on unmatched globs

**Symptom:** `no matches found: ...broker.json` when a workspace has no
state dir yet (first review).

**Cause:** zsh's default `NOMATCH` behavior errors out before `rm` runs.

**Fix:** use `find -delete` rather than `rm -f` with a glob.

### 5. `cd && node ...` bypasses the allowlist

**Symptom:** permission prompt for every review run, even though
`Bash(node /Users/.../plugins/*)` is in the allowlist.

**Cause:** the `&&` chain makes the full command start with `cd`, not
`node`, so the allow pattern doesn't match.

**Fix:** the companion accepts `--cwd <path>`, so pass it as an argument
instead of chaining.

## Troubleshooting table

| Symptom | Likely cause | First thing to check |
|---|---|---|
| `refresh token already used` | Broker cached a stale token after you re-ran `codex login` | `pkill -f 'app-server-broker\.mjs'` (blanket this time), retry |
| `sandbox-exec: Operation not permitted` | `enableWeakerNestedSandbox` missing | Section 3 |
| `permission denied` prompt for `Bash(find *)` etc. | Allowlist not loaded | Restart Claude Code |
| Job stays `running` forever | Broker crashed mid-turn | Check `broker.log` in `~/.claude/plugins/data/codex-openai-codex/state/<slug>/` |
| `failed to load configuration (os error 2)` | Stale `broker.json` | Pitfall 1 |
| Parallel review killed an in-flight one | Blanket pkill | Pitfall 3 |

## Verification checklist

After installing, confirm you can do ALL of:

- [ ] `codex --version` prints a version
- [ ] `codex login` has been run; `~/.codex/auth.json` exists
- [ ] `/codex:setup` in Claude Code reports OK
- [ ] `ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs` finds a file
- [ ] `~/.claude/skills/codex-review/SKILL.md` exists
- [ ] A test invocation ("review PR N") completes within 10 minutes and produces a review in `/codex:result`

If all six pass, you're ready.
