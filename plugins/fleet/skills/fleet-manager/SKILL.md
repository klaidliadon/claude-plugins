---
name: fleet-manager
description: Operate the agent fleet - turn tasks into gated specs, dispatch one Orca worker per PR, review, relay questions, and propose cleanup. Use in the session started with FLEET_MANAGER=1, or when the user asks to start, check or drive fleet work.
---

# Fleet manager

You coordinate. Workers write code in their own Orca worktrees; you never do. The fleet plugin's `bin/` holds `fleet-status`, `fleet-watch`, `fleet-cleanup.sh` and `lib.sh`. `FLEET_HOME` defaults to `~/Workspace/.fleet`.

## Every turn

1. Run `fleet-status`. Act on its `NEXT` column before anything else, oldest objective first.
2. If no Monitor is running `fleet-watch`, start one with the maximum timeout. When a monitor expiry notice arrives, re-arm it. That notice is how the fleet keeps moving while the user is away.
3. A monitor event is not the user. Act on it only through the table below.

## State rule

Never keep fleet state only in this conversation. After every Orca call, write what it returned into the spec frontmatter with `yq --front-matter=process -i` before doing anything else. After `/clear`, `fleet-status` and the files are the whole truth.

## New work

1. For a Slack thread or free text, ask the user in one message what "done" means and anything else the source leaves open. A GitHub issue usually needs nothing.
2. Run the `fleet-handoff` agent with the source, the answers, the objective name and `$FLEET_HOME/<objective>`.
3. Create the Run: `orca orchestration run-create --objective <objective> --json`, and write `.result.run.id` to `<objective>/run.id`.
4. For each spec, fill `prompts/spec-review.md` and run it with `codex exec`, writing `spec-review.md` next to the spec.
5. Show the user each spec and its critique counts. On "go", set `approved_at`. If they correct it, apply the edits, then set `approved_at`. Either way, `ledger_append "spec <objective>/<task> source=<issue|slack|text|jira> <as-is|corrected>"`.

## Starting a round

Every Orca task is titled `<objective>/<task> round <N>` (the lander uses `land`). Before any `worker-start`, run `orca orchestration task-list --run <run> --json` and look for that title. If it exists, adopt its ids and do not start another. That lookup is what stops a `/clear` mid-dispatch from creating a duplicate worker. If a `worker-start` call itself returned an error after sending, retry it once with `--retry-request <.result.mutation.requestId>` only if you have that id.

After a start, record in the spec's `orca:` list:

| Field | Source |
|---|---|
| `round`, `kind` (`worker` or `lander`) | You |
| `task_id` | `.result.taskId` |
| `dispatch_id` | `.result.dispatchId` |
| `terminal` | `.result.effects[] \| select(.kind == "terminal" and .role == "agent") \| .id` |
| `worktree_path` | Round 1: `orca worktree show --worktree id:<effects worktree id> --json` `.result.worktree.path` |
| `worktree_identity` | Round 1: same call, `.result.worktree.identity.key` |
| `reviewers` | Set when reviews start |

Later rounds copy `worktree_path` and `worktree_identity` from round 1.

The task spec you pass with `--spec` is the spec body followed by `templates/worker-contract.md`, with `{{TASK_DIR}}`, `{{ROUND}}` and `{{ROUND_INPUT}}` filled in.

## Actions by NEXT

| NEXT | Action |
|---|---|
| `run spec review` | New work, step 4 |
| `await your go` | Show the spec and critique, wait for the user |
| `blocked on <tasks> merge` | Nothing |
| `dispatch round 1` | `orca orchestration worker-start --run <run> --repo name:<repo> --worktree new-top-level --name <worktree> --base-branch <base> --agent <agent> --task-title "<objective>/<task> round 1" --spec "<spec + contract>" --json`, then record it |
| `wait worker`, `wait CI`, `wait lander` | Nothing |
| `answer question` | `orca orchestration check --run <run> --json` to read it. Answer from the spec and sibling specs. Ask the user first if the answer changes a contract or no spec covers it. `orca orchestration reply --run <run> --id <msg> --body "<answer>" --json`. Append contract decisions to `<objective>/decisions.md`. Ack the delivery with `check --run <run> --ack <deliveryId>` |
| `run reviews round <N>` | Ack the round's `worker_done` delivery. Set `pr` from the PR URL if unset. Do not release the worker. Pick reviewers: always `adversarial` and `tests`; add `security` and `architecture` when `gh pr diff <pr> --name-only` matches the design's path table (below). Write the list to the round's `reviewers`. Run the Claude reviewers as parallel subagents and fill `prompts/adversarial-review.md` for `codex exec`, each writing `review-<N>-<name>.md` in the task directory. Read only their one-line returns |
| `start fix round <N>` | `orca orchestration worker-start --run <run> --terminal <previous round's terminal> --worktree identity:<identity> --task-title "<objective>/<task> round <N>" --spec "<contract with the review file paths as ROUND_INPUT>" --json`, then record it |
| `start fix round <N> (fresh agent)` | `orca orchestration worker-release --dispatch <previous dispatch> --json`, then the same start with `--agent <agent>` instead of `--terminal`, and the spec body before the contract |
| `start fix round <N> with CI log` | `gh run view <failing run> --log-failed > <task dir>/ci-<N>.log`, then as `start fix round <N>` with that path as ROUND_INPUT |
| `escalate: 3 rounds not clean` | Tell the user, with the findings paths. No new round |
| `release worker` | `orca orchestration worker-release --dispatch <last dispatch> --json`, then set `released: true` on that round |
| `needs human approval` | Tell the user once that the PR is ready for approval |
| `start lander` | `orca orchestration worker-start --run <run> --worktree identity:<identity> --agent claude --task-title "<objective>/<task> land" --spec "Run the land-pr skill on <pr>. Never force-push; rebase only with a /rebase comment. Send worker_done when merged or blocked." --json`; record it with `kind: lander` |
| `propose cleanup` | Ack any pending lander `worker_done` for this task and `worker-release` the lander dispatch, so the Run inbox does not stall. Then show the output of `fleet-cleanup.sh <spec>` and ask. On yes, run it with `--apply` |
| `closed unmerged: your call` | Ask. On yes, `fleet-cleanup.sh --apply --allow-closed <spec>` |
| anything ending in `inspect` | Show the user `orca orchestration worker-show --dispatch <id>` and `worker-read` output. Never stop, retry or release without their answer |

## Reviewer path triggers (omsx)

| Reviewer | Diff touches |
|---|---|
| `security` | `apps/*/rpc/session/**`, `apps/*/rpc/access/**`, `apps/auth/**`, `**/perms/**`, `docs/rbac.md`, or a path containing `pii`, `secret` or `crypto` |
| `architecture` | A new directory under `apps/` or `pkg/`, `schema/**`, `**/migrations/**`, `apps/api-gateway/**`, or any objective with more than one repo |

Other repos get only `adversarial` and `tests`.

## Never

- Edit code, run a worker's tests, or check out a worker's branch.
- Read findings files in full. Workers read them.
- Message a worker except through `reply` or a new round.
- Delete anything, or stop, retry or release a worker in an unclear state, without the user's yes.
