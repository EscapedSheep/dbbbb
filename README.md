# dbbbb

dbbbb is a local-first Electron database client for PostgreSQL, MongoDB, MySQL, and SQLite. It keeps SQL tables/rows and MongoDB collections/documents as separate native workflows, while sharing connections, object navigation, query history, themes, and safety controls.

The project is usable as an early development build. Demo connections remain available, and real PostgreSQL, MongoDB, MySQL, and SQLite sessions are implemented in the Electron main process.

## What works now

- Real PostgreSQL connections with `disable`, `require`, and `verify-full` SSL modes; schema/table/view browsing; generated previews; SQL execution; bounded results; timeout and targeted cancellation.
- Real MongoDB and SRV connections—SRV URIs require TLS, and the dialog pre-selects it; database/collection browsing; canonical Extended JSON `find` and `aggregate` input; BSON-preserving canonical EJSON results; bounded execution and cancellation.
- Real MySQL connections with `disable`, `require`, and `verify-full` SSL modes; `information_schema` introspection of the bound database; generated previews; bounded single-statement SQL execution; and targeted `KILL QUERY` cancellation. Read-only connections are enforced twice: a client-side statement classifier plus `transaction_read_only` on every pooled session.
- Real SQLite connections to local database files with an optional read-only file open; table/view browsing; generated previews; bounded single-statement SQL execution. Statements run synchronously in the main process, so a long query blocks the UI and cannot be cancelled.
- A local query history and favorites library. It keeps at most 100 non-favorite history entries, collapses an immediate repeat of the identical command into the previous entry, and does not persist connection URIs or passwords.
- Streaming CSV import into an introspected PostgreSQL table and JSONL import into an introspected MongoDB collection. Imports use an opaque, single-use file token, bounded parsers, live byte progress, and cancellation.
- CSV export for the current bounded row result and canonical JSONL export for the current bounded document result. Files are written through a temporary file and atomically renamed on success.
- Reviewed single-record update/delete for eligible real, writable connections. PostgreSQL edits require an introspected table with a primary key and columns whose types round-trip losslessly; MongoDB edits preserve `_id`. Optimistic checks reject stale or ambiguous changes.
- Opt-in saved connections with protected credential storage, automatic reconnect at startup, and separate **Disconnect** and **Forget** actions.
- Light, Dark, and System themes in a low-saturation line UI, with keyboard-visible focus and accessible dialog/result controls.
- A sandboxed renderer, narrow typed preload bridge, validated IPC payloads, main-process database drivers and file access, redacted errors, and bounded structured-clone-safe wire values.

## Saved connections and credentials

Connections remain session-only by default. Selecting **Remember and reconnect** asks dbbbb to save the complete connection after the first database connection succeeds. The setting is opt-in; leaving it unchecked does not touch the credential vault.

Saved inputs are encrypted in the Electron main process with `safeStorage`. Electron uses macOS Keychain on macOS and DPAPI on Windows. On Linux, dbbbb accepts the `libsecret` or KWallet backends reported by Electron (`gnome_libsecret`, `kwallet`, `kwallet5`, or `kwallet6`). It explicitly rejects Electron's `basic_text` fallback, unknown backends, and unavailable encryption rather than writing plaintext credentials.

At startup, dbbbb decrypts saved entries and attempts to reconnect them. If a decrypted profile cannot reach or authenticate to its database, dbbbb keeps a redacted **Unavailable** entry so the user can explicitly Forget it; no username, password, or credential-bearing URI is exposed to the renderer. A corrupt entry or unavailable secure store produces only a credential-safe global warning because trustworthy display metadata cannot be recovered. Other entries can still restore. If saving a newly connected profile fails, that database session stays open for the current run, is marked as not saved, and shows a warning.

**Disconnect** closes only a live session and keeps its encrypted saved entry for the next startup. **Forget** removes the saved entry and protected credentials, and also closes the session when one is live.

## Current limits

- Protected storage is implemented and passed a one-time manual macOS Keychain save/restart/disconnect smoke of a local packaged build; that check is not automated. Repeatable Windows DPAPI and Linux libsecret/KWallet validation still remains; there is no insecure plaintext fallback when the platform store is unavailable.
- MongoDB driver and integration-test code are present, and the suite runs against a real MongoDB 7 container in the scheduled/manual CI job. This repository still does not claim verification against managed, SRV, or TLS deployments, and locally the suite skips unless a URL is explicitly supplied.
- Import currently targets one known PostgreSQL table or MongoDB collection. Content preview, field mapping, and a downloadable error report are not implemented.
- Editing and import remain PostgreSQL- and MongoDB-only. MySQL and SQLite connections fail closed on both paths, in the renderer and in the main process.
- SQLite statements run synchronously on the main-process event loop: a long query blocks the UI until it finishes, and cancellation is unsupported (`node:sqlite` has no interrupt API).
- The MySQL integration suite runs against a `mysql:8` container in the scheduled/manual CI job. Verification against managed or TLS production deployments is still pending, and locally the suite skips unless `DBBBB_TEST_MYSQL_URL` is set.
- Local packages are unsigned. Code signing, macOS notarization, auto-update, and release-channel infrastructure are not implemented.

