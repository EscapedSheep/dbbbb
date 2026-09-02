import { Buffer } from 'node:buffer'
import { Client, Pool, escapeIdentifier, types } from 'pg'
import type { ClientConfig, FieldDef, PoolClient, PoolConfig, QueryArrayResult } from 'pg'
import type {
  ApplyDataChangeResult,
  ConnectionProfile,
  DatabaseCommand,
  DatabaseObjectKind,
  DatabaseObjectNode,
  DatabaseResult,
  PostgresConnectionInput,
  PostgresSslMode,
  ResultColumn,
  WireValue
} from '../../shared/database'
import {
  planPostgresDelete,
  planPostgresUpdate
} from '../editing/change-planner'
import type { ByteSource } from '../transfers/delimited'
import { runCsvImport } from '../transfers/import-runner'
import type {
  AdapterDataChange,
  DatabaseAdapter,
  ExecuteOptions,
  ImportDataOptions,
  ImportDataSummary
} from './database-adapter'

const LIST_OBJECTS_SQL = `
SELECT n.nspname, c.relname, c.relkind
FROM pg_catalog.pg_namespace AS n
LEFT JOIN pg_catalog.pg_class AS c
  ON c.relnamespace = n.oid
 AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
WHERE n.nspname <> 'information_schema'
  AND n.nspname !~ '^pg_'
  AND pg_catalog.has_schema_privilege(n.oid, 'USAGE')
ORDER BY n.nspname, c.relname
`.trim()

const LIST_INSERTABLE_COLUMNS_SQL = `
SELECT a.attname
FROM pg_catalog.pg_attribute AS a
JOIN pg_catalog.pg_class AS c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = $1
  AND c.relname = $2
  AND c.relkind IN ('r', 'p', 'f')
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND a.attgenerated = ''
  AND a.attidentity <> 'a'
  AND pg_catalog.has_column_privilege(c.oid, a.attname, 'INSERT')
ORDER BY a.attnum
`.trim()

const LIST_TABLE_CHANGE_COLUMNS_SQL = `
SELECT
  a.attname,
  a.atttypid,
  t.typname,
  COALESCE(pk.primary_key_ordinal, 0) AS primary_key_ordinal
FROM pg_catalog.pg_attribute AS a
JOIN pg_catalog.pg_class AS c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_type AS t ON t.oid = a.atttypid
LEFT JOIN LATERAL (
  SELECT key.ordinality::integer AS primary_key_ordinal
  FROM pg_catalog.pg_index AS i
  CROSS JOIN LATERAL pg_catalog.unnest(i.indkey)
    WITH ORDINALITY AS key(attnum, ordinality)
  WHERE i.indrelid = c.oid
    AND i.indisprimary
    AND key.attnum = a.attnum
    AND key.ordinality <= i.indnkeyatts
) AS pk ON TRUE
WHERE n.nspname = $1
  AND c.relname = $2
  AND c.relkind IN ('r', 'p', 'f')
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND pg_catalog.has_column_privilege(c.oid, a.attname, 'UPDATE')
  AND pg_catalog.has_column_privilege(c.oid, a.attname, 'DELETE')
ORDER BY a.attnum
`.trim()

const BACKEND_PID_SQL = 'SELECT pg_catalog.pg_backend_pid()'
const CANCEL_BACKEND_SQL = 'SELECT pg_catalog.pg_cancel_backend($1)'
const DEFAULT_CONNECTION_TIMEOUT_MS = 10_000
const DEFAULT_STATEMENT_TIMEOUT_MS = 30_000
const DEFAULT_POOL_SIZE = 4
const DEFAULT_IMPORT_BATCH_SIZE = 500
const POSTGRES_MAX_PARAMETERS = 65_535
const MAX_ERROR_LENGTH = 600
const MAX_WIRE_DEPTH = 32
export const MAX_WIRE_VALUE_BYTES = 8 * 1024 * 1024

// Keep temporal values as the driver's raw text: parsing them into Date would
// reinterpret them in the host timezone and truncate microseconds, which breaks
// lossless round-trips for optimistic row changes.
for (const oid of [types.builtins.DATE, types.builtins.TIMESTAMP, types.builtins.TIMESTAMPTZ]) {
  types.setTypeParser(oid, (value: string) => value)
}

const ALLOWED_READ_ONLY_STARTERS = new Set([
  'EXPLAIN',
  'SELECT',
  'SHOW',
  'TABLE',
  'VALUES',
  'WITH'
])

const FORBIDDEN_READ_ONLY_TOKENS = new Set([
  'ALTER',
  'ANALYZE',
  'BEGIN',
  'CALL',
  'CHECKPOINT',
  'CLUSTER',
  'COMMENT',
  'COMMIT',
  'COPY',
  'CREATE',
  'DEALLOCATE',
  'DELETE',
  'DISCARD',
  'DO',
  'DROP',
  'EXECUTE',
  'GRANT',
  'INSERT',
  'INTO',
  'LISTEN',
  'LOAD',
  'LOCK',
  'MERGE',
  'MOVE',
  'NEXTVAL',
  'NOTIFY',
  'PG_ADVISORY_LOCK',
  'PG_ADVISORY_XACT_LOCK',
  'PG_CANCEL_BACKEND',
  'PG_RELOAD_CONF',
  'PG_ROTATE_LOGFILE',
  'PG_TERMINATE_BACKEND',
  'PG_TRY_ADVISORY_LOCK',
  'PG_TRY_ADVISORY_XACT_LOCK',
  'PREPARE',
  'REASSIGN',
  'REFRESH',
  'REINDEX',
  'RELEASE',
  'RESET',
  'REVOKE',
  'ROLLBACK',
  'SAVEPOINT',
  'SET',
  'SET_CONFIG',
  'SETVAL',
  'START',
  'TRUNCATE',
  'UNLISTEN',
  'UPDATE',
  'VACUUM'
])

