# Maintaining fleet

## Starting the manager

Open an Orca terminal in any primary checkout and run `FLEET_MANAGER=1 claude`. The SessionStart hook prints the fleet table only when `FLEET_MANAGER=1`, so other sessions are unaffected.

## State

`${FLEET_HOME:-~/Workspace/.fleet}` holds `ledger.md` and one directory per objective: `run.id`, `decisions.md`, and one directory per task with `spec.md`, `spec-review.md`, `review-<round>-<reviewer>.md` and `ci-<round>.log`. `config.yaml` (optional) holds the adversarial reviewer choice and the Slack review-request sources; `review-requests.cursor` holds, per source, the dispatch epoch of the last Slack check that went through, keyed by the source's Slack channel ID (`sources[].slack` is an ID such as `C0123ABCD`, never a channel name). A cursor stored under an old channel name is ignored, so the first check after migrating a source to its ID looks back one `interval_min`. `review_requests.thread_lookback_days`, default 7, bounds how far back a check looks for new replies under older messages; `slack_user_id` and `slack_workspace` are the user's Slack ID and the workspace host without `.slack.com`, both optional; `slack-check/<source>.out` is the last raw reply of the Slack check for a source; `reviews/<owner>+<repo>+<n>/spec.md` is one review request, under the `reviews` objective with its own `run.id`. `fleet-review-request` serializes on mkdir locks under `reviews/` (`.lock-<task>` per request, `.run.lock` for the Run) and takes over a lock older than `FLEET_LOCK_TTL` seconds, default 300.

