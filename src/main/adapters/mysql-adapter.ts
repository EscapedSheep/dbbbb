import { Buffer } from 'node:buffer'
import { Types, createConnection, createPool, escapeId } from 'mysql2/promise'
import type { FieldPacket, Pool, PoolConnection, PoolOptions } from 'mysql2/promise'
import type {
  ConnectionProfile,
  DatabaseCommand,
  DatabaseObjectNode,
  DatabaseResult,
  MySqlConnectionInput,
  MySqlSslMode,
  ResultColumn,
  WireValue
} from '../../shared/database'
import type { DatabaseAdapter, ExecuteOptions } from './database-adapter'

const LIST_OBJECTS_SQL = `
SELECT TABLE_NAME, TABLE_TYPE
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = ?
ORDER BY TABLE_NAME
`.trim()

const READ_ONLY_SESSION_SQL = 'SET SESSION transaction_read_only = ON'
const DEFAULT_CONNECTION_TIMEOUT_MS = 10_000
const DEFAULT_POOL_SIZE = 4
const MAX_ERROR_LENGTH = 600
const MAX_WIRE_DEPTH = 32
export const MAX_WIRE_VALUE_BYTES = 8 * 1024 * 1024

const ALLOWED_READ_ONLY_STARTERS = new Set([
  'DESCRIBE',
  'EXPLAIN',
  'SELECT',
  'SHOW',
  'WITH'
])

const FORBIDDEN_READ_ONLY_TOKENS = new Set([
  'ALTER',
  'ANALYZE',
  'BEGIN',
  'CALL',
  'CHANGE',
  'CHECK',
  'COMMIT',
  'CREATE',
  'DEALLOCATE',
  'DELETE',
  'DO',
  'DROP',
  'DUMPFILE',
  'EXECUTE',
  'FLUSH',
  'GET_LOCK',
  'GRANT',
  'HANDLER',
  'INSERT',
  'INSTALL',
  'INTO',
  'IS_FREE_LOCK',
  'IS_USED_LOCK',
  'KILL',
  'LOAD',
  'LOCK',
  'OPTIMIZE',
  'OUTFILE',
  'PREPARE',
  'PURGE',
  'RELEASE',
  'RELEASE_LOCK',
  'RENAME',
  'REPAIR',
  'REPLACE',
  'RESET',
  'REVOKE',
  'ROLLBACK',
  'SAVEPOINT',
  'SET',
  'SHUTDOWN',
  'START',
  'STOP',
  'TRUNCATE',
  'UNINSTALL',
  'UNLOCK',
  'UPDATE',
  'USE',
  'XA'
])

// Numeric wire types per MySQL's column-type constants (Types map values).
const NUMERIC_TYPE_NAMES = new Set([
  'DECIMAL',
  'TINY',
  'SHORT',
  'LONG',
  'FLOAT',
  'DOUBLE',
  'LONGLONG',
  'INT24',
  'YEAR',
  'NEWDECIMAL',
  'BIT'
])

interface MySqlObjectRef {
  kind: 'database' | 'table' | 'view'
  database: string
  name?: string
}

interface ActiveExecution {
  connection: PoolConnection
  threadId?: number
  timedOut: boolean
  cancelPromise?: Promise<void>
}

function validateInput(input: MySqlConnectionInput): void {
  if (
    input.engine !== 'mysql' ||
    input.host.trim().length === 0 ||
    !Number.isInteger(input.port) ||
    input.port < 1 ||
    input.port > 65_535 ||
    input.username.trim().length === 0 ||
    input.database.trim().length === 0
  ) {
    throw new Error('MySQL connection settings are invalid.')
  }
}

function sslConfig(mode: MySqlSslMode): PoolOptions['ssl'] {
  switch (mode) {
    case 'disable':
      return undefined
    case 'require':
      return {}
    case 'verify-full':
      return { rejectUnauthorized: true }
  }
}

