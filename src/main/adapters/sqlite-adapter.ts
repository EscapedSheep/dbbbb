// SQLite adapter on Electron's built-in Node `node:sqlite` (DatabaseSync), so
// there is no native dependency to ship. Two known trade-offs, pinned by tests:
// - DatabaseSync is synchronous: every statement runs on the main-process
//   event loop, so a long query blocks the UI until it finishes. timeoutMs is
//   validated for contract parity but cannot interrupt a running statement.
// - node:sqlite exposes no interrupt API, so cancel() is explicitly
//   unsupported (it throws without side effects) instead of pretending to work.
import { Buffer } from 'node:buffer'
import { DatabaseSync } from 'node:sqlite'
import type {
  ConnectionProfile,
  DatabaseCommand,
  DatabaseObjectNode,
  DatabaseResult,
  ResultColumn,
  SqliteConnectionInput
} from '../../shared/database'
import type { DatabaseAdapter, ExecuteOptions } from './database-adapter'
import { boundedRows, toWireValue } from './postgres-adapter'

const LIST_OBJECTS_SQL = `
SELECT name, type
FROM sqlite_master
WHERE type IN ('table', 'view')
  AND name NOT LIKE 'sqlite_%'
ORDER BY name
`.trim()

const PREVIEW_LIMIT = 100
const MAX_ERROR_LENGTH = 600

const ALLOWED_READ_ONLY_STARTERS = new Set(['EXPLAIN', 'SELECT', 'WITH'])

// Conservative, fail-closed: WITH can prefix writes in SQLite and writable
// PRAGMAs (e.g. writable_schema) mutate the database, so the starter check
// alone is not enough and PRAGMA is never allowed through.
const FORBIDDEN_READ_ONLY_TOKENS = new Set([
  'ALTER',
  'ANALYZE',
  'ATTACH',
  'BEGIN',
  'COMMIT',
  'CREATE',
  'DELETE',
  'DETACH',
  'DROP',
  'END',
  'INSERT',
  'PRAGMA',
  'REINDEX',
  'RELEASE',
  'REPLACE',
  'ROLLBACK',
  'SAVEPOINT',
  'TRANSACTION',
  'UPDATE',
  'VACUUM'
])

interface SqliteObjectRef {
  kind: 'schema' | 'table' | 'view'
  name?: string
}

interface SqliteColumnInfo {
  name: string | null
  type: string | null
}

function validateInput(input: SqliteConnectionInput): void {
  if (
    input.engine !== 'sqlite' ||
    input.filePath.trim().length === 0 ||
    input.filePath.includes('\0')
  ) {
    throw new Error('SQLite connection settings are invalid.')
  }
}

function assertProfile(profile: ConnectionProfile): void {
  if (profile.engine !== 'sqlite') {
    throw new Error('The selected connection is not a SQLite connection.')
  }
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
    throw new Error('SQLite execution options are invalid.')
  }
}

function objectId(ref: SqliteObjectRef): string {
  const encoded = Buffer.from(
    JSON.stringify([ref.kind, ref.name ?? null]),
    'utf8'
  ).toString('base64url')
  return `sqlite:${encoded}`
}

function quoteIdentifier(name: string): string {
  return `"${name.replaceAll('"', '""')}"`
}

