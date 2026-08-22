---
name: go-style
description: Go style conventions to apply when writing, refactoring, or reviewing Go code in any of the user's repos — type design and composition, naming and package-prefix stripping, named returns, error wrapping and translation, unchecked-error marking, hashing/secrets, config-at-startup validation, HTTP-client injection, struct-literal and pointer-field initialization, import aliasing, logger naming, test shape, assertion collapsing, parser colocation. The canonical cross-repo Go home — the global CLAUDE.md no longer carries a dedicated Go section. Load BEFORE writing Go; also use when reviewing Go diffs.
---

# Go style conventions

Uber Go style guide as baseline. These are the cross-project Go conventions confirmed by explicit feedback — the canonical home; the global CLAUDE.md no longer carries a `# Go` section. A repo-local CLAUDE.md still wins where it applies.

## Type design

Stateful → type with methods. Stateless → free function. Don't pretend either way.

Composition, in order of preference:

1. **Named-field DI.** Dependencies as named struct fields, wired through constructors. The default.
2. **Anonymous embedding** only when method passthrough is the goal (e.g. `*pgkit.DB` inside `Database`).
3. **Generic type parameters** when the same logic applies to multiple shapes (`Table[T, *T, ID]`, `cache.Simple[K, V]`, `Config[T]`).

What stays a free function: constructors (`NewX`, `ParseX`), middleware factories (`func(...) func(http.Handler) http.Handler`), pure transformations without state, generic accessors (`GetUser[T]`).

Anti-patterns: fat interfaces (compose small ones instead); interface-everything (concrete types are the default — interface at boundaries or for stubbing); `Helper` / `Util` types wrapping what should be plain functions.

## Naming

- `New*` constructors, `Parse*` from raw data, PascalCase with uppercase acronyms (`APIKeyTable`).
- Packages: short, lowercase, no underscores. Unexported helpers named by action: `deriveName`, `buildRequest`.
- Names describe behavior, not aspiration: `tokenSource`, not `VendorAuth`.
- Drop the package prefix from exported names — `s2s.Verify`, not `s2s.VerifyS2S`. The import path already qualifies it at the call site.

## Named returns

Preserve named return arguments — they document what each value means at the signature, especially in multi-value returns (`(n int, err error)`). Don't strip existing ones to bare types.

## Errors

- Wrap with `fmt.Errorf("context: %w", err)` — lowercase, colon-separated.
- Never surface raw DB errors — translate to domain errors by semantic context (`pgx.ErrNoRows` → `ErrUserNotFound`, never a leaked driver string).
- `//nolint:errcheck` for intentionally unchecked errors — never `_ =`.

## Hashing & secrets

Never plain SHA-256 without salt. Reuse the existing salt+pepper patterns (e.g. API-key hashing) before inventing new ones.

## Construction & clients

- Validate config at startup via `Parse()` methods — not at request time.
- Never use `http.DefaultClient` — inject an HTTP client with an explicit timeout.

## Small mechanics

- `cmp.Or(val, fallback)` over `if val == zero { val = fallback }` for simple defaults.
- Extract repeated header/request setup into a helper — don't copy-paste across methods.
- Inline single-field struct literals: `&Foo{Bar: val}`.

## Time-sensitive tests

Timers, tickers, expirations, and rate windows use `testing/synctest` (Go 1.25+ stdlib). Production code calls `time.Now().UTC()` / `time.Sleep` / timers normally — no `Clock` interface, no `utc.Now()` wrapper.

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

### Standing mappings

Apply these on sight, in every repo — no per-file decision:

| Import | Alias | Why |
|---|---|---|
| `github.com/Masterminds/squirrel` | `sq` | Long-established convention; predates this rule. |
| `github.com/0xPolygon/go-libs/config` | `libconfig` | `config` is too generic — `pkg/config` and `apps/<svc>/config` are both named `config`, so `libconfig.BasicAuth` reads unambiguously wherever it appears. |

Anything else: bare import, even when the package name overlaps the current file's package.

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