const NUMERIC_TYPE_OIDS = new Set<number>([
  types.builtins.INT2,
  types.builtins.INT4,
  types.builtins.INT8,
  types.builtins.FLOAT4,
  types.builtins.FLOAT8,
  types.builtins.NUMERIC,
  types.builtins.MONEY,
  types.builtins.OID
])

const BUILTIN_TYPE_NAMES = new Map<number, string>(
  Object.entries(types.builtins).map(([name, oid]) => [oid, name.toLowerCase()])
)

// Types whose wire values cannot round-trip losslessly through an edit, so
// single-row changes refuse them at metadata time instead of misreporting an
// optimistic-concurrency conflict later. `json` (unlike `jsonb`) does not
// preserve key order/duplicates, `interval` and `money` are session-dependent,
// and range/multirange bounds do not survive a text round-trip unchanged.
const NON_ROUND_TRIPPING_TYPE_NAMES = new Set([
  'json',
  'interval',
  'money',
  'int4range',
  'int8range',
  'numrange',
  'tsrange',
  'tstzrange',
  'daterange',
  'int4multirange',
  'int8multirange',
  'nummultirange',
  'tsmultirange',
  'tstzmultirange',
  'datemultirange'
])

type ObjectRow = [schemaName: unknown, objectName: unknown, relationKind: unknown]
type InsertableColumnRow = [columnName: unknown]
type ChangeColumnRow = [
  columnName: unknown,
  typeOid: unknown,
  typeName: unknown,
  primaryKeyOrdinal: unknown
]

interface PostgresObjectRef {
  kind: 'schema' | 'table' | 'view'
  schema: string
  name?: string
}

interface ChangeTableMetadata {
  columns: string[]
  columnTypeOids: Map<string, number>
  primaryKey: string[]
}

interface ActiveExecution {
  client: PoolClient
  backendPid?: number
  timedOut: boolean
  cancelPromise?: Promise<void>
}

function validateInput(input: PostgresConnectionInput): void {
  if (
    input.engine !== 'postgresql' ||
    input.host.trim().length === 0 ||
    !Number.isInteger(input.port) ||
    input.port < 1 ||
    input.port > 65_535 ||
    input.username.trim().length === 0 ||
    input.database.trim().length === 0
  ) {
    throw new Error('PostgreSQL connection settings are invalid.')
  }
}

function sslConfig(mode: PostgresSslMode): PoolConfig['ssl'] {
  switch (mode) {
    case 'disable':
      return false
    case 'require':
      return { rejectUnauthorized: false }
    case 'verify-full':
      return { rejectUnauthorized: true }
  }
}

function clientConfig(input: PostgresConnectionInput): ClientConfig {
  return {
    host: input.host,
    port: input.port,
    user: input.username,
    password: input.password,
    database: input.database,
    ssl: sslConfig(input.sslMode),
    application_name: 'dbbbb',
    connectionTimeoutMillis: DEFAULT_CONNECTION_TIMEOUT_MS,
    statement_timeout: DEFAULT_STATEMENT_TIMEOUT_MS
  }
}

function poolConfig(input: PostgresConnectionInput): PoolConfig {
  return {
    ...clientConfig(input),
    idleTimeoutMillis: 30_000,
    max: DEFAULT_POOL_SIZE,
    options: input.readOnly ? '-c default_transaction_read_only=on' : undefined
  }
}

function relationKind(value: unknown): Extract<DatabaseObjectKind, 'table' | 'view'> | undefined {
  if (value === 'r' || value === 'p' || value === 'f') return 'table'
  if (value === 'v' || value === 'm') return 'view'
  return undefined
}

function objectId(ref: PostgresObjectRef): string {
  const encoded = Buffer.from(
    JSON.stringify([ref.kind, ref.schema, ref.name ?? null]),
    'utf8'
  ).toString('base64url')
  return `postgresql:${encoded}`
}

function assertProfile(profile: ConnectionProfile): void {
  if (profile.engine !== 'postgresql') {
    throw new Error('The selected connection is not a PostgreSQL connection.')
  }
}

