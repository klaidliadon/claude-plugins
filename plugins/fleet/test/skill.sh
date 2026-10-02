#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
SKILL="$DIR/skills/fleet-manager/SKILL.md"

assert_contains "$(cat "$SKILL")" 'codex exec --sandbox workspace-write --add-dir <task dir> -C <repo-path> - <'
hits="$(grep -rnE 'dangerously|bypass' "$DIR/skills" "$DIR/prompts")" && fail "sandbox bypass mentioned: $hits"
hits="$(grep -n 'gh pr diff' "$DIR/prompts/adversarial-review.md")" && fail "adversarial prompt fetches the diff: $hits"

dispatch="$(grep '^| `dispatch round 1`' "$SKILL")"
session="$(grep -F '4. Start it on a fresh worktree' "$SKILL")"
for cmd in "$dispatch" "$session"; do
  assert_contains "$cmd" "git fetch origin <base>"
  assert_contains "$cmd" "--base-branch origin/<base>"
done
assert_contains "$session" "gh pr view <pr> --json baseRefName"
assert_contains "$(cat "$SKILL")" "BASE=<base>"

hits="$(grep -rniE 'om''sx|api''-gateway|RI''DL' "$DIR" --exclude-dir=.git)" && fail "repo-specific rules in the plugin: $hits"

finish_tests skill