## Run locally

Prerequisites: Node.js, npm, and any PostgreSQL, MySQL, or MongoDB server (or a SQLite database file) you choose to connect to.

```bash
npm install
npm run dev
```

The application starts with demo PostgreSQL and MongoDB connections, so the UI can be explored without a database server. Use **New connection** to open a real session. Credentials cross the preload boundary only for connection setup. They stay in the main-process session by default; the opt-in **Remember and reconnect** path stores only an OS-protected encrypted record as described above.

## Verify

Run the normal type, unit/component, and production-bundle checks:

```bash
npm run typecheck
npm test
npm run build
```

`npm run build` creates the compiled Electron bundles; it does not create an installer.

These three checks also run in CI on every push and pull request (Ubuntu and macOS). A scheduled or manually dispatched CI job additionally runs the three integration suites against `postgres:16`, `mongo:7`, and `mysql:8` service containers, including the PostgreSQL and MongoDB write paths. `npm run test:integration` runs all three opt-in suites locally in sequence.

### Optional PostgreSQL integration

The PostgreSQL suite skips unless `DBBBB_TEST_POSTGRES_URL` is set. Its default path is read-only and covers connection, introspection, bounded execution, and cancellation.

```bash
DBBBB_TEST_POSTGRES_URL='postgresql://user:password@127.0.0.1:5432/database?sslmode=disable' \
  npm run test:integration:postgres
```

Write integration is an additional opt-in gate. Use only a disposable database account that may create and drop a temporary schema; the test exercises CSV import plus reviewed update, stale-write rejection, and delete, then cleans up its fixture.

```bash
DBBBB_TEST_POSTGRES_URL='postgresql://user:password@127.0.0.1:5432/disposable_database?sslmode=disable' \
DBBBB_TEST_POSTGRES_ENABLE_WRITE=1 \
  npm run test:integration:postgres
```

### Optional MongoDB integration

The MongoDB suite is separate and skips by default. Supplying a URL enables connection, collection listing, and bounded canonical-EJSON query checks. The suite creates and drops its own fixture collection, so it does not depend on existing data. This command is provided as a harness, not as a claim that a live MongoDB environment has already been verified.

```bash
DBBBB_TEST_MONGO_URL='mongodb://127.0.0.1:27017/database' \
DBBBB_TEST_MONGO_DATABASE='database' \
  npm run test:integration:mongo
```

Write coverage—JSONL import, optimistic update, stale-write rejection, and delete against a second throwaway fixture collection—is an additional opt-in gate. Use only a disposable database:

```bash
DBBBB_TEST_MONGO_URL='mongodb://127.0.0.1:27017/disposable_database' \
DBBBB_TEST_MONGO_DATABASE='disposable_database' \
DBBBB_TEST_MONGO_ENABLE_WRITE=1 \
  npm run test:integration:mongo
```

An optional long-query cancellation case can be enabled with `DBBBB_TEST_MONGO_ENABLE_LONG_QUERY=1`; it requires a server/configuration that permits the test pipeline's server-side function.

### Optional MySQL integration

The MySQL suite skips unless `DBBBB_TEST_MYSQL_URL` is set. The URL uses the `mysql` protocol with a host, username, and database, and accepts an optional `sslmode` query parameter (`disable`, `require`, or `verify-full`; it defaults to `disable`). The suite is read-only: it covers connection, `information_schema` introspection, bounded execution, session read-only enforcement, and targeted cancellation, and it creates no fixture data.

```bash
DBBBB_TEST_MYSQL_URL='mysql://user:password@127.0.0.1:3306/database?sslmode=disable' \
  npm run test:integration:mysql
```

## Package locally

```bash
# Unpacked application directory for the current platform
npm run package:dir

# macOS DMG and ZIP
npm run package:mac
```

Artifacts are written under `release/`. They are development artifacts without signing or notarization, so macOS Gatekeeper or Windows SmartScreen may warn. The builder configuration also declares Windows NSIS and Linux AppImage/DEB targets, but this repository does not provide verified release scripts for them yet.

See [the development plan](docs/DEVELOPMENT_PLAN.md) and [the architecture notes](docs/ARCHITECTURE.md). dbbbb is licensed under the [MIT License](LICENSE).
