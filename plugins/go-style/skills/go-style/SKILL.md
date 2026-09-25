---
name: go-style
description: Go style conventions to apply when writing, refactoring, or reviewing Go code in any of the user's repos. Covers type design and composition, naming and package-prefix stripping, named returns, error wrapping and translation, unchecked-error marking, hashing/secrets, config-at-startup validation, HTTP-client injection, cmp.Or defaults, struct-literal and pointer-field initialization, time-sensitive tests with testing/synctest, multi-column scan structs, import aliasing, logger naming, test shape, assertion collapsing, parser colocation, and the Go diff review checklist. The canonical cross-repo Go home. Load BEFORE writing Go; also use when reviewing Go diffs.
---

# Go style conventions

Uber Go style guide as baseline. These are the cross-project Go conventions confirmed by explicit feedback, and this is their canonical home. A repo-local CLAUDE.md still wins where it applies.

## Type design

Stateful → type with methods. Stateless → free function. Don't pretend either way.

Composition, in order of preference:

1. **Named-field DI.** Dependencies as named struct fields, wired through constructors. The default.
2. **Anonymous embedding** only when method passthrough is the goal (e.g. `*pgkit.DB` inside `Database`).
3. **Generic type parameters** when the same logic applies to multiple shapes (`Table[T, *T, ID]`, `cache.Simple[K, V]`, `Config[T]`).

What stays a free function: constructors (`NewX`, `ParseX`), middleware factories (`func(...) func(http.Handler) http.Handler`), pure transformations without state, generic accessors (`GetUser[T]`).

Anti-patterns: fat interfaces (compose small ones instead); interface-everything (concrete types are the default; interface at boundaries or for stubbing); `Helper` / `Util` types wrapping what should be plain functions.

## Naming

- `New*` constructors, `Parse*` from raw data, PascalCase with uppercase acronyms (`APIKeyTable`).
- Packages: short, lowercase, no underscores. Unexported helpers named by action: `deriveName`, `buildRequest`.
- Names describe behavior, not aspiration: `tokenSource`, not `VendorAuth`.
- Drop the package prefix from exported names: `s2s.Verify`, not `s2s.VerifyS2S`. The import path already qualifies it at the call site.

## Named returns

Preserve named return arguments: they document what each value means at the signature, especially in multi-value returns (`(n int, err error)`). Don't strip existing ones to bare types.

## Errors

- Wrap with `fmt.Errorf("context: %w", err)`, lowercase, colon-separated.
- Never surface raw DB errors; translate to domain errors by semantic context (`pgx.ErrNoRows` → `ErrUserNotFound`, never a leaked driver string).
- `//nolint:errcheck` for intentionally unchecked errors, never `_ =`.

## Hashing & secrets

Never plain SHA-256 without salt. Reuse the existing salt+pepper patterns (e.g. API-key hashing) before inventing new ones.

## Construction & clients

- Validate config at startup via `Parse()` methods, not at request time.
- Never use `http.DefaultClient`; inject an HTTP client with an explicit timeout.

## Small mechanics

- `cmp.Or(val, fallback)` over `if val == zero { val = fallback }` for simple defaults.
- Extract repeated header/request setup into a helper once it repeats at 3+ call sites; below that, keep it inline.
- Inline single-field struct literals: `&Foo{Bar: val}`.

## Time-sensitive tests

Timers, tickers, expirations, and rate windows use `testing/synctest` (Go 1.25+ stdlib). Production code calls `time.Now().UTC()` / `time.Sleep` / timers normally: no `Clock` interface, no `utc.Now()` wrapper.

## `new(value)` for pointer fields (Go 1.26+)

Use `new(value)` to initialize `*T` struct fields; never declare a local just to take its address:

```go
// Don't:
role := RoleAdmin
in := CreateUserInput{Role: &role}

// Do:
in := CreateUserInput{Role: new(RoleAdmin)}
```

`new(expr)` allocates a copy of the value, while `&x` aliases the original. `Name: new(cfg.UserName)` gives the struct its own string that later writes to `cfg.UserName` do not touch; keep `Name: &cfg.UserName` when the field must alias `cfg`.

## Multi-column scans → named struct

