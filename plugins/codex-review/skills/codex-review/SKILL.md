---
name: codex-review
description: Run a Codex code review, only when the user names Codex. Three targets. (1) A GitHub PR by number ("codex review PR 511", "async codex review of 42") runs async in a throwaway worktree. (2) Files ("codex review this file", "codex review foo.go bar.go") run sync in the current repo. (3) No target ("codex review", "codex review my changes", "codex review the staged diff") runs sync on the staged, unstaged, or branch diff. A bare "review X" without Codex, or asking Claude itself to review, belongs to the built-in code-review skill. Not for the literal `/review` slash command.
---

# Codex Review

Run Codex against a PR, a set of files, or the local working tree. PR reviews run async in a throwaway worktree and are tracked by the Codex plugin. File and working-tree reviews run sync in the current repo, so you get the output in-turn.

First-time install and sandbox configuration live in [SETUP.md](SETUP.md).

## Mode selection

Pick exactly one mode per invocation. If ambiguous, ask once with `AskUserQuestion`. Every trigger names Codex; a bare "review X" belongs to the built-in code-review skill.

| Trigger | Mode |
|---|---|
| "codex review PR 511", "codex review #234", "async codex review of 42", "what does codex think of PR 123" | **PR** (§1) |
| "codex review this file", "codex review this script", "codex review foo.go", "codex review foo.go bar.go" | **Files** (§2) |
| "codex review" (no target), "codex review my changes", "codex review the staged diff", "codex review the branch" | **Working tree** (§3) |

**"this file/script"**: resolve to the file indicated by `<ide_opened_file>` in the conversation context. If none is open, ask.

**Multiple files**: all resolved paths must be inside the current repo. Reject absolute paths outside `$REPO_ROOT`.

**Adversarial review**: same flow as normal review, but replace `review` with `adversarial-review` in companion calls (PR mode) or prepend an adversarial framing to the prompt (Files/WT modes).

---

## §1. PR mode (async, worktree)

Review a specific GitHub PR with Codex in the background without touching the current working tree. Output is tracked by the Codex plugin; the user polls with `/codex:status` and retrieves with `/codex:result`.

### 1.1 Extract PR number

Parse the integer from the user's prompt. If ambiguous, ask once with `AskUserQuestion`. Do not guess.

### 1.2 Resolve PR metadata

```bash
gh pr view <N> --json number,title,url,baseRefName,headRefOid,state,isDraft
```

Reject early if:
- `state != "OPEN"`: ask the user whether to proceed anyway.
- `headRefOid` is empty: bail with an error.

### 1.3 Resolve plugin path

The codex plugin is versioned under the cache dir; pick the highest version:

```bash
PLUGIN_DIR=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/ 2>/dev/null | sort -V | tail -1)
```

If `$PLUGIN_DIR` is empty, tell the user the codex plugin isn't installed and stop.

### 1.4 Fetch PR head + create isolated worktree

Never touch the user's checked-out branch. Worktrees live under `/tmp/claude/codex-review/`, which is sandbox-writable and outside the repo to avoid macOS write protection on `.vscode/` and similar in-tree dirs. The worktree basename is `<repo-slug>-pr-<N>`: the Codex plugin names its state dir `<basename>-<sha256(path)>`, so the repo slug in the basename keeps same-numbered PRs from different repos apart, both on disk and in the §1.5 cleanup match.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REPO_SLUG=$(basename "$REPO_ROOT")
WT="/tmp/claude/codex-review/${REPO_SLUG}-pr-<N>"
mkdir -p "$(dirname "$WT")"
# Remove any stale worktree from a prior run
git -C "$REPO_ROOT" worktree remove --force "$WT" 2>/dev/null || true
find "$WT" -depth -delete 2>/dev/null || true
# Fetch PR head into a named local remote-tracking ref (avoids FETCH_HEAD
# being overwritten by any subsequent fetch)
git -C "$REPO_ROOT" fetch origin "pull/<N>/head:refs/remotes/origin/pr/<N>"
# Make sure the base ref is up to date so --base <base> works
git -C "$REPO_ROOT" fetch origin "<baseRefName>"
# Detached worktree at the PR head SHA
git -C "$REPO_ROOT" worktree add --detach "$WT" "refs/remotes/origin/pr/<N>"
# On macOS /tmp is a symlink to /private/tmp; resolve once so the same
# absolute path is used everywhere (broker argv, pkill match, companion --cwd).
WT_REAL=$(readlink -f "$WT" 2>/dev/null || echo "$WT")
```

### 1.5 Clear stale Codex broker state (mandatory)

The Codex plugin keeps a per-workspace broker session in `~/.claude/plugins/data/codex-openai-codex/state/<slug>-<hash>/broker.json` pointing at a Unix socket. If that file outlives its broker process (crash, session end, manual kill), the next companion run reuses the dead endpoint and every review fails with `failed to load configuration: No such file or directory (os error 2)`: empty `broker.log`, nothing in stderr, nothing fixable without cleanup.

Kill the broker owned by THIS worktree (not all brokers, which would blow up any concurrent review) and delete its state file:

```bash
# $WT_REAL was set in §1.4; matches how the broker records --cwd in argv.
pkill -f "app-server-broker\.mjs.*--cwd ${WT_REAL}( |$)" 2>/dev/null || true
# `find` over a glob avoids zsh "no matches found" on first-run workspaces
find ~/.claude/plugins/data/codex-openai-codex/state -maxdepth 2 -type f \
  -name broker.json -path "*/${REPO_SLUG}-pr-<N>-*" -delete 2>/dev/null || true
