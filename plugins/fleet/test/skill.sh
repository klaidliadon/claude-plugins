#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
SKILL="$DIR/skills/fleet-manager/SKILL.md"

assert_contains "$(cat "$SKILL")" 'codex exec --sandbox workspace-write --add-dir <task dir> -C <repo-path> - <'
hits="$(grep -rnE 'dangerously|bypass' "$DIR/skills" "$DIR/prompts")" && fail "sandbox bypass mentioned: $hits"
hits="$(grep -n 'gh pr diff' "$DIR/prompts/adversarial-review.md")" && fail "adversarial prompt fetches the diff: $hits"

dispatch="$(grep '^| `dispatch round 1`' "$SKILL")"
session="$(grep -F '4. Look for a task titled `reviews/<task> session`' "$SKILL")"
specreview="$(sed -n '/^4\. For each spec/,/^5\./p' "$SKILL")"
for cmd in "$dispatch" "$session" "$specreview"; do
  assert_contains "$cmd" "git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>"
done
for cmd in "$dispatch" "$session"; do
  assert_contains "$cmd" "--base-branch origin/<base>"
done
assert_contains "$session" "gh pr view <pr> --json baseRefName"
assert_contains "$specreview" "BASE=<base>"
assert_contains "$(grep '^| `done`' "$SKILL")" "learned:"
assert_contains "$(grep '^A consuming' "$SKILL")" "pushed_head"
assert_contains "$(grep '^| `run reviews round' "$SKILL")" "reviewed_head"
assert_contains "$(grep '^| `new commits since review' "$SKILL")" "recorded \`reviewers\` instead of picking them again"
assert_contains "$(grep '^| `start lander`' "$SKILL")" "gh pr merge --match-head-commit <head>"

# The documented fetch must advance origin/<base> even when remote.origin.fetch maps only another branch.
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/up" 2>/dev/null
git -C "$T/up" -c commit.gpgsign=false commit -q --allow-empty -m one
git -C "$T/up" push -q origin HEAD:main HEAD:other 2>/dev/null
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
git -C "$T/repo" config remote.origin.fetch '+refs/heads/other:refs/remotes/origin/other'
git -C "$T/up" -c commit.gpgsign=false commit -q --allow-empty -m two
git -C "$T/up" push -q origin HEAD:main 2>/dev/null
fetch="$(grep -o 'git fetch origin +refs/heads/<base>:refs/remotes/origin/<base>' <<<"$dispatch" | head -1)"
(cd "$T/repo" && eval "${fetch//<base>/main}" 2>/dev/null)
assert_eq "$(git -C "$T/repo" rev-parse origin/main)" "$(git -C "$T/up" rev-parse HEAD)"
# Control: a bare `git fetch origin main` leaves origin/main behind under the same mapping.
git -C "$T/up" -c commit.gpgsign=false commit -q --allow-empty -m three
git -C "$T/up" push -q origin HEAD:main 2>/dev/null
(cd "$T/repo" && git fetch -q origin main 2>/dev/null)
assert_fail test "$(git -C "$T/repo" rev-parse origin/main)" = "$(git -C "$T/up" rev-parse HEAD)"

assert_contains "$(cat "$DIR/agents/fleet-handoff.md")" "yq --front-matter=extract '.' <spec>"
hits="$(grep -nE '(^|[^[:alnum:]_-])sed ' "$SKILL")" && fail "SKILL.md fills with sed: $hits"
for f in "$DIR"/agents/fleet-reviewer-*.md; do
  assert_contains "$(cat "$f")" "Read the saved diff"
  hits="$(grep -n 'gh pr diff <' "$f")" && fail "a reviewer reads the live PR: $hits"
done
assert_contains "$(cat "$DIR/templates/review-session.md")" "never the live PR"
contract="$(grep -F 'filled worker contract. Fill it with' "$SKILL")"
assert_contains "$contract" '<plugin>/bin/fleet-fill <plugin>/templates/worker-contract.md TASK_DIR=<task dir> ROUND=<N> ROUND_INPUT='
assert_contains "$(grep '^| `start fix round <N>` ' "$SKILL")" "fleet-fill"
assert_contains "$(grep -F 'Before any `worker-start` for a review session' "$SKILL")" 'titled `reviews/<task> session`'
assert_contains "$session" 'adopt it'
for row in '^| `wait review session`' '^| `done`'; do
  assert_contains "$(grep "$row" "$SKILL")" 'If `session.task_id` is set and `session.reacted_start` is not, add the `start` reaction'