function inspectSql(sql: string): string[] {
  let visible = ''
  let index = 0

  const skipQuoted = (quote: "'" | '"', escapeBackslash = false): void => {
    const start = index
    index += 1
    while (index < sql.length) {
      const character = sql[index]
      if (character === quote) {
        if (sql[index + 1] === quote) {
          index += 2
          continue
        }
        index += 1
        visible += ' '
        return
      }
      // Only E'...' escape strings treat backslash as an escape; with
      // standard_conforming_strings=on a plain string keeps it literally.
      if (escapeBackslash && character === '\\' && index + 1 < sql.length) {
        index += 2
        continue
      }
      index += 1
    }
    throw new Error(
      `Read-only mode could not safely classify SQL near character ${start + 1}.`
    )
  }

  while (index < sql.length) {
    if (sql.startsWith('--', index)) {
      const newline = sql.indexOf('\n', index + 2)
      index = newline === -1 ? sql.length : newline + 1
      visible += ' '
      continue
    }

    if (sql.startsWith('/*', index)) {
      const start = index
      let depth = 1
      index += 2
      while (index < sql.length && depth > 0) {
        if (sql.startsWith('/*', index)) {
          depth += 1
          index += 2
        } else if (sql.startsWith('*/', index)) {
          depth -= 1
          index += 2
        } else {
          index += 1
        }
      }
      if (depth !== 0) {
        throw new Error(
          `Read-only mode could not safely classify SQL near character ${start + 1}.`
        )
      }
      visible += ' '
      continue
    }

    if (sql[index] === "'") {
      // E'...'/e'...' escape strings only when the E/e is a standalone prefix,
      // not the tail of an identifier such as `mode`.
      const previous = sql[index - 1]
      const beforePrevious = sql[index - 2]
      const escapeString =
        (previous === 'E' || previous === 'e') &&
        (beforePrevious === undefined || !/[$\p{L}\p{N}_]/u.test(beforePrevious))
      skipQuoted("'", escapeString)
      continue
    }

    if (sql[index] === '"') {
      skipQuoted('"')
      continue
    }

    if (sql[index] === '$') {
      const tag = /^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(index))?.[0]
      if (tag) {
        const start = index
        const end = sql.indexOf(tag, index + tag.length)
        if (end === -1) {
          throw new Error(
            `Read-only mode could not safely classify SQL near character ${start + 1}.`
          )
        }
        index = end + tag.length
        visible += ' '
        continue
      }
    }

    visible += sql[index]
    index += 1
  }

  const statements = visible
    .split(';')
    .map((statement) => statement.trim())
    .filter(Boolean)

  if (statements.length !== 1) {
    throw new Error('Read-only connections only allow one SQL statement at a time.')
  }

  return statements[0].toUpperCase().match(/[A-Z_][A-Z0-9_$]*/g) ?? []
}

export function assertReadOnlySql(sql: string): void {
  const tokens = inspectSql(sql)
  if (tokens.length === 0 || !ALLOWED_READ_ONLY_STARTERS.has(tokens[0])) {
    throw new Error('Read-only connections only allow read-only SQL statements.')
  }

  const forbidden = tokens.find((token) => FORBIDDEN_READ_ONLY_TOKENS.has(token))
  if (forbidden) {
    throw new Error(`Read-only connections do not allow the SQL token ${forbidden}.`)
  }
}

function truncatedMarker(omittedBytes: number): string {
  return `…[dbbbb truncated ${omittedBytes} bytes]`
}

// A single oversized value must not materialize in full before the row byte
// budget applies; truncate it and mark the result so it is visibly incomplete.
function boundedWireString(text: string): string {
  const bytes = Buffer.byteLength(text, 'utf8')
  if (bytes <= MAX_WIRE_VALUE_BYTES) return text
  const kept = Buffer.from(text, 'utf8').subarray(0, MAX_WIRE_VALUE_BYTES).toString('utf8')
  return `${kept}${truncatedMarker(bytes - MAX_WIRE_VALUE_BYTES)}`
}

function boundedWireBinary(bytes: Buffer): WireValue {
  if (bytes.byteLength <= MAX_WIRE_VALUE_BYTES) return { $binary: bytes.toString('base64') }
  const kept = bytes.subarray(0, MAX_WIRE_VALUE_BYTES).toString('base64')
  return { $binary: `${kept}${truncatedMarker(bytes.byteLength - MAX_WIRE_VALUE_BYTES)}` }
}

export function toWireValue(
  value: unknown,
  seen: WeakSet<object> = new WeakSet<object>(),
  depth = 0
): WireValue {
  if (value === null || value === undefined) return null
  if (typeof value === 'string') return boundedWireString(value)
  if (typeof value === 'boolean') return value

  if (typeof value === 'number') {
    if (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value))) {
      return String(value)
    }
    return value
  }

  if (typeof value === 'bigint') return value.toString()
  if (typeof value === 'symbol' || typeof value === 'function') return String(value)

  // Defensive fallback: the driver is configured to return temporal values as
  // raw text, so a Date here did not come from a query result.
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? 'Invalid Date' : value.toISOString()
  }

  if (Buffer.isBuffer(value)) {
    return boundedWireBinary(value)
  }

  if (value instanceof Uint8Array) {
    return boundedWireBinary(Buffer.from(value))
  }

  if (value instanceof ArrayBuffer) {
    return boundedWireBinary(Buffer.from(value))
  }

  if (depth >= MAX_WIRE_DEPTH) return '[Maximum nesting depth reached]'

  if (Array.isArray(value)) {
    if (seen.has(value)) return '[Circular]'
    seen.add(value)
    try {
      return value.map((item) => toWireValue(item, seen, depth + 1))
    } finally {
      seen.delete(value)
    }
  }

  if (typeof value === 'object') {
    if (seen.has(value)) return '[Circular]'
    seen.add(value)
    try {
      const output = Object.create(null) as Record<string, WireValue>
      const keys = Object.keys(value)

      for (const key of keys) {
        const descriptor = Object.getOwnPropertyDescriptor(value, key)
        const nextValue = descriptor && 'value' in descriptor
          ? toWireValue(descriptor.value, seen, depth + 1)
          : '[Accessor value unavailable]'
        Object.defineProperty(output, key, {
          configurable: true,
          enumerable: true,
          writable: true,
          value: nextValue
        })
      }
      return output
    } finally {
      seen.delete(value)
    }
  }

  return String(value)
}

function resultColumns(fields: FieldDef[]): ResultColumn[] {
  const keyCounts = new Map<string, number>()
  return fields.map((field) => {
    const count = keyCounts.get(field.name) ?? 0
    keyCounts.set(field.name, count + 1)
    const key = count === 0 ? field.name : `${field.name}:${count}`
    const dataType = BUILTIN_TYPE_NAMES.get(field.dataTypeID) ?? `oid:${field.dataTypeID}`
    const align = field.dataTypeID === types.builtins.BOOL
      ? 'center'
      : NUMERIC_TYPE_OIDS.has(field.dataTypeID)
        ? 'end'
        : 'start'
    return { key, label: field.name, dataType, align }
  })
}

