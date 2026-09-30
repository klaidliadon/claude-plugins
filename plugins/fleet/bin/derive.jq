def workers: [.rounds[]? | select(.kind == "worker")];
def counts($r): (.reviews[($r.round | tostring)] // {});
def reviews_done($r):
  ($r.reviewers // []) as $want | counts($r) as $got
  | ($want | length) > 0 and ($want | all(. as $n | $got | has($n)));
def total($r; $k): [counts($r)[] | .[$k]] | add // 0;
def blocking($r): total($r; "critical") + total($r; "important");
def review_cell($r):
  if $r == null then "-"
  elif (reviews_done($r) | not) then "running"
  else [ (if total($r; "critical") > 0 then "🔴\(total($r; "critical"))" else empty end),
         (if total($r; "important") > 0 then "🟡\(total($r; "important"))" else empty end),
         (if total($r; "suggestion") > 0 then "🟢\(total($r; "suggestion"))" else empty end) ]
       | if length == 0 then "clean" else join(" ") end
  end;
def stale($r): $r.done_at != null and (.now - $r.done_at) > 86400;

. as $t
| (workers | last) as $w
| ([.rounds[]? | select(.kind == "lander")] | last) as $l
| (if $w == null then null
   elif $w.status == "completed" then $w
   else (workers | map(select(.round == $w.round - 1)) | last) end) as $shown
| (if .approved_at == null then
     (if .spec_reviewed then {state: "spec-reviewed", next: "await your go"}
      else {state: "drafted", next: "run spec review"} end)
   elif (.deps_unmerged | length) > 0 then {state: "waiting", next: "blocked on \(.deps_unmerged | join(", ")) merge"}
   elif .pr.state == "MERGED" then {state: "merged", next: "propose cleanup"}
   elif .pr.state == "CLOSED" then {state: "closed", next: "closed unmerged: your call"}
   elif $l != null then
     (if $l.status == "running" then {state: "landing", next: "wait lander"}
      else {state: "landing", next: "lander \($l.status): inspect"} end)
   elif $w == null then {state: "approved", next: "dispatch round 1"}
   elif $w.status == "failed" then {state: "dispatched", next: "round \($w.round) failed: inspect"}
   elif $w.status == "running" then
     {state: (if .pr == null then "dispatched" elif $w.round == 1 then "pr-open" else "fixing" end), next: "wait worker"}
   elif $w.status != "completed" then {state: "dispatched", next: "worker \($w.status): inspect"}
   elif .pr == null then {state: "dispatched", next: "worker done without PR: inspect"}
   elif (reviews_done($w) | not) then {state: "in-review", next: "run reviews round \($w.round)"}
   elif blocking($w) > 0 then
     (if $w.round >= 3 then {state: "in-review", next: "escalate: 3 rounds not clean"}
      else {state: "in-review", next: ("start fix round \($w.round + 1)" + (if stale($w) then " (fresh agent)" else "" end))} end)
   elif .pr.ci == "failure" then
     (if $w.round >= 3 then {state: "in-review", next: "escalate: 3 rounds not clean"}
      else {state: "in-review", next: ("start fix round \($w.round + 1) with CI log" + (if ($w.released // false) or stale($w) then " (fresh agent)" else "" end))} end)
   elif .pr.ci != "success" then {state: "in-review", next: "wait CI"}
   elif ($w.released | not) then {state: "ready", next: "release worker"}
   elif .pr.approved then {state: "ready", next: "start lander"}
   else {state: "ready", next: "needs human approval"} end) as $d
| {
    objective: $t.objective, task: $t.task, repo: $t.repo,
    pr: (if $t.pr == null then "-" else "#\($t.pr.number)" end),
    state: $d.state,
    ci: ({success: "✅", failure: "❌", pending: "⏳"}[$t.pr.ci // "none"] // "-"),
    review: review_cell($shown),
    inbox: (if $t.asks > 0 then "\($t.asks) ask" else "-" end),
    next: (if $t.asks > 0 then "answer question" else $d.next end)
  }