done
assert_contains "$(grep '^5\. Run `<plugin>/bin/fleet-review-request run`' "$SKILL")" '$FLEET_HOME/reviews/.run.lock'
reviews_row="$(grep '^| `run reviews round' "$SKILL")"
assert_contains "$reviews_row" 'pr_snapshot <pr> <task dir>/round-<N>.diff'
assert_contains "$reviews_row" "before starting any reviewer, so a crash keeps them for re-review"
assert_contains "$(grep '^| `new commits since review' "$SKILL")" "+refs/pull/<n>/head"
assert_contains "$(grep '^| `new commits since review' "$SKILL")" "git range-diff"
assert_contains "$(grep '^| `rerun failed job' "$SKILL")" "gh run rerun <run> --failed"
rerun_row="$(grep '^| `rerun failed job' "$SKILL")"
assert_contains "$rerun_row" 'write `ci_rerun_pending: {head: <headRefOid>, run: <run>, attempt:'
for term in 'started_at: <now, UTC ISO 8601>}`, then run `gh run rerun <run> --failed`' \
  'never run `gh run rerun` again' 'wait and recheck that run on a later turn' \
  'until `FLEET_RERUN_WAIT_MIN` minutes (default 15) past `started_at`, then stop' \
  '`gh run view` fails' 'its JSON has no `attempt`' 'the entry has no `started_at` (fleet 0.2.2 wrote it; treat it as timed out)' \
  'keep `ci_rerun_pending`, run nothing else, and tell the user `ci rerun uncertain for <pr>: <reason>`' \
  'Last, once the attempt has advanced, set `ci_rerun` to the head and delete `ci_rerun_pending`'; do
  assert_contains "$rerun_row" "$term"
done
state_rule="$(sed -n '/^## State rule/,/^## /p' "$SKILL")"
for term in '`<diff-path>.snap.<head>`' 'pointing the `<diff-path>.snap` symlink at it with one rename' \
  '`<diff-path>` and `<diff-path>.names` are fixed symlinks into `<diff-path>.snap/`' \
  'a reader never sees a diff from one capture and names from another'; do
  assert_contains "$state_rule" "$term"
done
assert_contains "$reviews_row" 'run `pr_snapshot` again and record the head it prints'
step5="$(grep '^5\. Run `<plugin>/bin/fleet-review-request run`' "$SKILL")"
assert_contains "$step5" '`run-list returned 500 Runs; it may be truncated, not creating a Run`'
assert_contains "$(cat "$SKILL")" 'It also keeps running when it prints `fleet-watch: config.yaml invalid`'
MAINT="$(cat "$DIR/MAINTENANCE.md")"
for term in 'its `--cursor` is a line cursor that returns only new output, not a next page' \
  'when the list holds 500 Runs and none matches `reviews <FLEET_HOME>`, `run` exits 1' \
  '`<diff-path>.snap.<head>` with `diff`, `names` and `head`, behind the `<diff-path>.snap` symlink' \
  'GNU `mv -T`, else BSD `mv -h`' '`FLEET_RERUN_WAIT_MIN` minutes, default 15' \
  'reaches the `.run.lock` timeout without waiting: a `date` stub'; do
  assert_contains "$MAINT" "$term"
done
fill_step="$(grep -F '3. Snapshot the PR before anything reads it' "$SKILL")"
assert_contains "$fill_step" 'pr_snapshot <pr> <spec dir>/round-1.diff'
assert_contains "$fill_step" 'fleet_reviewers <repo-path> <pr> <spec dir>/round-1.diff'
assert_contains "$fill_step" 'DIFF_PATH=<spec dir>/round-1.diff HEAD=<session.reviewed_head>'
assert_contains "$(grep '^| `restart round <N> (fresh agent)`' "$SKILL")" "filled contract"
assert_contains "$(cat "$SKILL")" '(Orca answers "capability is revoked") is acked and not recorded'
assert_contains "$(cat "$SKILL")" "re-arm it on the user's next message, never on a timer"
assert_contains "$(cat "$SKILL")" "The watch exits on idle only when no source is configured"
assert_contains "$(cat "$SKILL")" 'With sources it keeps running, and a `slack: check` is the wake.'
requests="$(sed -n '/^## Review requests/,/^## /p' "$SKILL")"
for term in slack_read_channel oldest= next_cursor latest_reply thread_lookback_days slack_read_thread; do
  assert_contains "$requests" "$term"
done
read_step="$(sed -n '/^2\./,/^3\./p' <<<"$requests" | sed '$d')"
assert_contains "$read_step" "slack_read_channel"
assert_contains "$read_step" "latest_reply"
assert_contains "$read_step" "A parent older than the look-back window is never read"
assert_contains "$requests" "Any failed call leaves the cursor unchanged."
hits="$(grep -niE 'search|slack_search' <<<"$read_step")" && fail "step 2 of Review requests searches: $hits"
assert_contains "$(cat "$SKILL")" '`{globs: [...], grep: [...]}`'

hits="$(grep -rniE 'om''sx|api''-gateway|RI''DL' "$DIR" --exclude-dir=.git)" && fail "repo-specific rules in the plugin: $hits"

finish_tests skill