function connectionConfig(input: MySqlConnectionInput): PoolOptions {
  return {
    host: input.host,
    port: input.port,
    user: input.username,
    password: input.password,
    database: input.database,
    ssl: sslConfig(input.sslMode),
    connectTimeout: DEFAULT_CONNECTION_TIMEOUT_MS,
    // Keep temporal values as the server's raw text: parsing them into Date
    // would reinterpret them in the host timezone, which breaks lossless
    // round-trips. BIGINT and DECIMAL cross as strings to avoid precision loss.
    dateStrings: true,
    supportBigNumbers: true,
    bigNumberStrings: true
  }
}

function poolConfig(input: MySqlConnectionInput): PoolOptions {
  return {
    ...connectionConfig(input),
    connectionLimit: DEFAULT_POOL_SIZE,
    idleTimeout: 30_000
  }
}

function objectId(ref: MySqlObjectRef): string {
  const encoded = Buffer.from(
    JSON.stringify([ref.kind, ref.database, ref.name ?? null]),
    'utf8'
  ).toString('base64url')
  return `mysql:${encoded}`
}

function assertProfile(profile: ConnectionProfile): void {
  if (profile.engine !== 'mysql') {
    throw new Error('The selected connection is not a MySQL connection.')
  }
}

function classificationError(start: number): Error {
  return new Error(
    `Read-only mode could not safely classify SQL near character ${start + 1}.`
  )
}

