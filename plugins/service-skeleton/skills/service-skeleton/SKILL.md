---
name: service-skeleton
description: Go backend service layout — cmd/rpc/data/clients/tests structure, patterns, and anti-patterns. Use when scaffolding a new Go BE service, setting up a new repo from scratch, creating the initial directory layout for a backend, or deciding where new code belongs in an existing service. Reference iteration is omsx (~/Workspace/0xPolygon/omsx).
---

# Service skeleton (Go BE)

omsx is the reference iteration. When in doubt about layout, look there first.

## Structure

- `cmd/<binary>/` — entrypoints
- `rpc/` — chi router + middleware + `services/<surface>/<domain>/` handlers
- One file per RPC method (`create.go`, `list.go`, `get.go`, `update.go`, `delete.go`) with sibling `*_test.go`
- `data/` — pgkit/v2 generic `Table[T, *T, ID]` base; per-domain `*Table` embeds it; `Database.Tx` propagates `WithTx` across all embedded tables; goose migrations under `data/migrations/`
- `clients/` — outbound HTTP/gRPC clients
- `lib/` or `core/` — vertical sub-packages
- `proto/` or `schema/` — RIDL source of truth, generated `*.gen.go` / `*.gen.ts`
- `tests/` — e2e harness with `Setup(t)` + `Seed*` helpers

## Patterns

- **Panic-on-nil-required-dep in constructors.** Fail fast at boot, not at request time.
- **Build-time tools** (mockery, webrpc, golangci-lint, etc.) via `tool` directives in main `go.mod` — no `tools/` submodule.
- **Mocks:** mockery v2 → `mockFoo.gen.go` for service code; hand-rolled for tiny library interfaces.
- **Tests:** e2e through chi via `httptest.Server` + real Postgres + Seed helpers. No mocking the DB layer.

## Anti-patterns

- `replace` directives pinning your own forks — one-off bug fixes only, never as a pattern.
- Multi-method-per-file handlers when split-per-method fits.
- Separate `tools/` submodule for build-time deps — superseded by `tool` directives.
