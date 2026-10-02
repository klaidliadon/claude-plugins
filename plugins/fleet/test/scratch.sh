#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"

# A failing or empty mktemp aborts testlib before any write. Were it to fall through, the cursor write below
# would land in the fallback FLEET_HOME under $HOME.
mkdir -p "$T/bin" "$T/home"
for body in 'exit 1' 'exit 0'; do
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$T/bin/mktemp"
  chmod +x "$T/bin/mktemp"
  out="$(HOME="$T/home" PATH="$T/bin:$PATH" bash -c 'unset FLEET_HOME; source "$1"; "$2" cursor "#t" 1' \
    _ "$DIR/test/testlib.sh" "$DIR/bin/fleet-review-request" 2>&1)"
  assert_eq "$?" 1
  assert_eq "$out" "testlib: mktemp -d failed; refusing to run without a scratch FLEET_HOME"
  assert_eq "$(ls -A "$T/home")" ""
done
# Control: with a working mktemp the same command writes, inside the scratch FLEET_HOME only.
out="$(HOME="$T/home" bash -c 'unset FLEET_HOME; source "$1"; "$2" cursor "#t" 1 && echo "$FLEET_HOME"' \
  _ "$DIR/test/testlib.sh" "$DIR/bin/fleet-review-request")"
assert_eq "$?" 0
assert_ok test -s "$out/review-requests.cursor"
assert_eq "$(ls -A "$T/home")" ""

finish_tests scratch
