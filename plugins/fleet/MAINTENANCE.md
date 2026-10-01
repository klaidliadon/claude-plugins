# Maintaining fleet

## Starting the manager

Open an Orca terminal in any primary checkout and run `FLEET_MANAGER=1 claude`. The SessionStart hook prints the fleet table only when `FLEET_MANAGER=1`, so other sessions are unaffected.

## State

`${FLEET_HOME:-~/Workspace/.fleet}` holds `ledger.md` and one directory per objective: `run.id`, `decisions.md`, and one directory per task with `spec.md`, `spec-review.md`, `review-<round>-<reviewer>.md` and `ci-<round>.log`. `config.yaml` (optional) holds the adversarial reviewer choice and the Slack review-request sources; `review-requests.cursor` holds the last Slack ts checked per source; `reviews/<owner>-<repo>-<n>/spec.md` is one review request, under the `reviews` objective with its own `run.id`.

Each repo may commit `.agents/fleet.yaml` with its review skill, reviewer globs, reviewer focus text and worktree cleanup hook. Without it, a PR gets `adversarial` and `tests` only and cleanup runs no hook. Orca holds Runs, Tasks and Dispatches. The spec frontmatter's `orca:` list is the join between them.

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
8. Remove the scratch worktree and `FLEET_HOME`.