For query scans with 2+ outputs, group targets into a small inline struct with named fields instead of parallel `var a, b, c` declarations:

```go
var v struct {
    Locked   bool
    HasOrgs  bool
    HasUsers bool
}
if err := tx.QueryRow(ctx, q, key).Scan(&v.Locked, &v.HasOrgs, &v.HasUsers); err != nil {
    return fmt.Errorf("scan user state: %w", err)
}
```

Single-output scans stay plain vars (struct is overkill).

## Import aliasing

Default to **bare imports**: don't alias just because a name overlaps with the current package. Aliases add cognitive overhead and break grepability.

The exceptions are **standing, repo-wide rules**, never per-file judgment calls:

- An external package with an overly generic name (`config`, `types`, `util`) that collides with the repo's own packages gets ONE distinguishing alias applied uniformly across the repo. Check the repo's CLAUDE.md or existing imports for the established mapping before inventing one.

One rule applied everywhere beats per-file "alias on collision" decisions. A real collision is two imports with the same package name in one file. For those, prefer aliasing at the few collision sites over renaming packages (and count importers of the package whose *identity* changes when weighing a rename; the folder path is incidental).

### Standing mappings

Apply these on sight, in every repo, no per-file decision:

| Import | Alias | Why |
|---|---|---|
| `github.com/Masterminds/squirrel` | `sq` | Long-established convention; predates this rule. |
| `github.com/0xPolygon/go-libs/config` | `libconfig` | `config` is too generic: `pkg/config` and `apps/<svc>/config` are both named `config`, so `libconfig.BasicAuth` reads unambiguously wherever it appears. |

Anything else: bare import, even when the package name overlaps the current file's package.

## Logger naming

`*slog.Logger` identifiers are `logger`, never `log`: parameters, struct fields, locals, and rebindings (`logger = logger.With(...)`; use `:=` only inside a nested scope, since redeclaring a parameter at function top level does not compile). `log.X` reads ambiguously against the stdlib package; `logger.X` is unambiguously a value.

## Test shape

One top-level `func TestSubject(t *testing.T)` per subject with `t.Run` subtests per scenario, not one top-level `TestSubject_Scenario` function per case.

- Case names are lowercase sentence-style: `t.Run("reject expired token", …)`.
- When one type has several methods, each method is its own CamelCase subtest with cases nested under it: `t.Run("VerifyRequest", …)` → `t.Run("extracts Bearer token", …)`. Never flat `"VerifyRequest extracts Bearer token"` names.
- Table-driven sub-cases live inside the parent `t.Run` block.
- Separate top-level `Test*` only for genuinely different subjects.
- Reshape one-test-per-scenario tests only where the current diff already rewrites them, never as drive-by cleanup of untouched tests: the global rule "touch only what the change requires" outranks this skill.

## Assertion collapsing

`require.ErrorIs(t, err, target)`, never the `require.Error(t, err)` + `assert.ErrorIs(t, err, target)` pair. The single form already implies non-nil. Pair them only when the test must continue past a nil error to gather more failure data (rare).

## Parser colocation

A parser whose sole job is producing types defined in the same package lives in the **same file** as those types: `foo.go` holds types + `ParseFoo`, `foo_test.go` holds all their tests. No `foo_parse.go` / `foo_parse_test.go` split. Exception: parser grows to several hundred lines or acquires its own dependency tree. Fold a split pair only when the current diff already rewrites it, never as drive-by cleanup of untouched files: the global rule "touch only what the change requires" outranks this skill.

## Reviewing Go diffs

Every rule above is a review check. On top of them, flag:

- **Transactional gaps:** related writes outside one transaction.
- **External-before-local violations:** a cross-system write that relies on call ordering for correctness. With no shared transaction, the external step must be idempotent, have a compensation, and be covered by a reconciler.
- **Blast-radius mismatch:** an operation whose scope exceeds its intent (removing a role deletes the user).
- **Ghost fields:** a field in the schema or model with no DB column behind it.
- **Dead-on-arrival code:** new code with no caller.
- **N+1 patterns:** a query per item where one batched query resolves them all.

Praise what is clean: separation of concerns, strong table-driven tests, correct reuse of existing infrastructure, PII handled properly.
