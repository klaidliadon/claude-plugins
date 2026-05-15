---
name: git-cleanup
description: Audit local branches and worktrees against GitHub PR state, auto-clean unambiguously safe branches, prompt on the rest. Conservative, stack-aware via sdf, with `--all` sweep across ~/Workspace and `--dry-run`. Use when user types `/git-cleanup` or asks to audit branches, clean up branches or PRs, prune stale branches, check what branches can be deleted, or tidy a repo.
---

# git-cleanup

Audit local branches and worktrees against GitHub PR state. Auto-clean the unambiguously safe set. Prompt on the ambiguous set. Never touch the current branch, default branch, branches with open or draft PRs, or worktrees with uncommitted changes.

## Modes

| Invocation | Scope | Destructive? |
|---|---|---|
| `/git-cleanup` | Current repo at `$PWD` | Yes (auto-clean + prompted) |
| `/git-cleanup --all` | Every repo under `~/Workspace/<owner>/<repo>` | Yes (auto-clean + prompted, batched) |
| `/git-cleanup --dry-run` | Audit only, prints plan, exits | No |
| `/git-cleanup --all --dry-run` | Audit sweep across `~/Workspace`, prints plan, exits | No |

Conservative posture only. There is no `--aggressive` flag.

## Always-on behavior

Run unconditionally before classification, in this order:

1. `git fetch --prune` (refreshes `[gone]` markers and merge state).
2. `git worktree prune` (clears orphaned `.git/worktrees/<name>` metadata).
3. If `.sdf/` exists at repo root, or `sdf ls` reports stacks, or a PR body contains `<!-- sdf:stack-nav -->`: run `sdf fetch && sdf sync`. On rebase conflict, abort branch cleanup for this repo with the conflict message.

In `--dry-run`, still run `git fetch --prune`, `git worktree prune`, and `sdf fetch` (all read-only-effect). Skip `sdf sync` (rebases) and all destructive actions.

## Classification

For each local branch, evaluate the rules **top-down** and stop at the first match. Action is one of `AUTO`, `PROMPT`, `NEVER`.

**PR match takes precedence over upstream tracking state.** A merged PR proves the work landed on master regardless of where the local branch's upstream points. A closed-not-merged PR proves the work was abandoned, regardless of whether `[gone]` was set on the upstream.

**"PR match" means:** the cached PR list contains a PR whose `headRefName` equals the local branch name **or**, when the local branch's upstream is `[gone]`, equals the gone-upstream's branch name parsed from `git branch -vv` (e.g., for `[origin/api-gateway-v0-envelope: gone]` the candidate name is `api-gateway-v0-envelope`). Match by local name takes precedence; fall back to upstream name. The reason printed cites the matched name, e.g., `PR #917 closed (was tracking origin/api-gateway-v0-envelope)`.

| # | Condition | Action | Reason printed |
|---|---|---|---|
| 1 | Current branch in any worktree | NEVER | current branch |
| 2 | Default branch (`origin/HEAD` target) | NEVER | default branch |
| 3 | Worktree's `git -C <wt> status --porcelain` returns non-empty | NEVER | uncommitted changes in worktree |
| 4 | PR matches by `headRefName` AND PR state is OPEN or DRAFT | NEVER | PR #N open/draft |
| 5 | PR matches AND PR state is MERGED | AUTO local; PROMPT remote-delete if `git ls-remote --heads origin <branch>` returns a ref | PR #N merged |
| 6 | PR matches AND PR state is CLOSED (not merged) | PROMPT | PR #N closed |
| 7 | No PR match (neither local name nor gone-upstream name) AND upstream is `[gone]` | AUTO | upstream gone, no PR |
| 8 | No PR match AND branch has unpushed commits (ahead of own upstream) | PROMPT | N unpushed commits |
| 9 | No PR match AND no upstream (never pushed) | PROMPT | no PR, never pushed |
| 10 | No PR match AND upstream tracks a ref that is not `origin/<this-branch>` | PROMPT | no PR, tracks `<ref>` |

Tie-break: if a branch matches multiple PRs (rare; closed-then-reopened), pick the most recent by `updatedAt`.

Row 5 detail: the remote-delete prompt fires per-branch at the end of the AUTO sweep, batched (see step 9 of the single-repo flow). Probe with `git ls-remote --heads origin <branch>` rather than relying on `git branch -vv` markers, because the local tracking ref may be stale or absent.

### Worktree handling derived from branch classification

- Branch resolves to AUTO delete (or PROMPT accepted): remove its worktree first (`git worktree remove --force <path>`), then `git branch -D <name>`.
- Worktree points to a NEVER branch: leave it.
- Worktree has detached HEAD, missing on-disk path, or already-deleted branch: collect into the stale-worktree prompt batch.

### PR query mechanics