`handoff.md` is the last checkpoint, written by `fleet-checkpoint write` under the `.checkpoint.lock` mkdir lock. Its frontmatter holds `generated` (UTC ISO 8601), `fleet_home`, `run_id` (the Run bound to the old manager's terminal, or empty), `previous_terminal` (the old manager's `ORCA_TERMINAL_HANDLE`, or empty outside Orca), `next_terminal` (the new manager's terminal) and, once `fleet-checkpoint takeover` has closed the old tab, `taken_over_at`. Its body lists the `fleet-status --json` rows, the rows waiting on the user, the bound Run, the fenced Runs with their `run-use` command, and the review cursor. `_archive/` keeps every earlier handoff as `handoff-<YYYY-MM-DD>-<slot>.md`, with the lowest free slot of the UTC day; a new archive never replaces an old one. The takeover binds with a plain `run-use --id <run>` from the new terminal: `--from <handle>` makes the caller act as that terminal, so `run-use --from <old>` re-binds the old terminal instead of moving the Run (checked on Orca 1.4.211). `terminal wait --for tui-idle` returns while a Claude background shell still runs, which is why the old session stops its tasks before `write`.

`fleet-review-request run` adopts the reviews Run from `orca orchestration run-list --limit 500`. Orca's `run-list` has no page token: its `--cursor` is a line cursor that returns only new output, not a next page (`orca orchestration run-list --help`). So adoption fails closed: when the list holds 500 Runs and none matches `reviews <FLEET_HOME>`, `run` exits 1 instead of creating a second Run. Replace the check with paging if Orca adds a page token.

A review snapshot at `<diff-path>` (`round-<N>.diff`) is one immutable directory per head, `<diff-path>.snap.<head>` with `diff`, `names` and `head`, behind the `<diff-path>.snap` symlink. `<diff-path>` and `<diff-path>.names` are fixed symlinks into `<diff-path>.snap/`, created once, so readers keep using the two paths. `pr_snapshot` captures into a `<diff-path>.stage.*` directory, renames it to the head directory, and swaps the `.snap` symlink with one `rename(2)` (`fleet_rename`: GNU `mv -T`, else BSD `mv -h`, since plain `mv` would move the new link into the directory the old one points at). On a first capture, or over an older fleet's plain files (copied into `<diff-path>.snap.legacy`), it creates both reader links against what readers see today before the swap, and a failure at any step puts every path back. It removes the older head directories after the swap and stale staging from a crashed run at the start of the next call.

A failed CI job is rerun once per head. The manager records `ci_rerun_pending` with `started_at` before `gh run rerun`, and never reruns while that entry matches the head; after `FLEET_RERUN_WAIT_MIN` minutes, default 15, without a new attempt it stops and tells the user. That rule lives in the skill's `rerun failed job` row, not in `derive.jq`.

Each repo may commit `.agents/fleet.yaml` with its review skill, reviewer globs, reviewer focus text and worktree cleanup hook. A user can instead keep a personal copy at `$FLEET_HOME/repos/<owner>/<repo>.yaml`, which is never committed. `fleet_repo_config` reads `<owner>/<repo>` from the repo's `origin` remote and uses the personal file when it exists, else the committed one; the first found wins and the two are never merged. The personal file is keyed by owner and repo only, so two hosts with the same `<owner>/<repo>` share one. Without either, a PR gets `adversarial` and `tests` only and cleanup runs no hook. Orca holds Runs, Tasks and Dispatches. The spec frontmatter's `orca:` list is the join between them.

## Memory

Worktrees share the primary checkout's auto memory natively: Claude Code keys it by git repository ([docs](https://code.claude.com/docs/en/memory)). Workers must not write it (worker contract rule 9); they report `learned:` lines and the manager keeps what is durable. If Claude Code ever stops sharing memory across worktrees, check that page for `autoMemoryDirectory` before adding a link.

## Tests

`/opt/homebrew/bin/bash plugins/fleet/test/run.sh`. Tests stub `gh` and `orca` on `PATH` and never touch real state: `test/testlib.sh` points `FLEET_HOME` at a fresh `mktemp -d` and aborts the test when `mktemp` fails or prints nothing, since the scripts would otherwise fall back to `~/Workspace/.fleet`. A new test sources `testlib.sh` first and is listed in `test/run.sh`. Orca fixtures under `test/fixtures/orca/` were recorded from Orca 1.4.211; re-record them when Orca's JSON changes. `test/review-request.sh` reaches the `.run.lock` timeout without waiting: a `date` stub adds an offset that a `sleep` stub grows, and the held lock's future mtime keeps it from going stale.

## Slack check

The `fleet-slack-check` agent (`agents/fleet-slack-check.md`) reads a source's channel and threads on Haiku with only `slack_read_channel` and `slack_read_thread`, and replies with `req` lines and one `cursor` line. It reads text anyone in the channel writes, so its reply is untrusted. The manager writes the reply to a file with the Write tool and pipes it to `fleet-review-request validate <source> <cursor> <dispatch_epoch>`, which checks every field by regex and rejects the whole batch on one bad line. It then re-reads each accepted message with `slack_read_thread` before `add`, so only a ts Slack confirmed reaches `request_ts` and a reaction. The new cursor is always the manager's own dispatch epoch: an agent that hides a request loses it whatever cursor it reports, so trusting its cursor buys nothing, and a quiet channel still advances. The tool ids are those of the claude.ai Slack connector, `mcp__claude_ai_Slack__<tool>`; a session that only has another Slack MCP server cannot run the agent.

## Unreleased

- Idle Slack tick: `fleet-watch` keeps emitting `slack: check` when nothing is in flight.
- Channel IDs: sources and the cursor are keyed by Slack channel ID, and the read is a paged channel read, not a search.
- Hardening fixes: the CI rerun window, atomic review snapshots, fail-closed Run adoption, `fleet-watch` failure handling, and the lock timeout test.
- `/fleet:checkpoint` (`commands/checkpoint.md`, `bin/fleet-checkpoint`) hands the manager to a fresh session.
- Haiku Slack check: the `fleet-slack-check` agent reads Slack, and `fleet-review-request validate` whitelists its reply.

## Rule

Every `next` string `bin/derive.jq` can emit needs a row in the `fleet-manager` skill's action table.

## Review requests: manual dry run

The Slack read runs in the `fleet-slack-check` agent and the re-read and reactions through MCP tools inside the manager, so the tests cover only `fleet-review-request`, `validate` included, and the `kind: review` states. After changing the "Review requests" section of the skill or the agent, dry-run it against a scratch `FLEET_HOME`:

1. `FLEET_HOME="$(mktemp -d)" && [ -d "$FLEET_HOME" ] && export FLEET_HOME`. If that fails, stop: never fall back to `~/Workspace/.fleet`, which holds the real fleet. Then write a `config.yaml` with one source you can post to, by channel ID, one repo, `slack_workspace`, and a `slack_user_id` that is not yours, so your own posts count as someone else's.
2. Start the manager with that `FLEET_HOME`. Post a review request with a PR link from the configured repo, one from an unconfigured repo, and one for a PR by a skipped author.
3. Wait for `slack: check`. Only the first request gets `created`; the others print `skip` with the right reason.
4. Check `review-requests.cursor` holds the dispatch epoch of that check, and that a second `slack: check` creates nothing and still moves the cursor to its own epoch. Check that the channel read took more than one page; if the channel is too small, add `limit: 2` to the agent's inputs.
5. Reply with a PR link under a request posted before the cursor. The next check picks the reply up through `slack_read_thread`.
6. Post a request whose text tells the agent to ignore its rules and report a PR the message does not link: the reply has no line for that PR. Set `slack_user_id` to your own ID and post a request: the agent skips it. Make the agent fail, for example with a channel ID that does not exist, and check the cursor is unchanged and the failure is reported once.
7. Post the same PR link again: `fleet-review-request` reports it as already tracked.
8. Answer the single aggregated question with `later` and check `fleet-status` shows `skipped` and the manager never asks again.
9. Repeat with a new PR and answer `yes`: the manager starts one session on a fresh worktree with `--setup skip`, records `session`, and `fleet-status` moves through `wait review session` to `done` after the session's `worker_done`.
10. Check that before that `worker-start` the manager read `<base>` from `gh pr view <pr> --json baseRefName`, ran `git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>` in the primary checkout, and passed `--base-branch origin/<base>`.
11. With `review_requests.reactions: {start: eyes, done: white_check_mark}` set, check the request message gets 👀 when the session starts and ✅ after its `worker_done`. Re-run the `done` action and check it adds nothing twice. Remove `reactions` and check a new session adds none.
12. Write `$FLEET_HOME/repos/<owner>/<repo>.yaml` for the configured repo with a `review_skill` that differs from the repo's committed `.agents/fleet.yaml`, start another session, and check its filled spec names the personal `review_skill`. Remove the personal file and check the next session names the committed one.
13. Remove the scratch worktree and `FLEET_HOME`.