export function boundedRows(
  rawRows: unknown[][],
  maxRows: number,
  maxBytes: number
): { rows: WireValue[][]; truncated: boolean } {
  const candidates = rawRows.slice(0, maxRows + 1)
  const rows: WireValue[][] = []
  let bytes = 0
  let truncated = rawRows.length > maxRows

  for (const rawRow of candidates.slice(0, maxRows)) {
    const row = rawRow.map((value) => toWireValue(value))
    const rowBytes = Buffer.byteLength(JSON.stringify(row), 'utf8')
    if (bytes + rowBytes > maxBytes) {
      truncated = true
      break
    }
    bytes += rowBytes
    rows.push(row)
  }

  return { rows, truncated }
}

function validateExecuteOptions(options: ExecuteOptions): void {
  if (
    options.requestId.trim().length === 0 ||
    options.requestId.length > 128 ||
    !Number.isInteger(options.timeoutMs) ||
    options.timeoutMs < 0 ||
    !Number.isInteger(options.maxRows) ||
    options.maxRows < 1 ||
    !Number.isInteger(options.maxBytes) ||
    options.maxBytes < 1
  ) {
    throw new Error('PostgreSQL execution options are invalid.')
  }
}

function isCancellationError(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false
  const candidate = error as { code?: unknown; message?: unknown }
  return candidate.code === '57014' ||
    (typeof candidate.message === 'string' && /cancel(?:ing|led) statement/i.test(candidate.message))
}

function isStatementTimeoutError(error: unknown): boolean {
  return errorMessage(error).toLowerCase().includes('statement timeout')
}

// Errors whose connection must not return to the pool: SQLSTATE class 08
// (connection exception) and 57P0x (server shutdown/crash), Node errno codes
// such as ECONNRESET, and driver-raised termination reports.
function isConnectionFailure(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false
  const code = (error as { code?: unknown }).code
  if (typeof code === 'string') {
    if (/^[0-9A-Z]{5}$/.test(code)) return code.startsWith('08') || code.startsWith('57P0')
    return true
  }
  return errorMessage(error).toLowerCase().includes('connection')
}

function cancellationError(): Error & { code: string } {
  return Object.assign(new Error('PostgreSQL query was cancelled.'), { code: '57014' })
}

function isAbortError(error: unknown, signal?: AbortSignal): boolean {
  return Boolean(
    signal?.aborted ||
    (error && typeof error === 'object' && (error as { name?: unknown }).name === 'AbortError')
  )
}

function throwIfImportAborted(signal?: AbortSignal): void {
  if (!signal?.aborted) return
  const error = new Error('PostgreSQL import was aborted.')
  error.name = 'AbortError'
  throw error
}

export function postgresImportBatchSize(columnCount: number): number {
  if (!Number.isSafeInteger(columnCount) || columnCount < 1) {
    throw new Error('PostgreSQL import requires at least one insertable column.')
  }
  const parameterBound = Math.floor(POSTGRES_MAX_PARAMETERS / columnCount)
  if (parameterBound < 1) {
    throw new Error('PostgreSQL import has too many columns for a parameterized insert.')
  }
  return Math.min(DEFAULT_IMPORT_BATCH_SIZE, parameterBound)
}

function postgresInsertQuery(
  ref: PostgresObjectRef,
  allowedColumns: ReadonlySet<string>,
  rows: readonly Record<string, string>[]
): { text: string; values: string[] } {
  if (rows.length === 0) throw new Error('PostgreSQL import received an empty batch.')
  const columns = Object.keys(rows[0])
  if (columns.length === 0 || columns.some((column) => !allowedColumns.has(column))) {
    throw new Error('PostgreSQL import batch contains an invalid column mapping.')
  }
  const parameterCount = columns.length * rows.length
  if (!Number.isSafeInteger(parameterCount) || parameterCount > POSTGRES_MAX_PARAMETERS) {
    throw new Error('PostgreSQL import batch exceeds the parameter limit.')
  }

  const values: string[] = []
  const tuples = rows.map((row) => {
    const rowColumns = Object.keys(row)
    if (
      rowColumns.length !== columns.length ||
      rowColumns.some((column, index) => column !== columns[index])
    ) {
      throw new Error('PostgreSQL import batch has inconsistent columns.')
    }
    const placeholders = columns.map((column) => {
      const descriptor = Object.getOwnPropertyDescriptor(row, column)
      if (!descriptor || !('value' in descriptor) || typeof descriptor.value !== 'string') {
        throw new Error('PostgreSQL import batch contains an invalid field value.')
      }
      values.push(descriptor.value)
      return `$${values.length}`
    })
    return `(${placeholders.join(', ')})`
  })

  return {
    text: [
      `INSERT INTO ${escapeIdentifier(ref.schema)}.${escapeIdentifier(ref.name as string)}`,
      `(${columns.map((column) => escapeIdentifier(column)).join(', ')})`,
      `VALUES ${tuples.join(',\n       ')}`
    ].join('\n'),
    values
  }
}

