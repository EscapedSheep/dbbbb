# Architecture

> **⛔ DEPRECATED — historical reference only / 已废弃，仅作历史参考。**
> This document describes the retired Electron implementation (`src/`), which is no longer developed. The current product is the native Swift app under `swift/`; see `HANDOVER.md` and `README.md` for the current state.
> 本文档描述的是已废弃的 Electron 版（`src/`），不再维护。现行实现为 `swift/` 目录下的 Swift 原生版（Swift 6 + SwiftUI），现状见仓库根目录 `HANDOVER.md` 与 `README.md`。

## Runtime boundary

```text
React renderer
  UI state, query library, bounded current results
        │ named contextBridge methods only
        ▼
preload
  typed forwarding; no raw ipcRenderer exposure
        │ trusted-sender and payload-validated IPC
        ▼
Electron main
  DatabaseService ── session ── PostgreSQL adapter (`pg`)
       │                  ├───── MongoDB adapter (official driver)
       │                  ├───── MySQL adapter (`mysql2`)
       │                  └───── SQLite adapter (`node:sqlite`)
       ├── import coordinator / streaming parsers
       ├── result export service / filesystem dialogs
       └── encrypted connection vault (`safeStorage` protector)
```

The renderer has no direct Node.js, database-driver, or filesystem access. It owns presentation state, the current bounded result, theme preference, and the local query library. Connection passwords and credential-bearing URIs are not written to that library.

The main process owns real and demo adapter instances, live sessions, cancellation controllers, native file dialogs, transfer streams, and the encrypted connection vault. A successful real connection returns a redacted `ConnectionProfile`; it never returns a password or full credential-bearing MongoDB URI. Connection inputs remain only in the main-process session by default. When the user explicitly selects **Remember and reconnect**, the main process may also store the normalized input as an OS-protected encrypted vault record after the database connection succeeds.

The preload is deliberately mechanical. It exposes named lifecycle, query, edit, import, and export calls and never exposes `ipcRenderer` itself. Every main-process handler checks the requesting `webContents` and validates its payload before using it.

## Shared model

Only lifecycle, object navigation, and wire transport are shared. Query and result types are discriminated:

- SQL command (`SqlCommand`, shared by PostgreSQL, MySQL, and SQLite) → SQL text → column/row result
- MongoDB command → canonical Extended JSON `find` filter or aggregation pipeline → document result

Driver-native values never cross IPC. Both adapters convert results to a recursively structured-clone-safe `WireValue` before returning them:

- PostgreSQL retains ordinary safe scalars, keeps date/timestamp/timestamptz as the driver's raw text so edited values round-trip without host-timezone drift or microsecond loss, represents bytes with a `$binary` tag, and converts bigint, unsafe integer, decimal-like, and non-finite numeric values to strings instead of silently losing precision.
- MySQL keeps temporal values as the server's raw text (`dateStrings`) and crosses BIGINT/DECIMAL as strings (`bigNumberStrings`) for the same round-trip and precision reasons.
- SQLite reads integers as bigints and keeps only safe ones as numbers, stringifying the rest; array-shaped rows keep duplicate column labels addressable.
- MongoDB parses and serializes with the official BSON canonical Extended JSON implementation (`relaxed: false`), preserving tags such as ObjectId, Decimal128, Binary, and 64-bit integers.

Traversal depth/value limits, cycle/accessor handling, row count, and byte budgets bound serialization. Normal query execution defaults to 500 results and 5 MiB. Independently of those budgets, any single string or binary value over 8 MiB is truncated and visibly marked (`…[dbbbb truncated N bytes]`). Metadata explicitly reports truncation and whether data came from a demo or real database.

## Sessions, discovery, and cancellation

`DatabaseService` maps opaque connection IDs to a redacted profile plus one main-process adapter. Demo profiles and real profiles use the same contract, but edit/import paths explicitly reject demo sessions. A saved profile whose database reconnect fails is held separately as a redacted `connected: false` placeholder with no adapter or retained `ConnectionInput`; all database operations on that ID fail closed, while explicit Forget can still remove its vault record.

- PostgreSQL discovers schemas, tables, and views. Generated previews quote identifiers and apply `LIMIT 100`. A running request is associated with its backend process and cancellation targets that request rather than terminating the whole session.
- MongoDB discovers the selected database and collections. `find` and read-only `aggregate` commands use canonical EJSON rather than code evaluation. Execution uses an abort signal and timeout; write pipeline stages (`$out`/`$merge`) are rejected for read-only commands, and a cancellation registered before execution still cancels the request. Input is data-only EJSON, but server-side JavaScript operators such as `$where` are not filtered out, so read-only intent still depends on database privileges.
- MySQL discovers the bound database's tables and views from `information_schema`. Generated previews quote identifiers and apply `LIMIT 100`; execution is single-statement. Cancellation issues `KILL QUERY` from a separate short-lived connection against the running statement's thread, so the pool stays usable. Read-only profiles are enforced twice: a client-side statement classifier, plus `SET SESSION transaction_read_only = ON` applied once to every pooled session as server-side enforcement behind it.
- SQLite discovers tables and views from `sqlite_master` under one synthetic `main` schema node. Execution is single-statement everywhere (multi-statement input is rejected because `prepare()` would silently ignore trailing statements). Statements run synchronously on the main-process event loop, so a long query blocks the UI until it finishes, and `node:sqlite` exposes no interrupt API—`cancel()` is explicitly unsupported and throws without side effects rather than pretending to work. Read-only profiles open the file read-only, so the SQLite layer rejects writes even if the statement classifier has a gap.