- One `gh pr list --state all --limit 1000 --json number,state,headRefName,updatedAt,url --repo <owner/repo>` per repo. Cache results for the run.
- Do **not** filter by `--author @me`. Match by `headRefName` client-side so co-authored branches are covered.
- If a repo has >1000 PRs and some local branches were not matched in the first pass, fall back to per-branch `gh pr list --head <branch> --state all --json number,state,updatedAt,url` queries.
- If `gh` is unavailable or unauthenticated: degrade to rows 1–3 and 7–10 only (skip rows 4–6, which all depend on PR match). Print one-line notice.

## Single-repo execution flow (`/git-cleanup`)

1. **Preflight.**
   - Verify `$PWD` is a git repo: `git -C "$PWD" rev-parse --is-inside-work-tree`.
   - Capture current branch: `git -C "$PWD" branch --show-current`.
   - Capture default branch: `git -C "$PWD" symbolic-ref refs/remotes/origin/HEAD | sed 's|^refs/remotes/origin/||'`.
   - Capture worktree list: `git -C "$PWD" worktree list --porcelain`. Note which branch each worktree holds.
   - Run `git -C "$PWD" worktree prune`.
2. **Refresh state.** `git -C "$PWD" fetch --prune`.
3. **sdf reconcile** (if sdf detection signals fire). `sdf fetch && sdf sync`. On rebase conflict, abort: print the conflict location and the message `git-cleanup: aborting branch cleanup, resolve the sdf conflict and re-run`.
4. **Enumerate.**
   - `git -C "$PWD" branch -vv` (parse: branch name, ahead/behind counts, `[gone]` marker, current-branch `*`).
   - `git -C "$PWD" worktree list --porcelain` (cross-reference worktree paths).
   - `gh pr list --state all --limit 1000 --json number,state,headRefName,updatedAt,url --repo <owner/repo>` once; cache by `headRefName`.
5. **Classify.** Walk every local branch through the truth table, top-down. Build `{AUTO[], PROMPT[], NEVER[]}` with the reason that fired. For PROMPT branches, bucket by reason: `closed PR`, `unpushed commits`, `no PR, never pushed`, `no PR, tracks <ref>`.
6. **Print the plan.** Always, before executing any destructive action:

   ```
   git-cleanup audit: <repo-name>
   ================================
   AUTO   (N): branch-a [reason]  |  branch-b [reason]  |  ...
   PROMPT (N): branch-c [reason]  |  branch-d [reason]  |  ...
   NEVER  (N): branch-e [reason]  |  branch-f [reason]  |  ...
   ```

7. **Execute AUTO set.** For each AUTO branch, in order:
   - If a worktree holds it: `git -C "$PWD" worktree remove --force <worktree-path>`.
   - Then `git -C "$PWD" branch -D <branch>`.
   - Print one status line per action: `[AUTO] deleted <branch> (and worktree at <path>)`.
8. **Walk PROMPT set, one batch per reason bucket.** For each bucket with N items:
   - Print the bucket header and list each branch with its context.
   - For the "unpushed commits" bucket: show the count and the last commit subject per branch.
   - Ask: `<N> <bucket-reason>: delete all? [y/N/i]ndividual`.
   - `y`: delete all in the bucket (worktree-remove first, then `branch -D`).
   - `N`: skip the entire bucket.
   - `i`: fall through to per-branch `[y/N/s]kip` prompts.
9. **Remote-deletion sub-prompt** (only for branches deleted via row 5 — merged PR — whose `origin/<branch>` still exists). After the main loop:
   - For each row-5 AUTO branch, probe `git ls-remote --heads origin <branch>`. Collect those that return a non-empty result.
   - Ask: `Push-delete <N> merged remote branches on origin? [y/N/i]`.
   - On confirm: `git -C "$PWD" push origin --delete <branch>` per branch.
   - Hard rail: refuse to push-delete if the target is the default branch (defense in depth on row 2).
10. **Stale-worktree sub-prompt.** Collect worktrees with detached HEAD, missing on-disk paths, or already-deleted branches. Ask: `Prune <N> stale worktree paths? [y/N/i]`. On confirm: `git -C "$PWD" worktree remove --force <path>` for paths that exist; `git -C "$PWD" worktree prune` to clean metadata for missing paths.
11. **`sdf prune`** if sdf was detected in this repo.
12. **Final summary.** Print counts: deleted (AUTO), deleted (PROMPT-confirmed), kept (PROMPT-declined), never-touched, errors.

## Dry-run flow (`/git-cleanup --dry-run`)

Behaves like the single-repo flow with these differences:

- Runs `git fetch --prune`, `git worktree prune`, `gh pr list`, and `sdf fetch` (all read-only-effect).
- Does **not** run `sdf sync` (rebases the stack).
- Prints the full plan exactly as in step 6 of the single-repo flow.
- Exits before steps 7–12 with the message:

  ```
  dry-run: nothing changed. Re-run without --dry-run to execute.
  ```

