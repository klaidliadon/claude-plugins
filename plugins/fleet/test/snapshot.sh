#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/test/testlib.sh"
export PATH="$DIR/test/stubs:$PATH"
source "$DIR/bin/lib.sh"
export STUB_LOG="$T/log" STUB_GH_QUEUE="$T/queue"
PR=https://github.com/o/r/pull/7
for h in aaa bbb ccc; do echo "{\"headRefOid\":\"$h\"}" >"$T/head-$h.json"; echo "diff at $h" >"$T/diff-$h"; echo "path-$h.go" >"$T/names-$h"; done
S="$T/s" D="$T/s/round.diff"
mkdir -p "$S"
queue() { printf "$T/%s\n" "$@" >"$STUB_GH_QUEUE"; }
# fingerprint lists every path under the task directory with its link target or content.
fingerprint() {
  (cd "$S" && find . | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then echo "$p -> $(readlink "$p")"; elif [ -f "$p" ]; then echo "$p: $(cat "$p")"; else echo "$p/"; fi
  done)
}
# reads_capture asserts both reader paths name the capture at head $1.
reads_capture() {
  assert_eq "$(cat "$D")" "diff at $1"
  assert_eq "$(cat "$D.names")" "path-$1.go"
}

# A first-ever capture that fails leaves nothing behind.
printf '5xx\n' >"$STUB_GH_QUEUE"
assert_fail pr_snapshot "$PR" "$D" 2>/dev/null
assert_eq "$(ls -A "$S")" ""
queue head-aaa.json diff-aaa 5xx
assert_fail pr_snapshot "$PR" "$D" 2>/dev/null
assert_eq "$(ls -A "$S")" ""

queue head-aaa.json diff-aaa names-aaa head-aaa.json
assert_eq "$(pr_snapshot "$PR" "$D")" "aaa"
reads_capture aaa
assert_contains "$(cat "$STUB_LOG")" "gh pr diff $PR --name-only"
assert_eq "$(fingerprint)" "$(printf '%s\n' ./ './round.diff -> round.diff.snap/diff' './round.diff.names -> round.diff.snap/names' \
  './round.diff.snap -> round.diff.snap.aaa' ./round.diff.snap.aaa/ './round.diff.snap.aaa/diff: diff at aaa' \
  './round.diff.snap.aaa/head: aaa' './round.diff.snap.aaa/names: path-aaa.go')"
before="$(fingerprint)"

# Every failed capture leaves the existing snapshot byte-identical and no staging file.
failed() {
  out="$(pr_snapshot "$PR" "$D" 2>&1)"
  assert_eq "$?" 1
  assert_eq "$(fingerprint)" "$before"
  reads_capture aaa
}
queue 5xx; failed
queue head-bbb.json 5xx; failed
queue head-bbb.json diff-bbb 5xx; failed
queue head-bbb.json diff-bbb names-bbb 5xx; failed
queue head-aaa.json diff-bbb names-bbb head-bbb.json head-bbb.json diff-ccc names-ccc head-ccc.json; failed
assert_eq "$out" "pr_snapshot: the head of $PR moved twice during the capture"
# Staging creation, the swap rename and the interruption each get a stub on PATH.
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/mktemp"
chmod +x "$T/bin/mktemp"
queue head-bbb.json diff-bbb names-bbb head-bbb.json
PATH="$T/bin:$PATH" failed
rm "$T/bin/mktemp"
# mv refuses, or kills its caller, when its last argument ends in $STUB_MV_ON.
cat >"$T/bin/mv" <<SH
#!/usr/bin/env bash
case "\${@: -1}" in
  *"\$STUB_MV_ON") [ "\$STUB_MV_KILL" = 1 ] && kill -9 \$PPID; exit 1 ;;
esac
exec $(command -v mv) "\$@"
SH
chmod +x "$T/bin/mv"
queue head-bbb.json diff-bbb names-bbb head-bbb.json
PATH="$T/bin:$PATH" STUB_MV_ON=round.diff.snap.bbb failed
queue head-bbb.json diff-bbb names-bbb head-bbb.json
PATH="$T/bin:$PATH" STUB_MV_ON=round.diff.snap failed
# Killed just before the swap: readers still see the old capture, and the next call clears what the crash left.
queue head-bbb.json diff-bbb names-bbb head-bbb.json
rc="$({ (PATH="$T/bin:$PATH" STUB_MV_ON=round.diff.snap STUB_MV_KILL=1 pr_snapshot "$PR" "$D"); } >/dev/null 2>&1; echo $?)"
assert_eq "$rc" 137
assert_eq "$(readlink "$D.snap")" round.diff.snap.aaa
reads_capture aaa
assert_ok test -n "$(find "$S" -name 'round.diff.stage.*')"

# The head moves between the first read and the diff: the retry captures bbb, and head, diff and names agree.
: >"$STUB_LOG"
queue head-aaa.json diff-bbb names-bbb head-bbb.json head-bbb.json diff-bbb names-bbb head-bbb.json
assert_eq "$(pr_snapshot "$PR" "$D")" "bbb"
reads_capture bbb
assert_eq "$(cat "$D.snap/head")" bbb
assert_eq "$(grep -c 'gh pr diff' "$STUB_LOG")" 4
assert_eq "$(ls -A "$S" | LC_ALL=C sort | tr '\n' ' ')" "round.diff round.diff.names round.diff.snap round.diff.snap.bbb "

# Capturing a head that already has a directory reuses it unchanged.
queue head-bbb.json diff-ccc names-ccc head-bbb.json
assert_eq "$(pr_snapshot "$PR" "$D")" "bbb"
reads_capture bbb
assert_eq "$(ls -A "$S" | LC_ALL=C sort | tr '\n' ' ')" "round.diff round.diff.names round.diff.snap round.diff.snap.bbb "

# A snapshot written as two plain files by an older fleet becomes the symlink layout.
M="$T/m/round.diff"
mkdir -p "$T/m"
echo old >"$M"; echo old.go >"$M.names"
queue head-ccc.json diff-ccc names-ccc head-ccc.json
assert_eq "$(pr_snapshot "$PR" "$M")" "ccc"
assert_eq "$(readlink "$M")" round.diff.snap/diff
assert_eq "$(cat "$M" "$M.names")" $'diff at ccc\npath-ccc.go'
# A failed reader link fails the call; the next call creates it.
N="$T/n/round.diff"
mkdir -p "$T/n"
queue head-ccc.json diff-ccc names-ccc head-ccc.json
out="$(PATH="$T/bin:$PATH" STUB_MV_ON=/n/round.diff pr_snapshot "$PR" "$N" 2>&1)"
assert_eq "$?" 1
assert_fail test -e "$N"
queue head-ccc.json diff-ccc names-ccc head-ccc.json
assert_eq "$(pr_snapshot "$PR" "$N")" "ccc"
assert_eq "$(cat "$N")" "diff at ccc"

finish_tests snapshot
