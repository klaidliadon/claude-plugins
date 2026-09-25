---
name: gh-stack
description: Use when running the gh stack CLI extension on repos where GitHub stacked pull requests are enabled, to create a stack, add layers, sync or cascade-rebase after changes or merges, navigate between layers, or merge a stack. Use instead of raw git branch/rebase and gh pr create/merge for those mechanics.
---

# gh-stack: GitHub-native stacked PRs

`gh stack` (official GitHub CLI extension) manages stacked PRs natively: branch topology, cascade rebases, PR bases, the stack UI on github.com, and atomic bottom-up merges.

**Availability:** public preview, rolling out per-repo. Exit code 9 (or API 404 on `repos/{owner}/{repo}/stacks`) means the repo isn't enabled yet; fall back to manual git branch/rebase and `gh pr` there.

Full manual: `gh stack <cmd> --help` and https://gh.io/stacks. Upstream agent skill: `gh skill preview github/gh-stack gh-stack`.

PR titles, bodies and the merge-order callout: see gh-workflow.

## Rules

| Instead of | Use |
|---|---|
| `git checkout -b <name>` | `gh stack init <name>` (first branch) / `gh stack add <name>` (next layer, from the top) |
| `git rebase` | `gh stack sync` (fetch + cascade-rebase + push + update PRs) |
| `gh pr create` | `gh stack submit --auto` (drafts), then title, body and ready per gh-workflow |
| `gh pr merge` | `gh stack merge --yes [--squash]`; `gh pr merge` does not work on stacked PRs |

## Non-interactive invocation (violating any of these hangs the session)

- `gh stack view --json`: bare `view`/`--short` opens a TUI
- `gh stack submit --auto`: without it, a title/description editor opens. With `--auto`, new PRs are drafts with auto-generated titles; never pass `--open` (it marks every new and existing PR ready for review)
- `gh stack init <name>` / `gh stack add <name>`: always pass branch names
- `gh stack checkout <stack#|pr#|branch>`: never bare `checkout`
- `gh stack merge --yes`
- Never `gh stack modify` or `gh stack switch`: TUI-only; ask the user to run them from a separate terminal
- If `checkout <pr#>` hits a diverged local stack, the resolution prompt is unbypassable: `gh stack unstack --local` first (keeps the GitHub stack), then retry
- One-time setup: `git config rerere.enabled true`; with multiple remotes, set `git config remote.pushDefault origin` (checkout/trunk have no `--remote` flag)

## Workflow

1. `gh stack init <feature>/1-<step>`: first branch off trunk (`--base` for a non-default trunk); or `gh stack init <b1> <b2> <b3>` to adopt existing branches bottom-to-top
2. Commit normally; deliberate `git add`/`git commit` per layer beats the `-Am` shortcut
3. `gh stack add <feature>/2-<step>`: next layer (run from the topmost branch)
4. `gh stack submit --auto`: pushes all branches, creates draft PRs with correct bases, links the stack on GitHub. Then, per PR: set the title and body per gh-workflow (`gh pr edit <n> --title ... --body-file ...`), and mark it ready (`gh pr ready <n>`) only after gh-workflow's review gate passes
5. After amending any layer or after a merge/trunk move: `gh stack sync` (`--prune` deletes local branches of merged PRs)
6. `gh stack merge --yes [pr#|stack#]`: atomic all-or-nothing merge of everything up to and including the target; with a merge queue the stack is queued together and method flags are ignored

Navigation: `gh stack up|down|top|bottom|trunk`, `gh stack checkout <n>`.
Existing PRs made elsewhere (or by other tools): `gh stack link <bottom> ... <top>`.

## Conflicts & exit codes

`sync` restores all branches on conflict; resolve via `gh stack rebase`, fix bottom-up, `--continue` (or `--abort`). Never resolve a higher layer before the one below it.

Exit codes (not in `--help`; from the upstream skill's exit-code table): 3 rebase conflict · 6 branch in multiple stacks (check out a non-shared branch) · 7 rebase in progress · 9 stacked PRs not enabled for repo · 10 interrupted modify session.

## Conventions (this marketplace's owner)

- Branches: `<feature>/<N>-<step>` (e.g. `2-step-login/1-schema`); names are used verbatim, slashes fine
- **One worktree per stack**, not per branch: cascade rebases must check out every branch, and git refuses to rebase a branch checked out in another worktree. Stack worktree: `<repo>/.worktree/<feature>-stack/`
- Repos with their own stack automation (e.g. omsx's `stacked` label + `pr-auto-rebase.yml`): native retargeting overlaps with it; don't mix the two on one stack
