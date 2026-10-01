#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
SKILL="$DIR/skills/fleet-manager/SKILL.md"

assert_contains "$(cat "$SKILL")" 'codex exec --sandbox workspace-write --add-dir <task dir> -C <repo-path> - <'
hits="$(grep -rnE 'dangerously|bypass' "$DIR/skills" "$DIR/prompts")" && fail "sandbox bypass mentioned: $hits"
hits="$(grep -n 'gh pr diff' "$DIR/prompts/adversarial-review.md")" && fail "adversarial prompt fetches the diff: $hits"

hits="$(grep -rniE 'om''sx|api''-gateway|RI''DL' "$DIR" --exclude-dir=.git)" && fail "repo-specific rules in the plugin: $hits"

finish_tests skill