```

Do NOT kill the VSCode ChatGPT extension's `codex app-server`, only the plugin's broker (`app-server-broker.mjs`). Why, and the blanket-kill recovery: [SETUP.md](SETUP.md) pitfall 3.

### 1.6 Launch Codex review in background

From inside the worktree, invoke the plugin's companion script in review mode with `--background`. Claude Code must launch this with `Bash(..., run_in_background: true)`, which is what actually detaches the run. `--background` is forwarded to the companion so it registers the job for `/codex:status`.

```bash
node "$PLUGIN_DIR/scripts/codex-companion.mjs" review --cwd "$WT_REAL" --background --base "origin/<baseRefName>"
```

Use `--cwd` rather than `cd "$WT" && node ...`: the chained form bypasses the `Bash(node ~/.claude/plugins/*)` allow-list entry and triggers a permission prompt.

The background task exits quickly once the review thread is spawned in the broker. The review itself keeps running inside the broker, so track it via `/codex:status` / `/codex:result`, not by waiting on the Bash task.

Polling the job-state JSON directly instead: [SETUP.md](SETUP.md) pitfall 6.

### 1.7 Tell the user and stop

Output exactly:

> Codex review of PR #<N> (<title>) started in the background from `/tmp/claude/codex-review/<repo-slug>-pr-<N>`.
> Progress: `/codex:status`  · Result: `/codex:result`  · Cancel: `/codex:cancel`
> When done, ask me to remove the worktree.

Do NOT:
- Call `BashOutput` or wait for the job in this turn.
- Paraphrase or summarize the review ahead of time.
- Offer fixes; this skill is review-only.

### 1.8 After the review

When the user retrieves the result (`/codex:result`) and is done with it, clean up the worktree on their confirmation:

```bash
git -C "$REPO_ROOT" worktree remove "$WT"
```

---

## §2. Files mode (sync, in-place)

Review one or more specific files in the current repo. Runs foreground, so output returns in-turn.

### 2.1 Resolve target files

- "this file" / "this script" → the file in `<ide_opened_file>`.
- Explicit paths in the prompt → resolve each to an absolute path.
- Reject any path outside `$REPO_ROOT` (`git rev-parse --show-toplevel`).
- `ls` each path to confirm it exists. If any is missing, ask before proceeding.

Put the resolved absolute paths in a `TARGET_PATHS` array for §2.2.

### 2.2 Build the prompt

Let Codex read files from disk; don't inline contents (token bloat).

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
PROMPT_FILE="$REPO_ROOT/.codex/review-prompt.md"
BASE_PROMPT=""
if [[ -f "$PROMPT_FILE" ]]; then
  BASE_PROMPT=$(cat "$PROMPT_FILE")
fi

# List files relative to $REPO_ROOT for readability in output.
REL_PATHS=()
for p in "${TARGET_PATHS[@]}"; do
  REL_PATHS+=("${p#"$REPO_ROOT"/}")
done
FILES_LIST=$(printf '  - %s\n' "${REL_PATHS[@]}")

REVIEW_PROMPT="Review the following files in the current repository. Read each file, then produce a code review focused on correctness, robustness, conventions, and maintainability. Call out anything surprising or risky.

Files:
${FILES_LIST}

${BASE_PROMPT}"
```

### 2.3 Run Codex

**Always redirect stdin from `/dev/null`.** `codex exec` reads the prompt from the arg *and* tries to read additional input from stdin; if stdin is open with no EOF (e.g. the harness auto-detaches the call into the background), it blocks forever on "Reading additional input from stdin..." and never runs. `</dev/null` gives it immediate EOF. The prompt is passed as an arg, so stdin is never needed.

```bash
codex exec -C "$REPO_ROOT" "$REVIEW_PROMPT" </dev/null
```

Stream output to the user as-is. Do not summarize or filter; show the full review. If Codex exits non-zero, report the error verbatim; don't retry silently.

### 2.4 Stop

Do not offer fixes. This skill is review-only. The user can follow up with a separate ask if they want changes applied.

---

## §3. Working tree mode (sync, in-place)

Review pending changes in the current repo. Runs foreground.

### 3.1 Pick the target

Priority: **staged** → **unstaged** → **branch diff vs `origin/<default>`**.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
BASE_REF=$(git -C "$REPO_ROOT" symbolic-ref --short refs/remotes/origin/HEAD)   # e.g. origin/main
DEFAULT_BRANCH="${BASE_REF#origin/}"

if ! git -C "$REPO_ROOT" diff --cached --quiet; then
  TARGET=uncommitted     # staged
elif ! git -C "$REPO_ROOT" diff --quiet; then
  TARGET=uncommitted     # unstaged (--uncommitted covers both)
elif [[ "$(git -C "$REPO_ROOT" branch --show-current)" != "$DEFAULT_BRANCH" ]] \
  && ! git -C "$REPO_ROOT" diff "${BASE_REF}...HEAD" --quiet 2>/dev/null; then
  TARGET=base
else
  echo "Nothing to review."; exit 0
fi
```

If `BASE_REF` is empty (`origin/HEAD` unset), stop and tell the user to run `git remote set-head origin --auto`. Do not guess a branch name.

If the user pointed at a specific commit ("review commit abc123"), use `--commit <sha>` instead.

### 3.2 Build the prompt

```bash
PROMPT_FILE="$REPO_ROOT/.codex/review-prompt.md"
if [[ -f "$PROMPT_FILE" ]]; then
  REVIEW_PROMPT=$(cat "$PROMPT_FILE")
else
  REVIEW_PROMPT="Review the changes. Focus on correctness, robustness, conventions, and anything surprising or risky."
fi
```

### 3.3 Run Codex

`-C` is a flag of `codex exec`, not `codex exec review`, so it must come before `review`. Putting it after fails with "unexpected argument '-C' found".

**Always redirect stdin from `/dev/null`** (see §2.3; prevents `codex exec` blocking forever on "Reading additional input from stdin..." when the call is backgrounded).

```bash
# staged or unstaged
codex exec -C "$REPO_ROOT" review --uncommitted "$REVIEW_PROMPT" </dev/null

# branch diff vs origin default
codex exec -C "$REPO_ROOT" review --base "$BASE_REF" "$REVIEW_PROMPT" </dev/null

# specific commit
codex exec -C "$REPO_ROOT" review --commit "$SHA" "$REVIEW_PROMPT" </dev/null
```

Stream output to the user as-is. Do not summarize or filter.

### 3.4 Stop

Review-only. No fixes.

---

## Error handling

Missing `codex` CLI, auth, and sandbox errors (all modes): [SETUP.md](SETUP.md) troubleshooting table.

### PR mode (§1)
- `gh` not authenticated → tell the user to run `gh auth login`, stop.
- Codex plugin missing → tell the user to run `/plugin install codex@openai-codex`, stop.
- Worktree already exists and is dirty → offer to `git worktree remove --force`.
- Codex result says "refresh token already used" → the plugin broker has a stale in-memory token. The pkill step in §1.5 prevents this; if it still happens, the user may need to run `codex login` again.
- Job record (`~/.claude/plugins/data/codex-openai-codex/state/<slug>-<hash>/jobs/<id>.json`) shows `errorMessage: "failed to load configuration: No such file or directory (os error 2)"` with an empty `broker.log` → stale `broker.json` pointing at a dead socket. The §1.5 cleanup should have prevented this; re-run it and retry.

### Files mode (§2)
- Path outside `$REPO_ROOT` → reject, ask for a path inside the repo.
- Path doesn't exist → ask before guessing.
- Codex returns "could not read file" → the Claude Code sandbox may be restricting Codex's read access. Check `sandbox.filesystem.allowRead` includes the repo root (usually implicit but worth verifying).

### Working tree mode (§3)
- No staged/unstaged changes and on default branch → output "nothing to review", stop.
- `origin/HEAD` unset → tell the user to run `git remote set-head origin --auto`, stop.

---

Why the modes split this way: [SETUP.md](SETUP.md) design rationale.
