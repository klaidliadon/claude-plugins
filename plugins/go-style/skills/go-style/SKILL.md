---
name: go-style
description: Go style conventions to apply when writing, refactoring, or reviewing Go code in any of the user's repos — pointer-field initialization, import aliasing, logger naming, test shape, assertion collapsing, parser colocation. Load BEFORE writing Go; also use when reviewing Go diffs.
---

# Go style conventions

Cross-project conventions confirmed by explicit feedback. They complement (never override) the global CLAUDE.md Go rules and any repo-local CLAUDE.md.

## `new(value)` for pointer fields (Go 1.26+)

Use `new(value)` to initialize `*T` struct fields — never declare a local just to take its address:

```go
// Don't:
role := RoleAdmin
in := CreateUserInput{Role: &role}

// Do:
in := CreateUserInput{Role: new(RoleAdmin)}
```

Same for strings: `Name: new(cfg.UserName)` over `Name: &cfg.UserName`.

## Multi-column scans → named struct

For query scans with 2+ outputs, group targets into a small inline struct with named fields instead of parallel `var a, b, c` declarations:

```go
var v struct {
    Locked   bool
    HasOrgs  bool
    HasUsers bool
}
tx.QueryRow(ctx, q, key).Scan(&v.Locked, &v.HasOrgs, &v.HasUsers)
```

Single-output scans stay plain vars (struct is overkill).

## Import aliasing

Default to **bare imports** — don't alias just because a name overlaps with the current package. Aliases add cognitive overhead and break grepability.

The exceptions are **standing, repo-wide rules**, never per-file judgment calls:

- Long-established ecosystem conventions (e.g. `github.com/Masterminds/squirrel` → `sq`).
- An external package with an overly generic name (`config`, `types`, `util`) that collides with the repo's own packages gets ONE distinguishing alias applied uniformly across the repo — check the repo's CLAUDE.md or existing imports for the established mapping before inventing one.

One rule applied everywhere beats per-file "alias on collision" decisions. For genuine collisions elsewhere, prefer aliasing at the few real collision sites over renaming packages (and count importers of the package whose *identity* changes when weighing a rename — the folder path is incidental).

## Logger naming

`*slog.Logger` identifiers are `logger`, never `log` — parameters, struct fields, locals, and shadowed rebindings (`logger := logger.With(...)`). `log.X` reads ambiguously against the stdlib package; `logger.X` is unambiguously a value.

## Test shape

One top-level `func TestSubject(t *testing.T)` per subject with `t.Run` subtests per scenario — not one top-level `TestSubject_Scenario` function per case.

- Case names are lowercase sentence-style: `t.Run("reject expired token", …)`.
- When one type has several methods, each method is its own CamelCase subtest with cases nested under it: `t.Run("VerifyRequest", …)` → `t.Run("extracts Bearer token", …)`. Never flat `"VerifyRequest extracts Bearer token"` names.
- Table-driven sub-cases live inside the parent `t.Run` block.
- Separate top-level `Test*` only for genuinely different subjects.
- Applies retroactively: reshape one-test-per-scenario files when editing them.

## Assertion collapsing

`require.ErrorIs(t, err, target)` — never the `require.Error(t, err)` + `assert.ErrorIs(t, err, target)` pair. The single form already implies non-nil. Pair them only when the test must continue past a nil error to gather more failure data (rare).

## Parser colocation

A parser whose sole job is producing types defined in the same package lives in the **same file** as those types — `foo.go` holds types + `ParseFoo`, `foo_test.go` holds all their tests. No `foo_parse.go` / `foo_parse_test.go` split. Exception: parser grows to several hundred lines or acquires its own dependency tree. Applies retroactively — fold split pairs when touching them.
