#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export PATH="$DIR/test/stubs:$PATH"

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")"
export FLEET_HOME="$T/fleet" STUB_LOG="$T/log" STUB_GH_PR="$T/pr.json" STUB_GH_USER="$T/user.json"
echo '{"login":"me"}' >"$STUB_GH_USER"
RR="$DIR/bin/fleet-review-request"
PR=https://github.com/o/app/pull/12

pr_json() {
  printf '{"state":"%s","author":{"login":"%s"},"reviews":%s}' "$1" "$2" "${3:-[]}" >"$STUB_GH_PR"
}
add() {
  OUT="$("$RR" add "#team" "$1" alice https://slack.example/p1 2026-10-01T09:00:00Z 2>&1)"
  RC=$?
}

assert_eq "$("$RR" cursor "#team")" ""
assert_ok "$RR" cursor "#team" 1759312800.000100
assert_ok "$RR" cursor "#other" 1759312000.000001
assert_eq "$("$RR" cursor "#team")" "1759312800.000100"
assert_ok "$RR" cursor "#team" 1759316400.000200
assert_eq "$("$RR" cursor "#team")" "1759316400.000200"
assert_eq "$("$RR" cursor "#other")" "1759312000.000001"

pr_json OPEN bob
add "$PR"
assert_eq "$RC" 0; assert_eq "$OUT" "skip $PR: o/app is not configured for #team"
assert_fail test -e "$FLEET_HOME/reviews"

cat >"$FLEET_HOME/config.yaml" <<'YAML'
review_requests:
  sources:
    - slack: "#team"
      repos: [o/app, o/web]
    - slack: "#other"
      repos: [o/api]
  skip: {authors: [me, dependabot], already_reviewer: true}
YAML
add https://github.com/o/api/pull/1
assert_eq "$OUT" "skip https://github.com/o/api/pull/1: o/api is not configured for #team"
add https://github.com/o/app/issues/12
assert_eq "$RC" 2; assert_contains "$OUT" "not a PR URL"
pr_json MERGED bob; add "$PR"
assert_eq "$OUT" "skip $PR: PR is MERGED"
pr_json OPEN dependabot; add "$PR"
assert_eq "$OUT" "skip $PR: author dependabot is skipped"
pr_json OPEN bob '[{"author":{"login":"me"},"state":"COMMENTED"}]'; add "$PR"
assert_eq "$OUT" "skip $PR: me already reviewed it"
assert_fail test -e "$FLEET_HOME/reviews/app-12"

pr_json OPEN bob '[{"author":{"login":"carol"},"state":"APPROVED"}]'; add "$PR"
assert_eq "$RC" 0; assert_eq "$OUT" "created $FLEET_HOME/reviews/app-12/spec.md"
S="$FLEET_HOME/reviews/app-12/spec.md"
assert_eq "$(yq --front-matter=extract -o=json -I=0 '.' "$S")" \
  '{"objective":"reviews","task":"app-12","kind":"review","pr":"'"$PR"'","repo":"app","requested_by":"alice","request_link":"https://slack.example/p1","asked_at":"2026-10-01T09:00:00Z","answer":null,"session":{"task_id":null,"dispatch_id":null,"terminal":null,"worktree_path":null}}'
assert_contains "$(cat "$FLEET_HOME/ledger.md")" "review-request $PR from alice"

: >"$STUB_LOG"
add "$PR"
assert_eq "$RC" 0; assert_eq "$OUT" "skip $PR: already tracked in $S"
assert_not_contains "$(cat "$STUB_LOG")" "gh pr view"
yq --front-matter=process -i '.answer = "no" | .cleaned_at = "2026-10-02T00:00:00Z"' "$S"
add "$PR"
assert_eq "$OUT" "skip $PR: already tracked in $S"

yq -i '.review_requests.skip.already_reviewer = false' "$FLEET_HOME/config.yaml"
pr_json OPEN bob '[{"author":{"login":"me"},"state":"COMMENTED"}]'; add https://github.com/o/web/pull/3
assert_eq "$OUT" "created $FLEET_HOME/reviews/web-3/spec.md"

mkdir -p "$FLEET_HOME/reviews/web-4"
pr_json OPEN bob; add https://github.com/o2/web/pull/4
assert_contains "$OUT" "o2/web is not configured"
yq -i '.review_requests.sources[0].repos += ["o2/web"]' "$FLEET_HOME/config.yaml"
printf -- '---\npr: https://github.com/o/web/pull/4\n---\n' >"$FLEET_HOME/reviews/web-4/spec.md"
add https://github.com/o2/web/pull/4
assert_eq "$RC" 1; assert_contains "$OUT" "reviews/web-4 exists for another PR"

finish_tests review-request