Index discovery is not implemented. MongoDB live-environment verification remains an explicit, opt-in integration task rather than an assumed property of the normal test suite.

## Local query library

The renderer stores query history/favorites under the versioned `dbbbb.query-library.v1` localStorage key. The schema is whitelisted and contains an opaque connection ID, engine, command, title, timestamp, and favorite state—never a connection URI, username, or password. Parsing is defensive, serialized storage is bounded, only 100 non-favorite history records are retained, an immediate repeat of the identical command updates the previous entry instead of appending a new one, and favorites survive “clear history.” Stored data with an unrecognized version or an over-limit payload is left untouched; that session runs with an in-memory library instead of rewriting it.

This storage is a convenience history, not a secret store. Queries themselves may contain sensitive literals, so users should still treat the local application profile as sensitive.

## Imports and exports

Import file paths stay in the main process. Selection returns only an opaque, expiring, single-use token plus basename and size. Before reading, the coordinator checks the session/target/format matrix, rejects demo and read-only targets, accepts only a non-empty regular file up to 1 GiB, and re-checks size and modification time. Up to 20 selections can be pending; a full queue evicts only idle selections and refuses new ones while that many imports are running. Cancellation is available before and during the streaming operation—including inside a running MongoDB batch. Imports stop at a default 1,000,000-row limit, and JSONL input rejects blank lines instead of skipping them. Byte/count progress is throttled in the main process, tagged with the opaque token, and sent only to the still-live renderer that selected the file; notification failure never changes the database import result.

- PostgreSQL: CSV → one introspected table. Headers and insertable columns are validated; parameterized batches run in one transaction and roll back on error or cancellation.
- MongoDB: JSONL → one introspected collection. Ordered batches are deliberately non-transactional, so a failure can leave already confirmed earlier batches in place; the UI must preserve that warning. A failed or cancelled batch carries the count the server actually confirmed, so partial results are tallied accurately rather than as an all-or-nothing batch.
- MySQL and SQLite: not implemented. The coordinator's engine/target/format matrix accepts only the two combinations above, the MySQL and SQLite adapters do not implement `importData`, and the renderer offers import formats only for PostgreSQL tables and MongoDB collections—every layer fails closed.

Result export is limited to the already bounded result visible in the renderer: rows become CSV and documents become canonical JSONL. The main process validates the IPC result payload, streams to a private temporary file, removes it on failure, and renames it into place after success; on platforms that refuse to rename over the confirmed target (Windows), the target is removed and the rename retried once. Export is not an unbounded database dump.

## Safe single-record changes

Editing is offered only when the result came from executing the exact generated object-preview command, the command has not since been changed, and the session is real and writable. Duplicate SQL column labels disable row editing because they cannot form an unambiguous record. Editing is implemented only for PostgreSQL and MongoDB: the renderer gates edit eligibility to those two engines, and the MySQL and SQLite adapters do not implement `applyDataChange`, so the main process rejects their edit attempts as unsupported.

The editor parses a data-only JSON object, shows a diff, and requires review before apply. PostgreSQL cannot add or remove columns; MongoDB must retain the original `_id`. Production updates require the literal `APPLY`, and deletes require the literal `DELETE`; like read-only mode, these confirmations are renderer-side guardrails, not an authorization boundary—the main process does not require a confirmation token.

The main process independently checks engine/session/object eligibility and validates change payload size, depth, numeric safety, field names, and data-only properties into null-prototype records. PostgreSQL uses an introspected primary key, parameterized SQL, a transaction, and optimistic original-value checks; it also verifies UPDATE/DELETE column privileges and refuses tables containing column types that cannot round-trip losslessly (`json`, `interval`, `money`, range/multirange) at metadata time. MongoDB keeps `_id` immutable, and both updates and deletes filter on every original field, matching the whole-row optimistic granularity of the PostgreSQL path. Both paths require exactly one affected record; stale or ambiguous changes fail closed.

## Credential lifecycle

Credential persistence is opt-in. The connection form omits `remember` unless **Remember and reconnect** is checked, and the service writes a vault record only after the initial database connection succeeds. An unchecked connection is never written to the vault.

The vault has bounded, versioned schemas; restrictive file/directory modes; serialized writes; defensive parsing; and per-record validation. Its Electron protector uses `safeStorage` and accepts these platform paths only:

- macOS: Keychain-backed `safeStorage`
- Windows: DPAPI-backed `safeStorage`
- Linux: Electron's `gnome_libsecret`, `kwallet`, `kwallet5`, or `kwallet6` backend

Availability is checked before encryption or decryption. On Linux, `basic_text`, an unknown backend, or a missing backend is rejected even if Electron otherwise reports encryption available. Unsupported platforms and unavailable platform encryption are also rejected. This is a fail-closed policy: dbbbb does not deliberately persist plaintext connection passwords as a fallback.

Application startup loads the vault before creating the window and attempts saved connections concurrently. Invalid or undecryptable records are skipped with a redacted global warning because trustworthy metadata is unavailable. A decrypted record whose database connection fails becomes a redacted **Unavailable** placeholder; it retains only safe profile fields, can be explicitly forgotten, and cannot execute database operations. Other profiles can still restore. If an already-established connection cannot be saved, it remains usable only for that session, its profile reports `saved: false`, and `storageWarning` is shown.

Saved state and live-session state are separate. **Disconnect** removes and closes the live adapter but leaves the encrypted vault entry for a future startup. **Forget** removes the vault entry and closes a live adapter when present; an unavailable placeholder has no adapter to close. Removal or close failures are reported and keep a retryable profile rather than being presented as success.

## Security defaults

- `nodeIntegration: false`
- `contextIsolation: true`
- renderer sandbox enabled
- local Content Security Policy with scripts restricted to self and object/frame/form embedding disabled
- all permission requests and permission checks denied by default; new windows and renderer navigation denied (`https://` links are handed to the system browser)
- a single-instance lock keeps one process owning the credential vault; a second launch focuses the existing window
- at most 50 live sessions; demo sessions never accept edits or imports
- preload exposes named methods, never raw `ipcRenderer`
- IPC sender and payload validation in the main process
- no password or full credential-bearing URI returned to the renderer
- credential persistence is explicit opt-in and refuses insecure `basic_text`/plaintext fallback
- bounded query, change, import, and export payloads
- database content rendered as text, not injected HTML
- PostgreSQL defaults to certificate-verifying TLS; MongoDB `mongodb+srv://` URIs require TLS—connections that disable it are rejected, and the connection dialog pre-selects TLS when it detects an SRV URI
- MySQL read-only profiles are enforced twice (client-side statement classifier plus `transaction_read_only` on every pooled session); SQLite read-only profiles open the database file read-only
- client-side read-only mode is a guardrail, not an authorization boundary

Read-only enforcement in the client reduces mistakes but cannot replace database roles, server-side permissions, network controls, or backups. Users should connect with the least-privileged database account appropriate to the task.

## UI system

- Four surfaces: connections, objects, query, result
- 1 px dividers; shadows only for dialogs and popovers
- 4 px control radius and restrained motion
- Light/Dark tokens are semantic CSS custom properties
- SQL rows and MongoDB documents receive distinct result views
- keyboard-visible focus, dialog labels/status, and state that is not communicated by color alone

Theme preference is local presentation state and supports Light, Dark, and System. A small dependency-free script loaded ahead of the module bundle applies the stored theme before first paint, avoiding a flash of the wrong theme. The UI is designed for keyboard and assistive-technology use, while a formal end-to-end accessibility audit remains future work.

## Tests and packaging

The default Vitest suite exercises main-process validation/adapters/transfers/vault code and renderer components without requiring external databases; the SQLite adapter tests run against real on-disk database files via `node:sqlite`. PostgreSQL, MongoDB, and MySQL integration suites are separate and skip unless their environment variables are supplied; PostgreSQL and MongoDB write tests each require an additional explicit opt-in. No live MongoDB or MySQL verification is inferred from unit-test success. A CI workflow runs typecheck, the unit suite, and the production build on every push and pull request (Ubuntu and macOS); a scheduled or manually dispatched job runs the three integration suites against PostgreSQL 16, MongoDB 7, and MySQL 8 service containers, including the PostgreSQL and MongoDB write paths.

`electron-vite` produces the compiled application bundles. `electron-builder` can produce an unpacked current-platform app and macOS DMG/ZIP artifacts. A one-time manual smoke of a local packaged build (macOS Keychain save/restart/disconnect) passed during development; it is not automated coverage. Signing, notarization, auto-update, verified Windows/Linux release automation, and repeatable DPAPI/libsecret/KWallet smoke coverage are not implemented, so local artifacts are unsigned development builds.

## Extension points

New engines implement the adapter contract while keeping their command/result model explicit. MySQL and SQLite now ship as reference cases: both reuse the shared `SqlCommand` model and the column/row result shape, with engine-specific introspection, read-only enforcement, and cancellation behavior (SQLite deliberately has none). Editing and import remain PostgreSQL/MongoDB-only, so a further engine opting into either path must also extend those eligibility checks. Large transfers or CPU-heavy parsing can later move into an Electron utility process without giving the renderer new privileges or changing the public preload surface.
