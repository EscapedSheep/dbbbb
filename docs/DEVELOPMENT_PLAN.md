# dbbbb development plan

> **⛔ DEPRECATED — historical reference only / 已废弃，仅作历史参考。**
> This document describes the retired Electron implementation (`src/`), which is no longer developed. The current product is the native Swift app under `swift/`; see `HANDOVER.md` and `README.md` for the current state.
> 本文档描述的是已废弃的 Electron 版（`src/`），不再维护。现行实现为 `swift/` 目录下的 Swift 原生版（Swift 6 + SwiftUI），现状见仓库根目录 `HANDOVER.md` 与 `README.md`。

## Product promise

Open a connection, locate data, and make a safe, deliberate change without the visual weight of a full database administration suite.

All local single-user capabilities—including basic import and export—are intended to remain open. Possible future paid work belongs in team policy, audit, managed sharing, enterprise identity, and support rather than essential local workflows.

## Non-negotiable principles

1. Local-first: no account is required and database data never passes through a dbbbb service.
2. Native models: MongoDB documents are not disguised as SQL rows.
3. Safe defaults: production and read-only state are always visible; destructive changes are reviewed before execution.
4. Calm UI: four primary concepts—connections, objects, queries, results—with 1 px boundaries and little ornament.
5. Narrow permissions: credentials and database drivers stay outside the renderer process.
6. Inclusive themes: Light, Dark, and System modes share the same information hierarchy; focus, labels, and state must not rely on color alone.

## Status legend

- **Completed**: implemented and covered by the normal automated suite.
- **Partially complete**: useful implementation exists, but a stated integration, verification, or UX requirement remains.
- **Not started**: no supported product implementation exists yet.

## Milestones

### M0 — Application foundation — Completed

- Electron + React + TypeScript project
- Sandboxed renderer and typed preload bridge
- Database adapter contract with PostgreSQL and MongoDB demo adapters
- Connection/object/query/result vertical slice
- Light/Dark/System themes and responsive line UI
- Unit and component tests

The renderer has no Node.js access, the preload exposes named methods only, and both demo engines execute queries in their native result shapes.

### M1 — PostgreSQL connection and read workflow — Completed

- Real connection form with `disable`, `require`, and `verify-full` SSL modes
- Main-process `pg` adapter and session ownership
- Schema/table/view introspection
- Parameter-safe generated table preview with a 100-row limit
- SQL execution, targeted cancellation, timeouts, bounded rows/bytes, canonical wire normalization, and sanitized errors
- Read-only session guardrails
- Separate, opt-in PostgreSQL integration suite; destructive write coverage requires a second explicit environment flag and a disposable database

Remaining release validation: repeatable packaged smoke tests across supported operating systems. The saved-connection credential lifecycle is tracked under M3.

### M2 — MongoDB connection and read workflow — Partially complete

- Official MongoDB Node driver in the main process
- SRV/TLS connection support; SRV URIs require TLS and are rejected when it is disabled
- Database/collection introspection
- `find` and `aggregate` input using canonical Extended JSON—dbbbb adds no code-evaluation surface, but server-side JavaScript operators such as `$where` are not filtered, so read-only guarantees still rest on database privileges
- Canonical EJSON/BSON-preserving result transport, bounded document traversal, and document result view
- Timeout and per-request cancellation support
- A separate integration harness that skips unless an explicit MongoDB URL is supplied

Remaining: index introspection and verification against managed SRV/TLS deployments. The integration suite runs against a real MongoDB 7 container in the scheduled CI job; this plan does not claim broader live-environment verification beyond that.

### M3 — Safe local workflow and editing — Partially complete

- **Completed:** local query history and favorites with versioned, bounded storage, adjacent deduplication, and no saved URI/password fields
- **Completed:** single-row edit for eligible PostgreSQL tables and single-document edit for MongoDB collections
- **Completed:** optimistic concurrency checks, review-before-apply, explicit production `APPLY` confirmation, and explicit `DELETE` confirmation
- **Completed:** read-only/demo/engine/object eligibility checks in both renderer and main process
- **Completed:** opt-in **Remember and reconnect** flow backed by Electron `safeStorage`; unchecked connections remain session-only
- **Partially complete:** OS-protected credential storage via Electron `safeStorage` (macOS Keychain, Windows DPAPI, allowlisted Linux libsecret/KWallet backends), with Linux `basic_text`, unknown backends, and unavailable encryption failing closed. Coverage is unit-level with mocked platform protectors plus a one-time manual macOS Keychain smoke; real-machine Windows DPAPI and Linux libsecret/KWallet smoke runs remain pending.
- **Completed:** encrypted vault integration, startup reconnect of saved profiles, per-entry failure isolation, and credential-safe warnings
- **Completed:** redacted **Unavailable** placeholders for database reconnect failures, with fail-closed database actions and retryable explicit Forget; plaintext connection input is not retained in the placeholder
- **Completed:** distinct lifecycle actions—**Disconnect** keeps the encrypted saved entry, while **Forget** closes the session and removes it
- **Completed:** save failures keep the established database connection for the current session, mark it unsaved, and surface a warning without falling back to plaintext