function changeTableMetadata(rows: ChangeColumnRow[]): ChangeTableMetadata {
  if (rows.length === 0) {
    throw new Error('PostgreSQL change target no longer has editable table columns.')
  }

  const columns: string[] = []
  const columnNames = new Set<string>()
  const columnTypeOids = new Map<string, number>()
  const primaryKeyEntries: Array<{ column: string; ordinal: number }> = []
  const primaryKeyOrdinals = new Set<number>()

  for (const [columnValue, typeOidValue, typeNameValue, ordinalValue] of rows) {
    if (
      typeof columnValue !== 'string' ||
      columnValue.length === 0 ||
      !Number.isSafeInteger(typeOidValue) ||
      (typeOidValue as number) <= 0 ||
      typeof typeNameValue !== 'string' ||
      typeNameValue.length === 0 ||
      !Number.isSafeInteger(ordinalValue) ||
      (ordinalValue as number) < 0 ||
      columnNames.has(columnValue)
    ) {
      throw new Error('PostgreSQL returned invalid table-change metadata.')
    }
    // Array element types share the same round-trip limits as their base type.
    const baseTypeName = typeNameValue.replace(/^_/, '')
    if (NON_ROUND_TRIPPING_TYPE_NAMES.has(baseTypeName)) {
      throw new Error(
        `PostgreSQL row changes cannot edit column ${JSON.stringify(columnValue)}: ` +
        `type ${typeNameValue} values do not round-trip losslessly.`
      )
    }
    const ordinal = ordinalValue as number
    columns.push(columnValue)
    columnNames.add(columnValue)
    columnTypeOids.set(columnValue, typeOidValue as number)
    if (ordinal > 0) {
      if (primaryKeyOrdinals.has(ordinal)) {
        throw new Error('PostgreSQL returned invalid primary-key metadata.')
      }
      primaryKeyOrdinals.add(ordinal)
      primaryKeyEntries.push({ column: columnValue, ordinal })
    }
  }

  primaryKeyEntries.sort((left, right) => left.ordinal - right.ordinal)
  if (primaryKeyEntries.length === 0) {
    throw new Error('PostgreSQL single-row changes require a table primary key.')
  }
  if (primaryKeyEntries.some((entry, index) => entry.ordinal !== index + 1)) {
    throw new Error('PostgreSQL returned invalid primary-key ordering metadata.')
  }

  return {
    columns,
    columnTypeOids,
    primaryKey: primaryKeyEntries.map((entry) => entry.column)
  }
}

const CANONICAL_BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/