`--dry-run` composes with `--all`.

## Sweep flow (`/git-cleanup --all`)

Walks every directory matching `~/Workspace/<owner>/<repo>` exactly two levels deep.

### Repo discovery

```bash
find ~/Workspace -mindepth 2 -maxdepth 2 -type d
```

For each candidate path:

- Skip if `<path>/.git` does not exist.
- Skip if `<path>/.git` is a file (git submodule checkout).
- Skip `.worktree/` subdirs (handled by their parent repo, never enumerated as a top-level repo).

### Pass 1: silent auto-clean across all repos

For each discovered repo, in sequence:

- Run preflight + fetch + sdf reconcile + classify + execute the AUTO set silently.
- Print one compact line per repo when done: `<repo>: AUTO <n>, PROMPT <n>, NEVER <n>` or `<repo>: skipped (<reason>)`.
- Collect PROMPT items into a global queue, each tagged with `<repo>: <branch> [reason]`.
- Skip-reasons for the compact line: `sdf conflict`, `fetch failed`, `no origin remote`, `gh unavailable`.

### Pass 2: batch-prompt globally, grouped by reason bucket

After Pass 1 completes for all repos, walk the global PROMPT queue once, grouped by reason bucket (not by repo):

- "Across all repos: <N> closed-PR branches, delete all? [y/N/i]"
- "Across all repos: <N> branches with unpushed commits, delete? [y/N/i]"
- "Across all repos: <N> branches with no PR, delete? [y/N/i]"
- "Across all repos: <N> diverged branches, delete? [y/N/i]"
- "Across all repos: <N> non-origin tracked branches, delete? [y/N/i]"

`i` falls through to per-item prompts in the form `<repo>: <branch> [reason], delete? [y/N/s]kip`.

### Pass 3: remote-deletion batch

After all branch deletions across all repos:

- "Across all repos: push-delete <N> merged remote branches on origin? [y/N/i]"

### Pass 4: stale-worktree batch

- "Across all repos: prune <N> stale worktree paths? [y/N/i]"

### Final summary

Print a table grouped by repo:

```
repo            AUTO   PROMPT-yes   PROMPT-no   NEVER   errors
omsx            3      2            1           5       0
webrpc          1      0            0           3       0
...
```

## Output style

- Prefix tags: `[AUTO]`, `[PROMPT]`, `[NEVER]`, `[SKIP]`, `[ERROR]`. No emoji.
- Reasons in brackets after branch name, e.g. `feat-x [PR #918 merged, local == remote]`.
- Single-repo audit print: grouped by action.
- Sweep summary: grouped by repo.
- Prompt responses are case-insensitive: `y` / `n` / `i` / `s`.

## Error handling

| Failure | Behavior |
|---|---|
| Not in a git repo (single mode) | Abort with message |
| `gh` not installed or not authenticated | Degrade to rows 1–3 and 7–10 only (skip rows 4–6, which depend on PR match). One-line notice. |
| `sdf sync` rebase conflict | Single mode: abort. Sweep mode: skip the repo, continue to the next. |
| `git fetch` network failure | Abort (classification depends on fresh state). Single mode: exit. Sweep mode: skip the repo with reason `fetch failed`. |
| Worktree path no longer on disk | Stale-worktree prompt, not an error. |
| Currently inside a worktree on an otherwise-deletable branch | Mark NEVER. Print: `cd to main repo at <path> and re-run to delete <branch>`. |
| Repo with no `origin` remote | Degrade to upstream-only rules; all PR-based rows degrade to PROMPT. |
| `gh pr list` returns >1000 PRs | Fall back to per-branch `gh pr list --head <branch>` for unmatched branches. |

## Hard "never do this" rails

1. Never push-delete a remote branch whose target is the repo's default branch.
2. Never act on a branch that is the current branch in **any** worktree, not just `$PWD`.
3. Never `git branch -D` before removing the worktree pointing at it.
4. Never run `sdf prune` or `sdf sync` in a repo that does not use sdf.
5. Never act in `--all` sweep without classifying first; no "delete first, ask later".

## Out of scope

The skill does **not**:

- Touch tags or stashes.
- Update `TODO.local.md` or `~/TODO.md`.
- Manage non-`origin` remotes beyond classifying their branches as PROMPT.
- Support fork-based PR workflows (where `origin` is a fork and PRs live on upstream). PR matching will miss; affected branches degrade to the no-PR rows (7–10).
- Descend into submodule checkouts during `--all` sweep.

## Stack (sdf) integration: detection signals

Run sdf reconcile when **any** of the following is true for the current repo:

- `<repo>/.sdf/` directory exists.
- `sdf ls` (run from the repo) returns at least one stack.
- Any PR body fetched in step 4 contains the marker `<!-- sdf:stack-nav -->`.
