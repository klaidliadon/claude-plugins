#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
SKILL="$DIR/skills/fleet-manager/SKILL.md"

# row_for succeeds when the action table's first cell names <next>.
row_for() {
  awk -F' [|] ' -v want="$1" '/^[|] / { cell = substr($1, 3); if (index(cell, "`" want "`") || cell == want) found = 1 } END { exit !found }' "$SKILL"
}

base='{"objective":"obj","task":"1-api","repo":"app","approved_at":"2026-10-01T10:00:00Z","spec_reviewed":true,"deps_unmerged":[],"rounds":[{"round":1,"kind":"worker","status":"completed","done_at":1759312800,"reviewers":["adversarial"],"released":false}],"reviews":{"1":{"adversarial":{"critical":0,"important":1,"suggestion":0}}},"pr":{"number":3697,"state":"OPEN","ci":"success","approved":false},"asks":0,"now":1759316400,"stall_after":900}'

n="$(jq length "$DIR/test/derive-cases.json")"
for i in $(seq 0 $((n - 1))); do
  c="$(jq -c ".[$i]" "$DIR/test/derive-cases.json")"
  name="$(jq -r .name <<<"$c")"
  got="$(jq -c --argjson base "$base" '$base + .input' <<<"$c" | jq -c -f "$DIR/bin/derive.jq")"
  for k in $(jq -r '.want | keys[]' <<<"$c"); do
    want="$(jq -r ".want.$k" <<<"$c")"
    have="$(jq -r ".$k" <<<"$got")"
    [ "$want" = "$have" ] || fail "$name: $k want '$want' got '$have'"
  done
  raw="$(jq -r .next <<<"$got")"
  next="$(sed -E 's/round [0-9]+/round <N>/; s/^blocked on .* merge$/blocked on <tasks> merge/; s/--id [^ ]+$/--id <run>/' <<<"$raw")"
  row_for "$raw" && next="$raw"
  case "$next" in
    *inspect) row_for 'anything ending in `inspect`' "$SKILL" || fail "$name: SKILL.md has no inspect row" ;;
    *) row_for "$next" || fail "$name: SKILL.md has no action row for '$next'" ;;
  esac
done
finish_tests derive
