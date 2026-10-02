#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
SKILL="$DIR/skills/fleet-manager/SKILL.md"

assert_contains "$(cat "$SKILL")" 'codex exec --sandbox workspace-write --add-dir <task dir> -C <repo-path> - <'
hits="$(grep -rnE 'dangerously|bypass' "$DIR/skills" "$DIR/prompts")" && fail "sandbox bypass mentioned: $hits"
hits="$(grep -n 'gh pr diff' "$DIR/prompts/adversarial-review.md")" && fail "adversarial prompt fetches the diff: $hits"

dispatch="$(grep '^| `dispatch round 1`' "$SKILL")"
session="$(grep -F '4. Start it on a fresh worktree' "$SKILL")"
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
T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")" || exit 1
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

hits="$(grep -rniE 'om''sx|api''-gateway|RI''DL' "$DIR" --exclude-dir=.git)" && fail "repo-specific rules in the plugin: $hits"

finish_tests skill
