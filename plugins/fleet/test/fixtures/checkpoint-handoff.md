---
generated: <generated>
fleet_home: <fleet_home>
run_id: run_000000000001
previous_terminal: term_000000000001
next_terminal: "term_000000000002"
---
# Fleet handoff

## In flight

| Objective | Task | PR | State | NEXT | Live |
|---|---|---|---|---|---|
| fenced | 1-x | - | approved | rebind: orca orchestration run-use --id run_000000000009 | false |
| obj | 1-api\|v2 | https://github.com/o/r/pull/7 | pr-open | wait worker | true |
| obj | 2-web<br>second line | - | spec-reviewed | await your go | false |
| reviews | o+r+9 | https://github.com/o/r/pull/9 | review | ask review | false |

## Waiting on you

| Objective | Task | PR | NEXT |
|---|---|---|---|
| fenced | 1-x | - | rebind: orca orchestration run-use --id run_000000000009 |
| obj | 2-web<br>second line | - | await your go |
| reviews | o+r+9 | https://github.com/o/r/pull/9 | ask review |

## Terminal binding

run: run_000000000001 (obj)

## Fenced Runs

- `orca orchestration run-use --id run_000000000009` fixes fenced/1-x

## Review cursor

```yaml
C0TEAM: "1759312800.000100"
```
