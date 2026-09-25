---
name: service-skeleton
description: "Go backend service layout (apps/<svc>/ with cmd, config, data, domain, rpc, tests plus a root pkg/), patterns, and anti-patterns. Use when scaffolding a new Go BE service, setting up a new Go backend repo from scratch, creating the initial directory layout for a backend, or deciding where new code belongs in an existing service. Reference iteration is omsx (~/Workspace/0xPolygon/omsx)."
---

# Service skeleton (Go BE)

omsx is the reference iteration. When in doubt about layout, look there first: the canonical tree is the "App layout" and "Cross-binary helpers" sections of `omsx/README.md`, and the layering rules are in `omsx/AGENTS.md` (Invariants).

## Structure

A monorepo holds one Go module with a binary per `apps/<svc>/` and shared leaf code in a root `pkg/`.

- `apps/<svc>/cmd/<binary>/`: entrypoints.
- `apps/<svc>/config/config.go`: typed config loaded once at startup; embeds the shared common config from `pkg/`.
- `apps/<svc>/data/`: the binary's data layer. Per-table types embed a generic `Table[T, *T, ID]` from a shared `pkg/` helper (omsx `pkg/dbkit`); `data.go` holds the `Database` struct whose `WithTx(tx)` rebinds every table to one transaction (omsx `apps/api/data/data.go`); goose migrations under `data/migrations/`.
- `apps/<svc>/domain/<entity>/`: business actions shared by more than one RPC surface. Logic used by a single surface stays in its handler.
- `apps/<svc>/rpc/router.go`: chi router, middleware chain, server mount.
- `apps/<svc>/rpc/core/`: the thin infra dependency bundle (logger, config, `*data.Database`) that every service embeds. No business logic here.
- `apps/<svc>/rpc/<service>/`: one package per RPC service, with `service.go` holding the struct, the `var _ proto.XxxServer` assertion, and `New`.
- One file per RPC method, named lowerCamelCase after the method (omsx `customers/create.go`, `customers/bulkCreate.go`), with a sibling `*_test.go`.
- `apps/<svc>/clients/`: outbound clients, generated with oapi-codegen wherever the provider publishes an OpenAPI spec.
- `apps/<svc>/pkg/`: leaf libs scoped to one binary; never import `rpc/` or `data/`.
- Root `pkg/`: leaf libs shared across binaries; pure Go, never import `apps/`.
- `schema/` or `proto/`: RIDL source of truth; generated `*.gen.go` / `*.gen.ts`.
- `apps/<svc>/tests/`: e2e harness, `tests.StartServer(t)` plus `Seed*` helpers, wrapping the cross-binary scaffolding in root `pkg/` (omsx `pkg/testkit`).

## Patterns

- **Panic-on-nil-required-dep in constructors.** Fail fast at boot, not at request time.
- **Build-time tools** (webrpc-gen, oapi-codegen, golangci-lint, etc.) via `tool` directives in the main `go.mod`, with no `tools/` submodule.
- **Mocks:** hand-rolled at the boundary, next to the harness that uses them (omsx `apps/api/tests/waas_auth_manager_mock.go`). No generated mocks.
- **Tests:** integration through the HTTP layer via the harness, per the global testing rules.

## Anti-patterns

- `replace` directives pinning your own forks: one-off bug fixes only, never as a pattern.
- Multi-method-per-file handlers when split-per-method fits.
- Separate `tools/` submodule for build-time deps, superseded by `tool` directives.