function postgresChangeValue(
  value: WireValue,
  column: string,
  typeOid: number,
  label: string
): unknown {
  if (typeOid !== types.builtins.BYTEA || value === null) return value

  if (typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label}.${column} must be a canonical PostgreSQL binary value.`)
  }
  const prototype = Object.getPrototypeOf(value)
  const keys = Reflect.ownKeys(value)
  const descriptor = Object.getOwnPropertyDescriptor(value, '$binary')
  if (
    (prototype !== Object.prototype && prototype !== null) ||
    keys.length !== 1 ||
    keys[0] !== '$binary' ||
    !descriptor?.enumerable ||
    !('value' in descriptor) ||
    typeof descriptor.value !== 'string' ||
    !CANONICAL_BASE64.test(descriptor.value)
  ) {
    throw new Error(`${label}.${column} must be a canonical PostgreSQL binary value.`)
  }

  const decoded = Buffer.from(descriptor.value, 'base64')
  if (decoded.toString('base64') !== descriptor.value) {
    throw new Error(`${label}.${column} must be a canonical PostgreSQL binary value.`)
  }
  return decoded
}

function normalizedChangeRecord(
  record: AdapterDataChange['original'],
  metadata: ChangeTableMetadata,
  label: string
): Record<string, unknown> {
  if (record === null || typeof record !== 'object' || Array.isArray(record)) {
    throw new Error(`${label} must be a plain record.`)
  }
  const prototype = Object.getPrototypeOf(record)
  if (prototype !== Object.prototype && prototype !== null) {
    throw new Error(`${label} must be a plain record.`)
  }

  const allowedColumns = new Set(metadata.columns)
  const values = new Map<string, WireValue>()
  for (const key of Reflect.ownKeys(record)) {
    if (typeof key !== 'string' || !allowedColumns.has(key)) {
      throw new Error(`${label} contains an unknown table field.`)
    }
    const descriptor = Object.getOwnPropertyDescriptor(record, key)
    if (!descriptor?.enumerable || !('value' in descriptor)) {
      throw new Error(`${label} must contain only enumerable data fields.`)
    }
    values.set(key, descriptor.value)
  }

  const normalized = Object.create(null) as Record<string, unknown>
  for (const column of metadata.columns) {
    if (!values.has(column)) continue
    Object.defineProperty(normalized, column, {
      configurable: true,
      enumerable: true,
      writable: true,
      value: postgresChangeValue(
        values.get(column) as WireValue,
        column,
        metadata.columnTypeOids.get(column) as number,
        label
      )
    })
  }
  return normalized
}

function primaryKeySnapshot(
  metadata: ChangeTableMetadata,
  original: Record<string, unknown>,
  current?: Record<string, unknown>
): Record<string, unknown> {
  const primaryKey = Object.create(null) as Record<string, unknown>
  for (const column of metadata.primaryKey) {
    if (!Object.prototype.hasOwnProperty.call(original, column)) {
      throw new Error('PostgreSQL change payload is missing a primary-key value.')
    }
    if (current && !Object.prototype.hasOwnProperty.call(current, column)) {
      throw new Error('PostgreSQL current values are missing a primary-key value.')
    }
    Object.defineProperty(primaryKey, column, {
      configurable: true,
      enumerable: true,
      writable: true,
      value: original[column]
    })
  }
  return primaryKey
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  if (error && typeof error === 'object' && typeof (error as { message?: unknown }).message === 'string') {
    return (error as { message: string }).message
  }
  return 'Unexpected database error.'
}

function sanitizedError(action: string, error: unknown, secrets: string[]): Error {
  let message = errorMessage(error)
  for (const secret of secrets) {
    if (secret.length > 0) {
      message = message.split(secret).join('[redacted]')
      const encoded = encodeURIComponent(secret)
      if (encoded !== secret) message = message.split(encoded).join('[redacted]')
    }
  }

  message = message
    .replace(/\bpostgres(?:ql)?:\/\/[^\s/@]+(?::[^@\s]*)?@/gi, 'postgresql://[redacted]@')
    .replace(/\b(password|passwd|pwd)\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)/gi, '$1=[redacted]')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_ERROR_LENGTH)

  const safe = new Error(`${action}: ${message || 'Unexpected database error.'}`)
  safe.name = 'PostgresAdapterError'
  const code = error && typeof error === 'object' ? (error as { code?: unknown }).code : undefined
  if (typeof code === 'string' && /^[0-9A-Z]{5}$/.test(code)) {
    ;(safe as Error & { code?: string }).code = code
  }
  return safe
}

function finalQueryResult(
  result: QueryArrayResult<unknown[]> | QueryArrayResult<unknown[]>[]
): QueryArrayResult<unknown[]> {
  if (!Array.isArray(result)) return result
  const last = result.at(-1)
  if (!last) throw new Error('PostgreSQL returned no query result.')
  return last
}

export class PostgresAdapter implements DatabaseAdapter {
  readonly engine = 'postgresql' as const

  private readonly input: PostgresConnectionInput
  private readonly pool: Pool
  private readonly objects = new Map<string, PostgresObjectRef>()
  private readonly activeExecutions = new Map<string, ActiveExecution>()
  private readonly requestIds = new Set<string>()
  private readonly cancelledRequestIds = new Set<string>()
  private connected = false
  private closed = false
  private connectPromise?: Promise<void>
  private closePromise?: Promise<void>

  constructor(input: PostgresConnectionInput) {
    validateInput(input)
    this.input = { ...input }
    this.pool = new Pool(poolConfig(this.input))
  }

  async connect(): Promise<void> {
    this.assertOpen()
    if (this.connected) return
    if (this.connectPromise) return this.connectPromise

    this.connectPromise = (async () => {
      let client: PoolClient | undefined
      try {
        client = await this.pool.connect()
        this.connected = true
      } catch (error) {
        throw sanitizedError('Could not connect to PostgreSQL', error, [this.input.password])
      } finally {
        client?.release()
      }
    })()

    try {
      await this.connectPromise
    } finally {
      this.connectPromise = undefined
    }
  }

  async listObjects(profile: ConnectionProfile): Promise<DatabaseObjectNode[]> {
    assertProfile(profile)
    await this.connect()

    try {
      const result = await this.pool.query<ObjectRow>({
        text: LIST_OBJECTS_SQL,
        rowMode: 'array'
      })
      const bySchema = new Map<string, PostgresObjectRef[]>()

      for (const [schemaValue, nameValue, relationValue] of result.rows) {
        if (typeof schemaValue !== 'string') {
          throw new Error('PostgreSQL returned invalid schema metadata.')
        }
        const schemaObjects = bySchema.get(schemaValue) ?? []
        bySchema.set(schemaValue, schemaObjects)

        if (nameValue === null && relationValue === null) continue
        const kind = relationKind(relationValue)
        if (typeof nameValue !== 'string' || !kind) {
          throw new Error('PostgreSQL returned invalid object metadata.')
        }
        schemaObjects.push({ kind, schema: schemaValue, name: nameValue })
      }

      const nextObjects = new Map<string, PostgresObjectRef>()
      const nodes: DatabaseObjectNode[] = []
      for (const [schema, schemaObjects] of bySchema) {
        const schemaRef: PostgresObjectRef = { kind: 'schema', schema }
        const schemaId = objectId(schemaRef)
        nextObjects.set(schemaId, schemaRef)
        nodes.push({
          id: schemaId,
          name: schema,
          kind: 'schema',
          detail: `${schemaObjects.length} ${schemaObjects.length === 1 ? 'object' : 'objects'}`
        })

        for (const ref of schemaObjects) {
          const id = objectId(ref)
          nextObjects.set(id, ref)
          nodes.push({
            id,
            parentId: schemaId,
            name: ref.name as string,
            kind: ref.kind
          })
        }
      }

      this.objects.clear()
      for (const [id, ref] of nextObjects) this.objects.set(id, ref)
      return nodes
    } catch (error) {
      throw sanitizedError('Could not list PostgreSQL objects', error, [this.input.password])
    }
  }

  async previewObject(
    profile: ConnectionProfile,
    id: string
  ): Promise<DatabaseCommand> {
    assertProfile(profile)
    this.assertOpen()
    const ref = this.objects.get(id)
    if (!ref || ref.kind === 'schema' || !ref.name) {
      throw new Error('This PostgreSQL object cannot be previewed.')
    }

    return {
      engine: 'postgresql',
      kind: 'query',
      text: `SELECT *\nFROM ${escapeIdentifier(ref.schema)}.${escapeIdentifier(ref.name)}\nLIMIT 100;`
    }
  }

  async execute(
    profile: ConnectionProfile,
    command: DatabaseCommand,
    options: ExecuteOptions
  ): Promise<DatabaseResult> {
    assertProfile(profile)
    validateExecuteOptions(options)
    if (command.engine !== this.engine || command.kind !== 'query') {
      throw new Error('The selected PostgreSQL connection only accepts SQL queries.')
    }
    if (command.text.trim().length === 0) {
      throw new Error('PostgreSQL query cannot be empty.')
    }
    if (this.input.readOnly || profile.readOnly) assertReadOnlySql(command.text)
    if (this.requestIds.has(options.requestId)) {
      throw new Error('A PostgreSQL query with this request id is already running.')
    }

    this.requestIds.add(options.requestId)

    let client: PoolClient | undefined
    let execution: ActiveExecution | undefined
    let timeout: NodeJS.Timeout | undefined
    let releaseError: Error | undefined
    const startedAt = Date.now()

    try {
      await this.connect()
      if (this.cancelledRequestIds.has(options.requestId)) throw cancellationError()

      client = await this.pool.connect()
      if (this.cancelledRequestIds.has(options.requestId)) throw cancellationError()

      execution = {
        client,
        timedOut: false
      }
      this.activeExecutions.set(options.requestId, execution)

      const pidResult = await client.query<[number]>({ text: BACKEND_PID_SQL, rowMode: 'array' })
      const backendPid = Number(pidResult.rows[0]?.[0])
      if (!Number.isSafeInteger(backendPid) || backendPid <= 0) {
        throw new Error('PostgreSQL returned an invalid backend process id.')
      }
      execution.backendPid = backendPid
      if (this.cancelledRequestIds.has(options.requestId)) throw cancellationError()

      if (options.timeoutMs > 0) {
        timeout = setTimeout(() => {
          if (!execution) return
          execution.timedOut = true
          void this.dispatchCancel(execution).catch(() => undefined)
        }, options.timeoutMs)
        timeout.unref?.()
      }

      const rawResult = await client.query<unknown[]>({
        text: command.text,
        rowMode: 'array'
      }) as QueryArrayResult<unknown[]> | QueryArrayResult<unknown[]>[]
      if (execution.timedOut || this.cancelledRequestIds.has(options.requestId)) {
        throw cancellationError()
      }
      const result = finalQueryResult(rawResult)
      const bounded = boundedRows(result.rows, options.maxRows, options.maxBytes)

      return {
        kind: 'rows',
        columns: resultColumns(result.fields),
        rows: bounded.rows,
        meta: {
          elapsedMs: Math.max(0, Date.now() - startedAt),
          count: bounded.rows.length,
          truncated: bounded.truncated,
          source: 'database'
        }
      }
    } catch (error) {
      if (client && isConnectionFailure(error)) {
        releaseError = error instanceof Error ? error : new Error(errorMessage(error))
      }
      const wasCancelled = this.cancelledRequestIds.has(options.requestId)
      if (wasCancelled || isCancellationError(error)) {
        const timedOut = execution?.timedOut || (!wasCancelled && isStatementTimeoutError(error))
        throw new Error(timedOut
          ? 'PostgreSQL query timed out.'
          : 'PostgreSQL query was cancelled.')
      }
      throw sanitizedError('PostgreSQL query failed', error, [this.input.password])
    } finally {
      if (timeout) clearTimeout(timeout)
      if (this.activeExecutions.get(options.requestId) === execution) {
        this.activeExecutions.delete(options.requestId)
      }
      this.cancelledRequestIds.delete(options.requestId)
      this.requestIds.delete(options.requestId)
      // Passing an error destroys the client instead of pooling a broken one.
      client?.release(releaseError)
    }
  }

  async applyDataChange(
    profile: ConnectionProfile,
    objectIdValue: string,
    change: AdapterDataChange
  ): Promise<ApplyDataChangeResult> {
    assertProfile(profile)
    this.assertOpen()
    if (this.input.readOnly || profile.readOnly) {
      throw new Error('PostgreSQL row changes are disabled for read-only connections.')
    }
    if (profile.demo) {
      throw new Error('PostgreSQL row changes require a real database connection.')
    }
    if (change.action !== 'update' && change.action !== 'delete') {
      throw new Error('PostgreSQL row change action is invalid.')
    }
    if (change.action === 'update' && !change.current) {
      throw new Error('PostgreSQL update requires current row values.')
    }

    const ref = this.objects.get(objectIdValue)
    if (!ref || ref.kind !== 'table' || !ref.name) {
      throw new Error('PostgreSQL row changes require an introspected table target.')
    }

    await this.connect()
    let client: PoolClient | undefined
    let transactionStarted = false
    let releaseError: Error | undefined
    try {
      client = await this.pool.connect()
      await client.query('BEGIN')
      transactionStarted = true

      const metadataResult = await client.query<ChangeColumnRow>({
        text: LIST_TABLE_CHANGE_COLUMNS_SQL,
        values: [ref.schema, ref.name],
        rowMode: 'array'
      })
      const metadata = changeTableMetadata(metadataResult.rows)
      const original = normalizedChangeRecord(
        change.original,
        metadata,
        'PostgreSQL original values'
      )
      const current = change.current
        ? normalizedChangeRecord(change.current, metadata, 'PostgreSQL current values')
        : undefined
      const primaryKey = primaryKeySnapshot(
        metadata,
        original,
        change.action === 'update' ? current : undefined
      )
      const plan = change.action === 'update'
        ? planPostgresUpdate({
            schema: ref.schema,
            table: ref.name,
            primaryKey,
            original,
            current: current as Record<string, unknown>
          })
        : planPostgresDelete({
            schema: ref.schema,
            table: ref.name,
            primaryKey,
            original
          })

      const result = await client.query<unknown[]>({
        text: plan.text,
        values: plan.values,
        rowMode: 'array'
      })
      if (result.rowCount === 0) {
        throw new Error(
          'PostgreSQL optimistic-concurrency conflict: the row changed or no longer exists.'
        )
      }
      if (result.rowCount !== 1) {
        throw new Error('PostgreSQL refused a row change with an unexpected affected-row count.')
      }

      await client.query('COMMIT')
      transactionStarted = false
      return { action: change.action, affected: 1 }
    } catch (error) {
      if (client && isConnectionFailure(error)) {
        releaseError = error instanceof Error ? error : new Error(errorMessage(error))
      }
      if (transactionStarted && client) {
        await client.query('ROLLBACK').catch(() => undefined)
      }
      throw sanitizedError('PostgreSQL data change failed', error, [this.input.password])
    } finally {
      client?.release(releaseError)
    }
  }

  async importData(
    profile: ConnectionProfile,
    objectIdValue: string,
    source: ByteSource,
    options: ImportDataOptions
  ): Promise<ImportDataSummary> {
    assertProfile(profile)
    this.assertOpen()
    if (options.format !== 'csv') {
      throw new Error('PostgreSQL import only supports CSV files.')
    }
    if (this.input.readOnly || profile.readOnly) {
      throw new Error('PostgreSQL import is disabled for read-only connections.')
    }

    const ref = this.objects.get(objectIdValue)
    if (!ref || ref.kind !== 'table' || !ref.name) {
      throw new Error('PostgreSQL import requires an introspected table target.')
    }

    await this.connect()
    let client: PoolClient | undefined
    let transactionStarted = false
    let releaseError: Error | undefined

    try {
      throwIfImportAborted(options.signal)
      client = await this.pool.connect()
      throwIfImportAborted(options.signal)

      const columnResult = await client.query<InsertableColumnRow>({
        text: LIST_INSERTABLE_COLUMNS_SQL,
        values: [ref.schema, ref.name],
        rowMode: 'array'
      })
      const columns = columnResult.rows.map(([column]) => {
        if (typeof column !== 'string' || column.length === 0) {
          throw new Error('PostgreSQL returned invalid insertable-column metadata.')
        }
        return column
      })
      if (new Set(columns).size !== columns.length) {
        throw new Error('PostgreSQL returned duplicate insertable-column metadata.')
      }
      const batchSize = postgresImportBatchSize(columns.length)
      const allowedColumns = new Set(columns)

      throwIfImportAborted(options.signal)
      await client.query('BEGIN')
      transactionStarted = true

      const imported = await runCsvImport(source, {
        knownColumns: columns,
        explicitHeader: options.hasHeader ? undefined : columns,
        trimHeaders: false,
        batchSize,
        signal: options.signal,
        onProgress: options.onProgress,
        errorMode: 'all-or-stop',
        async insertRows(rows, context) {
          throwIfImportAborted(context.signal)
          const query = postgresInsertQuery(ref, allowedColumns, rows)
          await client!.query(query)
          throwIfImportAborted(context.signal)
          return rows.length
        }
      })

      throwIfImportAborted(options.signal)
      await client.query('COMMIT')
      transactionStarted = false
      return {
        processed: imported.progress.processed,
        inserted: imported.progress.inserted,
        failed: imported.progress.failed
      }
    } catch (error) {
      if (client && isConnectionFailure(error)) {
        releaseError = error instanceof Error ? error : new Error(errorMessage(error))
      }
      if (transactionStarted && client) {
        await client.query('ROLLBACK').catch(() => undefined)
      }
      if (isAbortError(error, options.signal)) {
        throw new Error('PostgreSQL import was aborted.')
      }
      throw sanitizedError('PostgreSQL import failed', error, [this.input.password])
    } finally {
      client?.release(releaseError)
    }
  }

  async cancel(requestId: string): Promise<void> {
    if (!this.requestIds.has(requestId)) return
    this.cancelledRequestIds.add(requestId)
    const execution = this.activeExecutions.get(requestId)
    if (!execution) return
    if (!execution.backendPid) return

    try {
      await this.dispatchCancel(execution)
    } catch (error) {
      throw sanitizedError('Could not cancel PostgreSQL query', error, [this.input.password])
    }
  }

  async close(): Promise<void> {
    if (this.closePromise) return this.closePromise
    if (this.closed) return

    this.closePromise = (async () => {
      try {
        for (const requestId of this.requestIds) this.cancelledRequestIds.add(requestId)
        const active = [...this.activeExecutions.values()].filter(
          (execution) => execution.backendPid !== undefined
        )
        await Promise.allSettled(active.map((execution) => this.dispatchCancel(execution)))
        await this.pool.end()
      } catch (error) {
        throw sanitizedError('Could not close PostgreSQL', error, [this.input.password])
      } finally {
        this.connected = false
        this.closed = true
        this.objects.clear()
      }
    })()

    return this.closePromise
  }

  private assertOpen(): void {
    if (this.closed || this.closePromise) {
      throw new Error('The PostgreSQL connection is closed.')
    }
  }

  private dispatchCancel(execution: ActiveExecution): Promise<void> {
    if (execution.cancelPromise) return execution.cancelPromise

    execution.cancelPromise = (async () => {
      const backendPid = execution.backendPid
      if (!backendPid) return

      // A dedicated out-of-pool client: cancellation must not queue behind a
      // saturated pool (max is only DEFAULT_POOL_SIZE connections).
      const cancelClient = new Client(clientConfig(this.input))
      await cancelClient.connect()
      try {
        const result = await cancelClient.query<[boolean]>({
          text: CANCEL_BACKEND_SQL,
          values: [backendPid],
          rowMode: 'array'
        })
        if (result.rows[0]?.[0] !== true) {
          throw new Error('PostgreSQL did not accept the cancellation request.')
        }
      } finally {
        await cancelClient.end().catch(() => undefined)
      }
    })()

    return execution.cancelPromise
  }
}
