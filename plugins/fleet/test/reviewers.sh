#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
source "$DIR/bin/lib.sh"
export PATH="$DIR/test/stubs:$PATH"

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")"
export STUB_LOG="$T/log" STUB_GH_DIFF="$T/diff" STUB_GH_PR="$T/pr.json"
echo '{"baseRefName":"main"}' >"$STUB_GH_PR"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
mkdir -p "$T/repo/apps/billing" "$T/repo/.agents"
touch "$T/repo/apps/billing/main.go"
git -C "$T/repo" add apps
git -C "$T/repo" -c commit.gpgsign=false commit -q -m init
git -C "$T/repo" push -q origin HEAD:main 2>/dev/null
PR=https://github.com/o/r/pull/7

reviewers() {
  printf '%s\n' "$@" >"$STUB_GH_DIFF"
  fleet_reviewers "$T/repo" "$PR" | paste -sd, -
}

assert_eq "$(reviewers apps/billing/rpc/session/login.go)" "adversarial,tests"
assert_not_contains "$(cat "$STUB_LOG" 2>/dev/null)" "gh pr diff"

cat >"$T/repo/.agents/fleet.yaml" <<'YAML'
reviewers:
  security: ["apps/*/rpc/session/**", "**/perms/**", "docs/rbac.md"]
  architecture: ["schema/**", "new-dir:apps/*"]
  adversarial: ["**"]
YAML
assert_eq "$(reviewers README.md)" "adversarial,tests"
assert_eq "$(reviewers apps/billing/rpc/session/login.go)" "adversarial,tests,security"
assert_eq "$(reviewers apps/billing/rpc/sessions/login.go)" "adversarial,tests"
assert_eq "$(reviewers perms/x.go)" "adversarial,tests,security"
assert_eq "$(reviewers pkg/a/perms/x.go)" "adversarial,tests,security"
assert_eq "$(reviewers docs/rbac.md)" "adversarial,tests,security"
assert_eq "$(reviewers docs/rbacXmd)" "adversarial,tests"
assert_eq "$(reviewers schema/x.sql docs/rbac.md)" "adversarial,tests,security,architecture"
assert_eq "$(reviewers apps/billing/new.go)" "adversarial,tests"
assert_eq "$(reviewers apps/payouts/main.go)" "adversarial,tests,architecture"
assert_eq "$(reviewers apps/payouts/rpc/deep/x.go)" "adversarial,tests,architecture"
assert_eq "$(reviewers apps/top.go)" "adversarial,tests"
assert_contains "$(cat "$STUB_LOG")" "gh pr diff $PR --name-only"

printf 'focus:\n  architecture: "Check the gateway."\n' >>"$T/repo/.agents/fleet.yaml"
assert_eq "$(fleet_focus "$T/repo" architecture)" "Check the gateway."
assert_eq "$(fleet_focus "$T/repo" security)" ""
assert_eq "$(fleet_focus "$T/nowhere" architecture)" ""

finish_tests reviewers
