# Maintaining fleet

## Starting the manager

Open an Orca terminal in the omsx primary checkout and run `FLEET_MANAGER=1 claude`. The SessionStart hook prints the fleet table only when `FLEET_MANAGER=1`, so other sessions are unaffected.

## State

`${FLEET_HOME:-~/Workspace/.fleet}` holds `ledger.md` and one directory per objective: `run.id`, `decisions.md`, and one directory per task with `spec.md`, `spec-review.md`, `review-<round>-<reviewer>.md` and `ci-<round>.log`. Orca holds Runs, Tasks and Dispatches. The spec frontmatter's `orca:` list is the join between them.

## Tests

`/opt/homebrew/bin/bash plugins/fleet/test/run.sh`. Tests stub `gh` and `orca` on `PATH` and never touch real state. Orca fixtures under `test/fixtures/orca/` were recorded from Orca 1.4.211; re-record them when Orca's JSON changes.

## Rule

Every `next` string `bin/derive.jq` can emit needs a row in the `fleet-manager` skill's action table.