A one-time manual smoke of a local packaged build (macOS Keychain save/restart/disconnect) passed during development; it is not automated coverage. Remaining: repeatable Windows DPAPI and Linux libsecret/KWallet smoke tests. A general edit “revert” workflow is also not implemented.

### M4 — Basic import/export — Partially complete

- **Completed:** streaming CSV import to one introspected PostgreSQL table
- **Completed:** streaming JSONL import to one introspected MongoDB collection
- **Completed:** bounded, backpressure-aware parsing; opaque single-use file selections; file revalidation; throttled live byte/count progress; final counts; and cancellation
- **Completed:** transactional PostgreSQL import and ordered, explicitly non-transactional MongoDB batches
- **Completed:** CSV export from the current bounded row result and canonical JSONL export from the current bounded document result, using temporary files and atomic finalization

Remaining: content preview, field mapping, selectable error policy in the product UI, and a downloadable error report.

### M5 — Packaging and beta readiness — Partially complete

- **Completed:** electron-builder configuration and local unpacked/macOS packaging commands
- **Completed:** Light/Dark/System line UI and automated keyboard/ARIA behavior coverage for key workflows
- **Not completed:** code signing, macOS notarization, auto-update, release channels, and restoration of unsaved or crash-interrupted session state
- **Not completed:** formal accessibility, performance, and packaged cross-platform smoke audits

Current package artifacts are unsigned development builds and may trigger operating-system warnings.

### M6 — Broader relational support — Partially complete

- **Completed:** MySQL adapter (`mysql2`) with `disable`, `require`, and `verify-full` SSL modes, `information_schema` introspection of the bound database, generated previews, bounded single-statement execution, and targeted `KILL QUERY` cancellation. Read-only profiles are enforced twice: a client-side statement classifier plus `SET SESSION transaction_read_only` on every pooled session
- **Completed:** SQLite adapter on Electron's built-in `node:sqlite` with local file connections, an optional read-only file open, table/view introspection, generated previews, and bounded single-statement execution. Known limits, pinned by tests: statements run synchronously on the main-process event loop, so a long query blocks the UI, and `node:sqlite` exposes no interrupt API, so cancellation is explicitly unsupported and throws rather than pretending to work
- **Completed:** renderer connection dialog, status surfaces, and the shared SQL command model cover all four engines; editing and import remain gated to PostgreSQL and MongoDB
- **Completed:** opt-in MySQL integration suite enabled by `DBBBB_TEST_MYSQL_URL`; the scheduled/manual CI job runs it against a `mysql:8` service container alongside the PostgreSQL and MongoDB suites
- **Not completed:** edit and import policies for MySQL and SQLite—the adapters deliberately do not implement `applyDataChange`/`importData`, and both paths fail closed in the renderer and main process

Remaining: an edit/import strategy for the new engines, and real-environment MySQL verification beyond the CI service container (managed and TLS deployments are unverified). SQLite has no separate live suite; it is covered by unit tests against real on-disk database files.

## Explicitly deferred

Oracle, SQL Server, BigQuery, SSH/SSO, ER diagrams, schema diff, backup/restore, cross-database joins, visual query builders, AI features, and DataGrip-level semantic SQL analysis.

## Validation gate

Before broadening the engine list, at least five developers who regularly use both MongoDB and SQL should replace their existing viewer for four weeks. One common workflow must be observably faster or safer than its DbGate/Compass equivalent; “free and simpler” alone is not enough differentiation.

Every release candidate must also pass `npm run typecheck`, `npm test`, and `npm run build`—the same checks the CI workflow runs on every push and pull request (Ubuntu and macOS). A scheduled or manually dispatched CI job additionally runs the three integration suites against `postgres:16`, `mongo:7`, and `mysql:8` service containers, including the PostgreSQL and MongoDB write paths. Real-database suites stay opt-in locally so the default test run is deterministic: PostgreSQL reads require `DBBBB_TEST_POSTGRES_URL`, PostgreSQL writes additionally require `DBBBB_TEST_POSTGRES_ENABLE_WRITE=1`, MongoDB requires `DBBBB_TEST_MONGO_URL` through its dedicated test command with writes gated by `DBBBB_TEST_MONGO_ENABLE_WRITE=1`, and MySQL requires `DBBBB_TEST_MYSQL_URL`. `npm run test:integration` runs all three suites in sequence.