// Strips comments (-- and /* */) and quoted literals/identifiers, then
// enforces exactly one statement. Returns the statement's uppercase tokens.
// Anything ambiguous (unterminated quotes/comments) throws, so callers fail
// closed instead of guessing at intent.
function inspectSql(sql: string): string[] {
  let visible = ''
  let index = 0

  const skipQuoted = (quote: "'" | '"' | '`'): void => {
    const start = index
    index += 1
    while (index < sql.length) {
      if (sql[index] === quote) {
        if (sql[index + 1] === quote) {
          index += 2
          continue
        }
        index += 1
        visible += ' '
        return
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
      // SQLite block comments do not nest; treating nested openers as fatal
      // keeps the classifier fail-closed where the two grammars disagree.
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

    const character = sql[index]
    if (character === "'" || character === '"' || character === '`') {
      skipQuoted(character)
      continue
    }

    if (sql[index] === '[') {
      const start = index
      const end = sql.indexOf(']', index + 1)
      if (end === -1) {
        throw new Error(
          `Read-only mode could not safely classify SQL near character ${start + 1}.`
        )
      }
      index = end + 1
      visible += ' '
      continue
    }

    visible += sql[index]
    index += 1
  }

  const statements = visible
    .split(';')
    .map((statement) => statement.trim())
    .filter(Boolean)

  if (statements.length !== 1) {
    throw new Error('SQLite connections only allow one SQL statement at a time.')
  }

  return statements[0].toUpperCase().match(/[A-Z_][A-Z0-9_]*/g) ?? []
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

// SQLite type-affinity rules: a declared type containing INT is integer
// affinity, REAL/FLOA/DOUB is real, and NUMERIC/DECIMAL/anything else numeric
// is numeric; everything else stays start-aligned text/blob.
function columnAlign(declaredType: string | null): 'start' | 'end' {
  const type = declaredType?.toUpperCase() ?? ''
  if (/INT|REAL|FLOA|DOUB|NUMERIC|DECIMAL/.test(type)) return 'end'
  return 'start'
}

function resultColumns(columns: SqliteColumnInfo[]): ResultColumn[] {
  const keyCounts = new Map<string, number>()
  return columns.map((column, index) => {
    const label = column.name ?? `column_${index + 1}`
    const count = keyCounts.get(label) ?? 0
    keyCounts.set(label, count + 1)
    return {
      key: count === 0 ? label : `${label}:${count}`,
      label,
      dataType: column.type ?? 'unknown',
      align: columnAlign(column.type)
    }
  })
}

// node:sqlite only yields bigint when readBigInts is enabled; keep safe
// integers as numbers and stringify the rest so precision never silently
// degrades. Everything else defers to the shared wire conversion.
function toSqliteWireValue(value: unknown): unknown {
  if (typeof value !== 'bigint') return value
  const asNumber = Number(value)
  return Number.isSafeInteger(asNumber) && BigInt(asNumber) === value
    ? asNumber
    : value.toString()
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  if (error && typeof error === 'object' && typeof (error as { message?: unknown }).message === 'string') {
    return (error as { message: string }).message
  }
  return 'Unexpected database error.'
}

// SQLite errors can embed the database file path (and the query text); never
// leak a local filesystem path across the IPC boundary.
function sanitizedError(action: string, error: unknown, filePath: string): Error {
  let message = errorMessage(error)
  if (filePath.length > 0) {
    message = message.split(filePath).join('[local file]')
    const encoded = encodeURIComponent(filePath)
    if (encoded !== filePath) message = message.split(encoded).join('[local file]')
  }

  message = message
    .replace(/[a-zA-Z]:(?:\\[\w .@+-]+)+/g, '[local file]')
    .replace(/(?:\\[\w .@+-]+){2,}/g, '[local file]')
    .replace(/(?:\/[\w .@+-]+){2,}/g, '[local file]')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_ERROR_LENGTH)

  const safe = new Error(`${action}: ${message || 'Unexpected database error.'}`)
  safe.name = 'SqliteAdapterError'
  return safe
}

export class SqliteAdapter implements DatabaseAdapter {
  readonly engine = 'sqlite' as const

  private readonly input: SqliteConnectionInput
  private readonly objects = new Map<string, SqliteObjectRef>()
  private database?: DatabaseSync
  private closed = false

  constructor(input: SqliteConnectionInput) {
    validateInput(input)
    this.input = { ...input }
  }

  // Synchronous like everything else here; the async signature is the
  // DatabaseAdapter contract. Read-only profiles open the file read-only so
  // the OS/SQLite layer rejects writes even if the SQL classifier has a gap.
  async connect(): Promise<void> {
    this.assertOpen()
    if (this.database) return

    try {
      this.database = new DatabaseSync(this.input.filePath, {
        readOnly: this.input.readOnly
      })
    } catch (error) {
      throw sanitizedError('Could not open the SQLite database', error, this.input.filePath)
    }
  }

  async listObjects(profile: ConnectionProfile): Promise<DatabaseObjectNode[]> {
    assertProfile(profile)
    await this.connect()
    const database = this.database as DatabaseSync

    try {
      const rows = database.prepare(LIST_OBJECTS_SQL).all() as Array<Record<string, unknown>>
      const schemaRef: SqliteObjectRef = { kind: 'schema' }
      const schemaId = objectId(schemaRef)
      const nextObjects = new Map<string, SqliteObjectRef>([[schemaId, schemaRef]])
      const nodes: DatabaseObjectNode[] = []

      for (const row of rows) {
        const name = row.name
        const type = row.type
        if (typeof name !== 'string' || (type !== 'table' && type !== 'view')) {
          throw new Error('SQLite returned invalid object metadata.')
        }
        const ref: SqliteObjectRef = { kind: type, name }
        const id = objectId(ref)
        nextObjects.set(id, ref)
        nodes.push({ id, parentId: schemaId, name, kind: type })
      }

      this.objects.clear()
      for (const [id, ref] of nextObjects) this.objects.set(id, ref)

      return [
        {
          id: schemaId,
          name: 'main',
          kind: 'schema',
          detail: `${nodes.length} ${nodes.length === 1 ? 'object' : 'objects'}`
        },
        ...nodes
      ]
    } catch (error) {
      throw sanitizedError('Could not list SQLite objects', error, this.input.filePath)
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
      throw new Error('This SQLite object cannot be previewed.')
    }

    return {
      engine: 'sqlite',
      kind: 'query',
      text: `SELECT *\nFROM ${quoteIdentifier(ref.name)}\nLIMIT ${PREVIEW_LIMIT};`
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
      throw new Error('The selected SQLite connection only accepts SQL queries.')
    }
    if (command.text.trim().length === 0) {
      throw new Error('SQLite query cannot be empty.')
    }
    // prepare() would silently ignore anything after the first statement, so
    // multi-statement input is rejected for every profile, not just read-only.
    if (this.input.readOnly || profile.readOnly) assertReadOnlySql(command.text)
    else inspectSql(command.text)

    await this.connect()
    const database = this.database as DatabaseSync
    const startedAt = Date.now()

    try {
      const statement = database.prepare(command.text)
      // Bigints keep INTEGER precision past 2^53; array rows keep duplicate
      // column names addressable through ResultColumn keys.
      statement.setReadBigInts(true)
      statement.setReturnArrays(true)
      // Synchronous: blocks the main-process event loop until done.
      const rawRows = statement.all() as unknown as unknown[][]
      const columns = statement.columns() as SqliteColumnInfo[]

      const normalized = rawRows.map((row) => row.map(toSqliteWireValue))
      const bounded = boundedRows(normalized, options.maxRows, options.maxBytes)

      return {
        kind: 'rows',
        columns: resultColumns(columns),
        rows: bounded.rows,
        meta: {
          elapsedMs: Math.max(0, Date.now() - startedAt),
          count: bounded.rows.length,
          truncated: bounded.truncated,
          source: 'database'
        }
      }
    } catch (error) {
      throw sanitizedError('SQLite query failed', error, this.input.filePath)
    }
  }

  // node:sqlite has no interrupt API and statements run synchronously, so
  // there is nothing to cancel: fail loudly instead of silently no-oping.
  // This is a deliberate, side-effect-free "unsupported".
  async cancel(_requestId: string): Promise<void> {
    throw new Error('SQLite queries cannot be cancelled; statements run to completion.')
  }

  async close(): Promise<void> {
    if (this.closed) return
    try {
      this.database?.close()
    } catch (error) {
      throw sanitizedError('Could not close the SQLite database', error, this.input.filePath)
    } finally {
      this.database = undefined
      this.closed = true
      this.objects.clear()
    }
  }

  private assertOpen(): void {
    if (this.closed) {
      throw new Error('The SQLite connection is closed.')
    }
  }
}
