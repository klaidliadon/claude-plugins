# Setup Guide: Codex Review Skill

This guide walks through installing everything needed to run the `codex-review` skill end-to-end. The skill asks Codex (via the OpenAI Codex CLI, optionally through its Claude Code plugin) to review code.

## What you get

Three review modes, picked automatically from the prompt:

- **PR mode**: async. Reviews a GitHub PR in a throwaway worktree via the plugin's companion + broker. Tracked by `/codex:status` / `/codex:result`.
- **Files mode**: sync. Reviews specific files in the current repo with `codex exec`. Output returns in-turn.
- **Working tree mode**: sync. Reviews staged/unstaged or branch diff with `codex exec review`. Output returns in-turn.

The plugin + broker prerequisites below apply only to **PR mode**. Files and working-tree modes need nothing beyond the `codex` CLI itself and the sandbox settings in §3.

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

This should report "Codex CLI is ready." If it complains about missing runtime support, re-run `codex login` or upgrade `@openai/codex`.

## 3. Configure Claude Code sandbox (`~/.claude/settings.json`)

Merge these into your existing `sandbox` block; don't replace:

```json
{
  "sandbox": {
    "enabled": true,
    "enableWeakerNestedSandbox": true,
    "excludedCommands": ["codex"],
    "filesystem": {
      "allowRead":  ["~/.ssh"],
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

- `enableWeakerNestedSandbox: true`: Codex uses `sandbox-exec` internally for its own tool runs. Nested inside Claude Code's sandbox that fails with "sandbox_apply: Operation not permitted" unless this is on. Without it, Codex also reports an empty review ("could not inspect the patch").
- `excludedCommands: ["codex"]`: lets `codex` itself run outside the sandbox, so its own sandboxing works.
- `filesystem.allowWrite: ~/.codex`: Codex writes session logs and `config.toml` overrides. Reads of `~/.codex` (e.g. `auth.json`) need no entry, since the sandbox only restricts reads of paths you deny.
- `filesystem.allowRead: ~/.ssh`: only needed if `~/.ssh` is in your read deny list and your `origin` remote uses SSH, so the PR-mode `git fetch` can authenticate.
- `network.allowedDomains`: the three hosts the CLI uses for API + auth.

**Changes apply on Claude Code restart.** Settings aren't hot-reloaded.

## 4. Add allowlist entries

Append to `permissions.allow` in `~/.claude/settings.json`:

```json
[
  "Bash(gh pr view *)",
  "Bash(git rev-parse --show-toplevel)",
  "Bash(git -C * fetch origin *)",
  "Bash(git -C * worktree add --detach *)",
  "Bash(git -C * worktree remove *)",
  "Bash(git -C * symbolic-ref --short refs/remotes/origin/HEAD)",
  "Bash(git -C * diff *)",
  "Bash(git -C * branch --show-current)",
  "Bash(node ~/.claude/plugins/*)",
  "Bash(ls *)",
  "Bash(jq *)",
  "Bash(mkdir -p *)",
  "Bash(find ~/.claude/plugins/data/codex-openai-codex/state *)",
  "Bash(pkill -f \"app-server-broker*)"
]
```

Each `gh` and `git` entry matches one command shape SKILL.md runs, and nothing broader: no `git push`, no `gh pr merge`. The `find` and `pkill` entries likewise match exactly the §1.5 broker cleanup commands. Without them you'll get permission prompts mid-run. If you edit SKILL.md to run a new `gh` or `git` shape, add its entry here.

Skip the `cd && node` anti-pattern: the skill invokes the companion with `--cwd "$WT_REAL"` so the command matches your `Bash(node ~/.claude/plugins/*)` entry atomically.

## 5. Install the skill

The skill ships as the `codex-review` plugin in the `klaidliadon` marketplace. Inside Claude Code:

```
/plugin marketplace add klaidliadon/claude-plugins
/plugin install codex-review@klaidliadon
```

Restart Claude Code. In a new session, ask:

> codex review PR 42

or similar; the skill triggers only on prompts that name Codex. A bare "review PR 42" goes to the built-in code-review skill.

## 6. Smoke test

Pick a small open PR in a repo you have local:

```
codex review PR <N>
```

Expected flow:

1. Claude fetches PR metadata, creates a worktree at `/tmp/claude/codex-review/<repo-slug>-pr-<N>`.
2. Cleans up any stale `broker.json` for this worktree.
3. Launches `codex-companion.mjs review --background`.
4. Reports back: "review started, poll with `/codex:status`."
5. Result available via `/codex:result` when the turn completes (typically 2 to 8 min for real PRs).

If the first run fails with `failed to load configuration: No such file or directory (os error 2)`, see Pitfalls below.

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

- Worktree: `/tmp/claude/codex-review/<repo-slug>-pr-<N>` (detached HEAD at PR head)
- Plugin state: `~/.claude/plugins/data/codex-openai-codex/state/<slug>-<hash>/`
  - `broker.json`: endpoint, PID, logFile of current broker
  - `jobs/<jobId>.json`: status of each review (running | completed | failed)
  - `jobs/<jobId>.log`: live companion stream
- Broker socket: `$TMPDIR/cxc-*/broker.sock`

`<slug>` is the worktree basename and `<hash>` is a sha256 of its full path; each worktree has its own state dir, its own broker, its own socket. That's what makes parallel reviews work, and why the worktree basename carries the repo slug: the §1.5 cleanup matches on the basename.

## Known pitfalls (the ones that bit us)

### 1. Stale `broker.json` wedges the companion

**Symptom:** job status `failed`, `errorMessage: "failed to load configuration: No such file or directory (os error 2)"`, `broker.log` empty (0 bytes).

**Cause:** a previous broker died but its `broker.json` survived, pointing at a dead Unix socket. The companion happily reuses it, every RPC fails.

**Fix (built into SKILL.md §1.5):**

```bash
pkill -f "app-server-broker\.mjs.*--cwd ${WT_REAL}( |$)" 2>/dev/null || true
find ~/.claude/plugins/data/codex-openai-codex/state -maxdepth 2 -type f \
  -name broker.json -path "*/${REPO_SLUG}-pr-<N>-*" -delete 2>/dev/null || true
```

### 2. `/tmp` vs `/private/tmp` symlink

**Symptom:** scoped `pkill` doesn't match its target broker; later runs fail as in pitfall 1.

**Cause:** macOS `/tmp` is a symlink to `/private/tmp`. Depending on how the broker was spawned, its argv records one or the other. `pkill -f` matches text, not canonical paths.

**Fix:** compute `WT_REAL=$(readlink -f "$WT")` once after creating the worktree, and use `$WT_REAL` both when launching the companion and in the pkill match pattern.

### 3. Blanket `pkill -f 'app-server-broker\.mjs'` breaks parallel reviews

**Symptom:** starting a second review interrupts a first in-flight review mid-turn; first one lands in `status: failed`.

**Cause:** the broker process is what actually runs the review. A blanket pkill kills every broker system-wide.

**Fix:** scope the kill to just this worktree's broker via `pkill -f "app-server-broker.*--cwd ${WT_REAL}( |$)"`. The skill kills this workspace's broker at all because a broker holding an in-memory refresh token becomes unusable once the user re-runs `codex login`. If you need the blanket form (to recover from "refresh token already used" across multiple reviews), run `pkill -f 'app-server-broker\.mjs'` manually outside the skill. Never kill the VSCode ChatGPT extension's `codex app-server`.

### 4. zsh errors on unmatched globs

**Symptom:** `no matches found: ...broker.json` when a workspace has no state dir yet (first review).

**Cause:** zsh's default `NOMATCH` behavior errors out before `rm` runs.

**Fix:** use `find -delete` rather than `rm -f` with a glob.

### 5. `cd && node ...` bypasses the allowlist

**Symptom:** permission prompt for every review run, even though `Bash(node /Users/.../plugins/*)` is in the allowlist.

**Cause:** the `&&` chain makes the full command start with `cd`, not `node`, so the allow pattern doesn't match.

**Fix:** the companion accepts `--cwd <path>`, so pass it as an argument instead of chaining.

### 6. Polling job-state JSON misses the running state

**Symptom:** a hand-written poll loop over `jobs/<jobId>.json` exits immediately while the review is still running.

**Cause:** the job-state JSON is pretty-printed, so `"status": "running"` carries a space. A literal `"status":"running"` grep silently no-matches.

**Fix:** prefer `/codex:status`. If you poll directly, use `grep -E '"status"[[:space:]]*:[[:space:]]*"running"'`, or check `"phase": "done"` for terminal state.

## Troubleshooting table

| Symptom | Likely cause | First thing to check |
|---|---|---|
| `codex: command not found` | Codex CLI not installed | `npm install -g @openai/codex` |
| Codex says it is not authenticated | Login missing or expired | `/codex:setup` |
| Codex reports an empty review ("could not inspect the patch") | `enableWeakerNestedSandbox` missing | Section 3 |
| `refresh token already used` | Broker cached a stale token after you re-ran `codex login` | `pkill -f 'app-server-broker\.mjs'` (blanket this time), retry |
| `sandbox-exec: sandbox_apply: Operation not permitted` | `enableWeakerNestedSandbox` missing | Section 3 |
| Permission prompt for the §1.5 `find` or `pkill` | Allowlist not loaded, or entry shape differs from §4 | Restart Claude Code, then compare with §4 |
| Job stays `running` forever | Broker crashed mid-turn | Check `broker.log` in `~/.claude/plugins/data/codex-openai-codex/state/<slug>/` |
| `failed to load configuration (os error 2)` | Stale `broker.json` | Pitfall 1 |
| Parallel review killed an in-flight one | Blanket pkill | Pitfall 3 |

## Design rationale

- **PR uses a worktree, files and working tree run in place**: PR review must not disturb the user's workspace; files and working-tree review IS the user's workspace.
- **PR async, files and working tree sync**: PR reviews take minutes; files and working-tree reviews finish fast enough to block the turn.
- **Plugin companion for PR, raw `codex exec` for the rest**: keeps PR reviews tracked by `/codex:status` and `/codex:result`; files and working-tree modes don't need that tracking since the user sees the result in-turn.
- **Let Codex read files in files mode**: passing paths beats inlining contents; no token bloat, and Codex reads only what it needs.
- **Review-only, never fix**: if the user wants fixes, that's a separate follow-up ask. Keeps the skill focused.

## Verification checklist

After installing, confirm you can do ALL of:

- [ ] `codex --version` prints a version
- [ ] `codex login` has been run; `~/.codex/auth.json` exists
- [ ] `/codex:setup` in Claude Code reports OK
- [ ] `ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs` finds a file
- [ ] `/plugin` lists `codex-review@klaidliadon` as installed and enabled
- [ ] A test invocation ("codex review PR N") completes within 10 minutes and produces a review in `/codex:result`

If all six pass, you're ready.
