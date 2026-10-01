#!/usr/bin/env bash
FLEET_HOME="${FLEET_HOME:-$HOME/Workspace/.fleet}"

fm_get() {
  local v
  v="$(yq --front-matter=extract "$2" "$1")"
  [ "$v" = "null" ] && v=""
  printf '%s' "$v"
}

fm_set() {
  yq --front-matter=process -i "$2" "$1"
}

ledger_append() {
  mkdir -p "$FLEET_HOME"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$FLEET_HOME/ledger.md"
}

# yaml_get prints <expr> from <file>, or nothing when the file is missing or the value is null.
yaml_get() {
  local v
  [ -f "$1" ] || return 0
  v="$(yq "$2" "$1")" || return 1
  [ "$v" = "null" ] && v=""
  printf '%s' "$v"
}

fleet_config() {
  yaml_get "$FLEET_HOME/config.yaml" "$1"
}

fleet_focus() {
  yaml_get "$1/.agents/fleet.yaml" ".focus.\"$2\""
}

# glob_re turns a path glob into an anchored regex: ** spans directories, * and ? stay inside one.
GLOB_RE='def glob_re: gsub("(?<c>[.+^${}()|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002")
  | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]") | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*") | "^\(.)$";'

# fleet_reviewers prints adversarial, tests, then every reviewer whose .agents/fleet.yaml globs match the PR diff.
# A new-dir:<glob> entry matches a directory the PR creates: one that matches the glob and does not exist on the base branch.
fleet_reviewers() {
  local cfg="$1/.agents/fleet.yaml" rules files base d added=""
  printf 'adversarial\ntests\n'
  [ -f "$cfg" ] || return 0
  rules="$(yq -o=json -I=0 '.reviewers // {}' "$cfg")" || return 1
  files="$(gh pr diff "$2" --name-only)" || return 1
  files="$(jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$files")"
  if jq -e '[.[][] | select(startswith("new-dir:"))] | length > 0' >/dev/null <<<"$rules"; then
    base="$(gh pr view "$2" --json baseRefName | jq -r .baseRefName)" || return 1
    git -C "$1" fetch -q origin "$base" 2>/dev/null || true
    while IFS= read -r d; do
      git -C "$1" cat-file -e "origin/$base:$d" 2>/dev/null || added+="$d"$'\n'
    done < <(jq -r --argjson files "$files" "$GLOB_RE"'
      [.[][] | select(startswith("new-dir:")) | ltrimstr("new-dir:") | glob_re] as $res
      | [$files[] | split("/") | .[:-1] as $p | range(1; ($p | length) + 1) | $p[:.] | join("/")]
      | unique[] | select(. as $d | any($res[]; . as $r | $d | test($r)))' <<<"$rules")
  fi
  jq -r --argjson files "$files" --argjson added "$(jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$added")" "$GLOB_RE"'
    to_entries[] | select(.key != "adversarial" and .key != "tests")
    | select(any(.value[];
        if startswith("new-dir:") then (ltrimstr("new-dir:") | glob_re) as $r | any($added[]; test($r))
        else glob_re as $r | any($files[]; test($r)) end))
    | .key' <<<"$rules"
}