function inspectSql(sql: string): string[] {
  let visible = ''
  let index = 0

  const skipQuoted = (quote: "'" | '"' | '`'): void => {
    const start = index
    index += 1
    while (index < sql.length) {
      const character = sql[index]
      if (character === quote) {
        // A doubled quote is an escaped quote in both strings and identifiers.
        if (sql[index + 1] === quote) {
          index += 2
          continue
        }
        index += 1
        visible += ' '
        return
      }
      // With NO_BACKSLASH_ESCAPES off (the MySQL default) backslash escapes
      // the next character inside string literals; backtick identifiers have
      // no backslash escapes.
      if (quote !== '`' && character === '\\' && index + 1 < sql.length) {
        index += 2
        continue
      }
      index += 1
    }
    throw classificationError(start)
  }

  while (index < sql.length) {
    if (sql[index] === '#') {
      const newline = sql.indexOf('\n', index + 1)
      index = newline === -1 ? sql.length : newline + 1
      visible += ' '
      continue
    }

    if (sql.startsWith('--', index)) {
      // MySQL only treats -- as a comment when whitespace (or the end of the
      // statement) follows; 1--1 is a valid expression, so keep it visible.
      const after = sql[index + 2]
      if (after === undefined || /\s/.test(after)) {
        const newline = sql.indexOf('\n', index + 2)
        index = newline === -1 ? sql.length : newline + 1
        visible += ' '
        continue
      }
    }

    if (sql.startsWith('/*', index)) {
      const start = index
      // Versioned comments (/*! ... */) EXECUTE on matching server versions,
      // so the classifier cannot treat them as inert; fail closed instead.
      if (sql[index + 2] === '!') {
        throw classificationError(start)
      }
      index += 2
      while (index < sql.length && !sql.startsWith('*/', index)) {
        index += 1
      }
      if (index >= sql.length) {
        throw classificationError(start)
      }
      index += 2
      visible += ' '
      continue
    }

    if (sql[index] === "'" || sql[index] === '"' || sql[index] === '`') {
      skipQuoted(sql[index] as "'" | '"' | '`')
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

  // Defensive fallback: the driver is configured with dateStrings, so a Date
  // here did not come from a query result.
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

function fieldTypeName(field: FieldPacket): string | undefined {
  if (typeof field.typeName === 'string' && field.typeName.length > 0) {
    return field.typeName.toUpperCase()
  }
  const code = field.type ?? field.columnType
  if (typeof code !== 'number') return undefined
  const name = (Types as unknown as Record<number, string | undefined>)[code]
  return typeof name === 'string' ? name.toUpperCase() : undefined
}

function resultColumns(fields: FieldPacket[]): ResultColumn[] {
  const keyCounts = new Map<string, number>()
  return fields.map((field) => {
    const count = keyCounts.get(field.name) ?? 0
    keyCounts.set(field.name, count + 1)
    const key = count === 0 ? field.name : `${field.name}:${count}`
    const typeName = fieldTypeName(field)
    const code = field.type ?? field.columnType
    const dataType = typeName?.toLowerCase() ??
      (typeof code === 'number' ? `type:${code}` : 'unknown')
    const align = typeName && NUMERIC_TYPE_NAMES.has(typeName) ? 'end' : 'start'
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
    throw new Error('MySQL execution options are invalid.')
  }
}

function isCancellationError(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false
  const candidate = error as { code?: unknown; errno?: unknown; message?: unknown }
  // ER_QUERY_INTERRUPTED (1317): the server aborted the query after KILL QUERY.
  return candidate.code === 'ER_QUERY_INTERRUPTED' ||
    candidate.errno === 1317 ||
    (typeof candidate.message === 'string' &&
      /query execution was interrupted/i.test(candidate.message))
}

function isStatementTimeoutError(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false
  const candidate = error as { errno?: unknown }
  // ER_QUERY_TIMEOUT (3024) and MariaDB's max_statement_time (1938).
  return candidate.errno === 3024 || candidate.errno === 1938 ||
    /max(?:imum)?[_ ](?:execution|statement)[_ ]time/i.test(errorMessage(error))
}

// Errors whose connection must not return to the pool: mysql2 marks fatal
// protocol/transport failures with `fatal: true`, and any non-ER_ code is a
// Node errno (ECONNRESET, PROTOCOL_CONNECTION_LOST, ...) rather than a
// server-raised SQL error.
function isConnectionFailure(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false
  const candidate = error as { code?: unknown; fatal?: unknown }
  if (candidate.fatal === true) return true
  if (typeof candidate.code === 'string') return !candidate.code.startsWith('ER_')
  return errorMessage(error).toLowerCase().includes('connection')
}

function cancellationError(): Error & { code: string } {
  return Object.assign(new Error('MySQL query was cancelled.'), {
    code: 'ER_QUERY_INTERRUPTED'
  })
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
    .replace(/\bmysql:\/\/[^\s/@]+(?::[^@\s]*)?@/gi, 'mysql://[redacted]@')
    .replace(/\b(password|passwd|pwd)\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)/gi, '$1=[redacted]')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_ERROR_LENGTH)

  const safe = new Error(`${action}: ${message || 'Unexpected database error.'}`)
  safe.name = 'MySqlAdapterError'
  const code = error && typeof error === 'object' ? (error as { code?: unknown }).code : undefined
  if (typeof code === 'string' && /^[A-Z][A-Z0-9_]{1,63}$/.test(code)) {
    ;(safe as Error & { code?: string }).code = code
  }
  return safe
}

export class MySqlAdapter implements DatabaseAdapter {
  readonly engine = 'mysql' as const

  private readonly input: MySqlConnectionInput
  private readonly pool: Pool
  private readonly objects = new Map<string, MySqlObjectRef>()
  private readonly activeExecutions = new Map<string, ActiveExecution>()
  private readonly requestIds = new Set<string>()
  private readonly cancelledRequestIds = new Set<string>()
  private readonly readOnlySessions = new WeakSet<object>()
  private connected = false
  private closed = false
  private connectPromise?: Promise<void>
  private closePromise?: Promise<void>

  constructor(input: MySqlConnectionInput) {
    validateInput(input)
    this.input = { ...input }
    this.pool = createPool(poolConfig(this.input))
  }

  async connect(): Promise<void> {
    this.assertOpen()
    if (this.connected) return
    if (this.connectPromise) return this.connectPromise

    this.connectPromise = (async () => {
      let connection: PoolConnection | undefined
      let destroyConnection = false
      try {
        connection = await this.pool.getConnection()
        await this.applyReadOnlySession(connection)
        this.connected = true
      } catch (error) {
        // Never pool a connection whose read-only session setup failed.
        destroyConnection = Boolean(connection)
        throw sanitizedError('Could not connect to MySQL', error, [this.input.password])
      } finally {
        if (connection) {
          if (destroyConnection) connection.destroy()
          else connection.release()
        }
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
      const [rawRows] = await this.pool.query(LIST_OBJECTS_SQL, [this.input.database])
      const rows = rawRows as Array<{ TABLE_NAME: unknown; TABLE_TYPE: unknown }>
      if (!Array.isArray(rows)) {
        throw new Error('MySQL returned invalid object metadata.')
      }

      const refs: MySqlObjectRef[] = []
      for (const row of rows) {
        if (row === null || typeof row !== 'object') {
          throw new Error('MySQL returned invalid object metadata.')
        }
        const kind = row.TABLE_TYPE === 'BASE TABLE'
          ? 'table'
          : row.TABLE_TYPE === 'VIEW'
            ? 'view'
            : undefined
        if (!kind) continue
        if (typeof row.TABLE_NAME !== 'string' || row.TABLE_NAME.length === 0) {
          throw new Error('MySQL returned invalid object metadata.')
        }
        refs.push({ kind, database: this.input.database, name: row.TABLE_NAME })
      }

      const nextObjects = new Map<string, MySqlObjectRef>()
      const databaseRef: MySqlObjectRef = { kind: 'database', database: this.input.database }
      const databaseId = objectId(databaseRef)
      nextObjects.set(databaseId, databaseRef)
      const nodes: DatabaseObjectNode[] = [{
        id: databaseId,
        name: this.input.database,
        kind: 'database',
        detail: `${refs.length} ${refs.length === 1 ? 'object' : 'objects'}`
      }]

      for (const ref of refs) {
        const id = objectId(ref)
        nextObjects.set(id, ref)
        nodes.push({
          id,
          parentId: databaseId,
          name: ref.name as string,
          kind: ref.kind
        })
      }

      this.objects.clear()
      for (const [id, ref] of nextObjects) this.objects.set(id, ref)
      return nodes
    } catch (error) {
      throw sanitizedError('Could not list MySQL objects', error, [this.input.password])
    }
  }

  async previewObject(
    profile: ConnectionProfile,
    id: string
  ): Promise<DatabaseCommand> {
    assertProfile(profile)
    this.assertOpen()
    const ref = this.objects.get(id)
    if (!ref || ref.kind === 'database' || !ref.name) {
      throw new Error('This MySQL object cannot be previewed.')
    }

    return {
      engine: 'mysql',
      kind: 'query',
      text: `SELECT *\nFROM ${escapeId(ref.database)}.${escapeId(ref.name)}\nLIMIT 100;`
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
      throw new Error('The selected MySQL connection only accepts SQL queries.')
    }
    if (command.text.trim().length === 0) {
      throw new Error('MySQL query cannot be empty.')
    }
    if (this.input.readOnly || profile.readOnly) assertReadOnlySql(command.text)
    if (this.requestIds.has(options.requestId)) {
      throw new Error('A MySQL query with this request id is already running.')
    }

    this.requestIds.add(options.requestId)

    let connection: PoolConnection | undefined
    let execution: ActiveExecution | undefined
    let timeout: NodeJS.Timeout | undefined
    let destroyConnection = false
    const startedAt = Date.now()

    try {
      await this.connect()
      if (this.cancelledRequestIds.has(options.requestId)) throw cancellationError()

      connection = await this.pool.getConnection()
      if (this.cancelledRequestIds.has(options.requestId)) throw cancellationError()

      try {
        await this.applyReadOnlySession(connection)
      } catch (error) {
        // A session that refused read-only mode must not return to the pool.
        destroyConnection = true
        throw error
      }

      execution = {
        connection,
        timedOut: false
      }
      this.activeExecutions.set(options.requestId, execution)

      const threadId = Number(connection.threadId)
      if (!Number.isSafeInteger(threadId) || threadId <= 0) {
        throw new Error('MySQL returned an invalid connection thread id.')
      }
      execution.threadId = threadId
      if (this.cancelledRequestIds.has(options.requestId)) throw cancellationError()

      if (options.timeoutMs > 0) {
        timeout = setTimeout(() => {
          if (!execution) return
          execution.timedOut = true
          void this.dispatchCancel(execution).catch(() => undefined)
        }, options.timeoutMs)
        timeout.unref?.()
      }

      const [rawRows, rawFields] = await connection.query({
        sql: command.text,
        rowsAsArray: true
      })
      if (execution.timedOut || this.cancelledRequestIds.has(options.requestId)) {
        throw cancellationError()
      }
      const rows = Array.isArray(rawRows) ? rawRows as unknown[][] : []
      const fields = Array.isArray(rawFields) ? rawFields : []
      const bounded = boundedRows(rows, options.maxRows, options.maxBytes)

      return {
        kind: 'rows',
        columns: resultColumns(fields),
        rows: bounded.rows,
        meta: {
          elapsedMs: Math.max(0, Date.now() - startedAt),
          count: bounded.rows.length,
          truncated: bounded.truncated,
          source: 'database'
        }
      }
    } catch (error) {
      if (connection && isConnectionFailure(error)) {
        destroyConnection = true
      }
      const wasCancelled = this.cancelledRequestIds.has(options.requestId)
      if (wasCancelled || isCancellationError(error)) {
        const timedOut = execution?.timedOut || (!wasCancelled && isStatementTimeoutError(error))
        throw new Error(timedOut
          ? 'MySQL query timed out.'
          : 'MySQL query was cancelled.')
      }
      throw sanitizedError('MySQL query failed', error, [this.input.password])
    } finally {
      if (timeout) clearTimeout(timeout)
      if (this.activeExecutions.get(options.requestId) === execution) {
        this.activeExecutions.delete(options.requestId)
      }
      this.cancelledRequestIds.delete(options.requestId)
      this.requestIds.delete(options.requestId)
      // A broken connection is destroyed instead of returning to the pool.
      if (connection) {
        if (destroyConnection) connection.destroy()
        else connection.release()
      }
    }
  }

  async cancel(requestId: string): Promise<void> {
    if (!this.requestIds.has(requestId)) return
    this.cancelledRequestIds.add(requestId)
    const execution = this.activeExecutions.get(requestId)
    if (!execution) return
    if (!execution.threadId) return

    try {
      await this.dispatchCancel(execution)
    } catch (error) {
      throw sanitizedError('Could not cancel MySQL query', error, [this.input.password])
    }
  }

  async close(): Promise<void> {
    if (this.closePromise) return this.closePromise
    if (this.closed) return

    this.closePromise = (async () => {
      try {
        for (const requestId of this.requestIds) this.cancelledRequestIds.add(requestId)
        const active = [...this.activeExecutions.values()].filter(
          (execution) => execution.threadId !== undefined
        )
        await Promise.allSettled(active.map((execution) => this.dispatchCancel(execution)))
        await this.pool.end()
      } catch (error) {
        throw sanitizedError('Could not close MySQL', error, [this.input.password])
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
      throw new Error('The MySQL connection is closed.')
    }
  }

  // Server-side enforcement behind the client-side classifier: a read-only
  // profile sets transaction_read_only on every pooled session exactly once.
  private async applyReadOnlySession(connection: PoolConnection): Promise<void> {
    if (!this.input.readOnly || this.readOnlySessions.has(connection)) return
    await connection.query(READ_ONLY_SESSION_SQL)
    this.readOnlySessions.add(connection)
  }

  private dispatchCancel(execution: ActiveExecution): Promise<void> {
    if (execution.cancelPromise) return execution.cancelPromise

    execution.cancelPromise = (async () => {
      const threadId = execution.threadId
      if (!threadId) return

      // A dedicated out-of-pool connection: cancellation must not queue
      // behind a saturated pool (connectionLimit is only DEFAULT_POOL_SIZE).
      const killConnection = await createConnection(connectionConfig(this.input))
      try {
        await killConnection.query(`KILL QUERY ${threadId}`)
      } catch (error) {
        // ER_NO_SUCH_THREAD (1094): the query already finished, which is the
        // outcome cancellation wanted anyway.
        const errno = error && typeof error === 'object'
          ? (error as { errno?: unknown }).errno
          : undefined
        if (errno !== 1094) throw error
      } finally {
        await killConnection.end().catch(() => undefined)
      }
    })()

    return execution.cancelPromise
  }
}
