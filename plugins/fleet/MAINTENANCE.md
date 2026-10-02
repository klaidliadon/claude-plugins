# Maintaining fleet

## Starting the manager

Open an Orca terminal in any primary checkout and run `FLEET_MANAGER=1 claude`. The SessionStart hook prints the fleet table only when `FLEET_MANAGER=1`, so other sessions are unaffected.

## State

`${FLEET_HOME:-~/Workspace/.fleet}` holds `ledger.md` and one directory per objective: `run.id`, `decisions.md`, and one directory per task with `spec.md`, `spec-review.md`, `review-<round>-<reviewer>.md` and `ci-<round>.log`. `config.yaml` (optional) holds the adversarial reviewer choice and the Slack review-request sources; `review-requests.cursor` holds the last Slack ts checked per source; `reviews/<owner>+<repo>+<n>/spec.md` is one review request, under the `reviews` objective with its own `run.id`.

Each repo may commit `.agents/fleet.yaml` with its review skill, reviewer globs, reviewer focus text and worktree cleanup hook. A user can instead keep a personal copy at `$FLEET_HOME/repos/<owner>/<repo>.yaml`, which is never committed. `fleet_repo_config` reads `<owner>/<repo>` from the repo's `origin` remote and uses the personal file when it exists, else the committed one; the first found wins and the two are never merged. The personal file is keyed by owner and repo only, so two hosts with the same `<owner>/<repo>` share one. Without either, a PR gets `adversarial` and `tests` only and cleanup runs no hook. Orca holds Runs, Tasks and Dispatches. The spec frontmatter's `orca:` list is the join between them.

## Memory

Worktrees share the primary checkout's auto memory natively: Claude Code keys it by git repository ([docs](https://code.claude.com/docs/en/memory)). Workers must not write it (worker contract rule 9); they report `learned:` lines and the manager keeps what is durable. If Claude Code ever stops sharing memory across worktrees, check that page for `autoMemoryDirectory` before adding a link.

## Tests

`/opt/homebrew/bin/bash plugins/fleet/test/run.sh`. Tests stub `gh` and `orca` on `PATH` and never touch real state. Orca fixtures under `test/fixtures/orca/` were recorded from Orca 1.4.211; re-record them when Orca's JSON changes.

## Rule

Every `next` string `bin/derive.jq` can emit needs a row in the `fleet-manager` skill's action table.

## Review requests: manual dry run

The Slack steps run through MCP tools inside the manager, so the tests cover only `fleet-review-request` and the `kind: review` states. After changing the "Review requests" section of the skill, dry-run it against a scratch `FLEET_HOME`:

1. `export FLEET_HOME=$(mktemp -d)` and write a `config.yaml` with one source you can post to and one repo.
2. Start the manager with that `FLEET_HOME`. Post a review request with a PR link from the configured repo, one from an unconfigured repo, and one for a PR by a skipped author.
3. Wait for `slack: check`. Only the first request gets `created`; the others print `skip` with the right reason.
4. Check `review-requests.cursor` holds the newest message ts for the source, and that a second `slack: check` creates nothing.
5. Post the same PR link again: `fleet-review-request` reports it as already tracked.
6. Answer the single aggregated question with `later` and check `fleet-status` shows `skipped` and the manager never asks again.
7. Repeat with a new PR and answer `yes`: the manager starts one session on a fresh worktree with `--setup skip`, records `session`, and `fleet-status` moves through `wait review session` to `done` after the session's `worker_done`.
8. Check that before that `worker-start` the manager read `<base>` from `gh pr view <pr> --json baseRefName`, ran `git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>` in the primary checkout, and passed `--base-branch origin/<base>`.
9. With `review_requests.reactions: {start: eyes, done: white_check_mark}` set, check the request message gets 👀 when the session starts and ✅ after its `worker_done`. Re-run the `done` action and check it adds nothing twice. Remove `reactions` and check a new session adds none.
10. Write `$FLEET_HOME/repos/<owner>/<repo>.yaml` for the configured repo with a `review_skill` that differs from the repo's committed `.agents/fleet.yaml`, start another session, and check its filled spec names the personal `review_skill`. Remove the personal file and check the next session names the committed one.
11. Remove the scratch worktree and `FLEET_HOME`.
