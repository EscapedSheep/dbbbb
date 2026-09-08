# dbbbb

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/EscapedSheep/dbbbb/actions/workflows/ci.yml/badge.svg)](https://github.com/EscapedSheep/dbbbb/actions/workflows/ci.yml)

**English** | [简体中文](README.zh-CN.md)

dbbbb is a local-first, open-source macOS database client for PostgreSQL, MySQL, MongoDB, and SQLite. It is a native Swift 6 application built with SwiftUI and SwiftPM, requiring macOS 15 or later. The goal: open a connection, locate data, and make safe, deliberate changes without the visual weight of a full database administration suite.

> **Note:** the repository also contains `src/`, the deprecated first-generation Electron implementation. It is kept for historical reference only and is no longer developed. The current product lives entirely under `swift/`.

## What works now

- Real connections to all four engines. PostgreSQL, MySQL support `disable`, `require`, and `verify-full` SSL modes; MongoDB supports SRV URIs with TLS enforced. SQLite opens local database files, optionally read-only.
- Object browsing, generated previews, and query execution with bounded results (500 rows / 5 MiB per result, 8 MiB per single value with an explicit truncation marker), targeted cancellation, and redacted error messages that never leak passwords, URIs, or local paths. Double-click a table or view to run its `SELECT … LIMIT 100` instantly (a MongoDB collection runs its find).
- View Create Statement for tables and views on PostgreSQL, MySQL, and SQLite: the DDL opens read-only in a monospaced, copyable sheet (a fail-closed capability — MongoDB and unsupported adapters never show it).
- Optional database field: PostgreSQL falls back to the `postgres` maintenance database; MySQL connects without a default schema and browses all non-system schemas server-wide.
- Read-only connections enforced twice: a client-side statement classifier plus server-side read-only settings.
- Reviewed single-record update/delete on all four engines: draft → review two-phase flow, optimistic conflict detection, and an extra typed confirmation on production profiles. Editing is a fail-closed capability — read-only profiles, non-preview results, or unsupported adapters simply never show edit entry points.
- CSV import into SQL tables and JSONL import into MongoDB collections (batched, bounded, cancellable); CSV and canonical JSONL export of the current bounded result, written atomically.
- Precision-safe display: bigints, decimals, non-finite numbers, and dates are always rendered as strings; MongoDB results round-trip through canonical Extended JSON with Decimal128 bit-level fidelity.
- Opt-in saved connections: the connection list lives under `~/Library/Application Support/dbbbb` with restrictive permissions, while passwords and credential-bearing MongoDB URIs are stored only in the macOS Keychain. Saved connections reconnect automatically at startup; reconnect failures surface a redacted banner and never drop the saved entry.
- A local query history and favorites library (bounded, credentials never persisted).
- Light, Dark, and System themes.

## Run locally

Prerequisites: macOS 15+, and an Xcode toolchain with Swift 6.x (Xcode 16 or later).

```bash
cd swift
swift build
swift run
```

The app starts with demo connections, so the UI can be explored without any database server. Use **New connection** to open a real session — the input is verified with a real round trip before the connection is added.

## Verify

```bash
cd swift
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The `DEVELOPER_DIR` prefix is only needed when `xcode-select` points at the Command Line Tools, which ship no XCTest; if an Xcode is already selected, plain `swift test` works. Build warnings are treated as errors by project discipline — keep `swift build` warning-free.

Integration tests skip automatically unless a server URL is provided via `DBBBB_TEST_POSTGRES_URL`, `DBBBB_TEST_MYSQL_URL`, or `DBBBB_TEST_MONGO_URL`, so the default suite needs no live database.

## Package

```bash
swift/Scripts/make-app.sh
```

This produces an ad-hoc-signed `swift/release/dbbbb.app` and `swift/release/dbbbb-<version>-macOS-<arch>.zip`. The version is derived from the exact git tag on `HEAD` (falling back to a script constant when untagged). Commands for upgrading to Developer ID signing and notarization are documented in the script header.

## Repository layout

- `swift/` — the current product: `dbbbbCore` (type contracts), `dbbbbKit` (engine adapters, persistence, transfers), `dbbbbApp` (SwiftUI shell), plus tests and the packaging script.
- `src/`, `docs/`, `package.json` — the deprecated Electron implementation and its documentation, kept for historical reference only.
- `HANDOVER.md` — current project status and handover notes.

## License

dbbbb is open source, released under the [MIT License](LICENSE).
