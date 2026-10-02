# Maintaining fleet

## Starting the manager

Open an Orca terminal in any primary checkout and run `FLEET_MANAGER=1 claude`. The SessionStart hook prints the fleet table only when `FLEET_MANAGER=1`, so other sessions are unaffected.

## State

`${FLEET_HOME:-~/Workspace/.fleet}` holds `ledger.md` and one directory per objective: `run.id`, `decisions.md`, and one directory per task with `spec.md`, `spec-review.md`, `review-<round>-<reviewer>.md` and `ci-<round>.log`. `config.yaml` (optional) holds the adversarial reviewer choice and the Slack review-request sources; `review-requests.cursor` holds the newest parent ts read per source, keyed by the source's Slack channel ID (`sources[].slack` is an ID such as `C0123ABCD`, never a channel name). A cursor stored under an old channel name is ignored, so the first check after migrating a source to its ID looks back one `interval_min`. `review_requests.thread_lookback_days`, default 7, bounds how far back a check looks for new replies under older messages; `reviews/<owner>+<repo>+<n>/spec.md` is one review request, under the `reviews` objective with its own `run.id`. `fleet-review-request` serializes on mkdir locks under `reviews/` (`.lock-<task>` per request, `.run.lock` for the Run) and takes over a lock older than `FLEET_LOCK_TTL` seconds, default 300.

Each repo may commit `.agents/fleet.yaml` with its review skill, reviewer globs, reviewer focus text and worktree cleanup hook. A user can instead keep a personal copy at `$FLEET_HOME/repos/<owner>/<repo>.yaml`, which is never committed. `fleet_repo_config` reads `<owner>/<repo>` from the repo's `origin` remote and uses the personal file when it exists, else the committed one; the first found wins and the two are never merged. The personal file is keyed by owner and repo only, so two hosts with the same `<owner>/<repo>` share one. Without either, a PR gets `adversarial` and `tests` only and cleanup runs no hook. Orca holds Runs, Tasks and Dispatches. The spec frontmatter's `orca:` list is the join between them.

## Memory

Worktrees share the primary checkout's auto memory natively: Claude Code keys it by git repository ([docs](https://code.claude.com/docs/en/memory)). Workers must not write it (worker contract rule 9); they report `learned:` lines and the manager keeps what is durable. If Claude Code ever stops sharing memory across worktrees, check that page for `autoMemoryDirectory` before adding a link.

## Tests

`/opt/homebrew/bin/bash plugins/fleet/test/run.sh`. Tests stub `gh` and `orca` on `PATH` and never touch real state: `test/testlib.sh` points `FLEET_HOME` at a fresh `mktemp -d` and aborts the test when `mktemp` fails or prints nothing, since the scripts would otherwise fall back to `~/Workspace/.fleet`. A new test sources `testlib.sh` first and is listed in `test/run.sh`. Orca fixtures under `test/fixtures/orca/` were recorded from Orca 1.4.211; re-record them when Orca's JSON changes.

## Rule

Every `next` string `bin/derive.jq` can emit needs a row in the `fleet-manager` skill's action table.

## Review requests: manual dry run

The Slack steps run through MCP tools inside the manager, so the tests cover only `fleet-review-request` and the `kind: review` states. After changing the "Review requests" section of the skill, dry-run it against a scratch `FLEET_HOME`:

1. `FLEET_HOME="$(mktemp -d)" && [ -d "$FLEET_HOME" ] && export FLEET_HOME`. If that fails, stop: never fall back to `~/Workspace/.fleet`, which holds the real fleet. Then write a `config.yaml` with one source you can post to, by channel ID, and one repo.
2. Start the manager with that `FLEET_HOME`. Post a review request with a PR link from the configured repo, one from an unconfigured repo, and one for a PR by a skipped author.
3. Wait for `slack: check`. Only the first request gets `created`; the others print `skip` with the right reason.
4. Check `review-requests.cursor` holds the newest parent ts for the source, and that a second `slack: check` creates nothing. Check that the channel read took more than one page; if the channel is too small, force it with a small `limit` on `slack_read_channel`.
5. Reply with a PR link under a request posted before the cursor. The next check picks the reply up through `slack_read_thread`.
6. Force one thread read to fail, for example with a wrong `message_ts`, and check the cursor is unchanged after that check.
7. Post the same PR link again: `fleet-review-request` reports it as already tracked.
8. Answer the single aggregated question with `later` and check `fleet-status` shows `skipped` and the manager never asks again.
9. Repeat with a new PR and answer `yes`: the manager starts one session on a fresh worktree with `--setup skip`, records `session`, and `fleet-status` moves through `wait review session` to `done` after the session's `worker_done`.
10. Check that before that `worker-start` the manager read `<base>` from `gh pr view <pr> --json baseRefName`, ran `git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>` in the primary checkout, and passed `--base-branch origin/<base>`.
11. With `review_requests.reactions: {start: eyes, done: white_check_mark}` set, check the request message gets 👀 when the session starts and ✅ after its `worker_done`. Re-run the `done` action and check it adds nothing twice. Remove `reactions` and check a new session adds none.
12. Write `$FLEET_HOME/repos/<owner>/<repo>.yaml` for the configured repo with a `review_skill` that differs from the repo's committed `.agents/fleet.yaml`, start another session, and check its filled spec names the personal `review_skill`. Remove the personal file and check the next session names the committed one.
13. Remove the scratch worktree and `FLEET_HOME`.
