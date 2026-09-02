// @vitest-environment node
import { Buffer } from 'node:buffer'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ConnectionProfile, MySqlConnectionInput } from '../../shared/database'
import type { ExecuteOptions } from './database-adapter'

interface MockPool {
  config: Record<string, unknown>
  getConnection: ReturnType<typeof vi.fn>
  query: ReturnType<typeof vi.fn>
  end: ReturnType<typeof vi.fn>
}

interface MockCreatedConnection {
  config: Record<string, unknown>
  query: ReturnType<typeof vi.fn>
  end: ReturnType<typeof vi.fn>
  destroy: ReturnType<typeof vi.fn>
}

const mysqlMock = vi.hoisted(() => ({
  pools: [] as MockPool[],
  createdConnections: [] as MockCreatedConnection[],
  createdConnectionQuery: vi.fn(),
  escapeId: vi.fn((value: string) => `\`${value.replaceAll('`', '``')}\``),
  types: {
    0: 'DECIMAL',
    3: 'LONG',
    8: 'LONGLONG',
    12: 'DATETIME',
    246: 'NEWDECIMAL',
    252: 'BLOB',
    253: 'VAR_STRING'
  } as Record<number, string>
}))

vi.mock('mysql2/promise', () => {
  class Pool implements MockPool {
    readonly config: Record<string, unknown>
    readonly getConnection = vi.fn()
    readonly query = vi.fn()
    readonly end = vi.fn(async () => undefined)

    constructor(config: Record<string, unknown>) {
      this.config = config
      mysqlMock.pools.push(this)
    }
  }

  return {
    createPool: vi.fn((config: Record<string, unknown>) => new Pool(config)),
    createConnection: vi.fn(async (config: Record<string, unknown>) => {
      const connection: MockCreatedConnection = {
        config,
        query: vi.fn((...args: unknown[]) => mysqlMock.createdConnectionQuery(...args)),
        end: vi.fn(async () => undefined),
        destroy: vi.fn()
      }
      mysqlMock.createdConnections.push(connection)
      return connection
    }),
    escapeId: mysqlMock.escapeId,
    Types: mysqlMock.types
  }
})

import {
  MAX_WIRE_VALUE_BYTES,
  MySqlAdapter,
  assertReadOnlySql,
  boundedRows,
  toWireValue
} from './mysql-adapter'

const input: MySqlConnectionInput = {
  engine: 'mysql',
  name: 'Local MySQL',
  host: 'db.internal',
  port: 3306,
  database: 'product',
  username: 'dbbbb',
  password: 'top-secret',
  sslMode: 'verify-full',
  environment: 'development',
  readOnly: true
}

const profile: ConnectionProfile = {
  id: 'mysql-test',
  name: input.name,
  engine: 'mysql',
  endpoint: `${input.host}:${input.port}`,
  database: input.database,
  environment: input.environment,
  readOnly: true,
  demo: false
}

const writableInput: MySqlConnectionInput = { ...input, readOnly: false }
const writableProfile: ConnectionProfile = { ...profile, readOnly: false }

function options(requestId: string, overrides: Partial<ExecuteOptions> = {}): ExecuteOptions {
  return {
    requestId,
    timeoutMs: 5_000,
    maxRows: 2,
    maxBytes: 1024 * 1024,
    ...overrides
  }
}

function poolConnection(threadId = 7312) {
  return {
    threadId,
    query: vi.fn(async (..._args: unknown[]): Promise<unknown> => [[], []]),
    release: vi.fn(),
    destroy: vi.fn()
  }
}

function currentPool(): MockPool {
  const pool = mysqlMock.pools.at(-1)
  if (!pool) throw new Error('Expected a mocked MySQL pool.')
  return pool
}

beforeEach(() => {
  mysqlMock.pools.length = 0
  mysqlMock.createdConnections.length = 0
  mysqlMock.createdConnectionQuery.mockReset()
  mysqlMock.escapeId.mockClear()
})

describe('MySqlAdapter pure boundaries', () => {
  it('accepts read-only SQL with quoted keywords and rejects mutations', () => {
    expect(() => assertReadOnlySql(
      'SELECT `update`, \'delete; insert\' FROM `insert` # drop table hidden'
    )).not.toThrow()
    expect(() => assertReadOnlySql('WITH changed AS (DELETE FROM users) SELECT 1')).toThrow(
      /DELETE/
    )
    expect(() => assertReadOnlySql('SELECT 1; SELECT 2')).toThrow(/one SQL statement/i)
  })

  it('allows the documented read-only statement starters', () => {
    expect(() => assertReadOnlySql('SHOW PROCESSLIST')).not.toThrow()
    expect(() => assertReadOnlySql('DESCRIBE `users`')).not.toThrow()
    expect(() => assertReadOnlySql('EXPLAIN SELECT 1')).not.toThrow()
    expect(() => assertReadOnlySql('WITH cte AS (SELECT 1) SELECT * FROM cte')).not.toThrow()
  })

  it('fails closed on versioned comments because MySQL executes them', () => {
    expect(() => assertReadOnlySql('/*!50100 DROP TABLE users */')).toThrow(/classify/i)
    expect(() => assertReadOnlySql('SELECT /*!80000 1 + 1 */')).toThrow(/classify/i)
    expect(() => assertReadOnlySql('SELECT 1 /* ordinary comment */')).not.toThrow()
    expect(() => assertReadOnlySql('SELECT 1 /* unterminated')).toThrow(/classify/i)
  })

  it('treats backslash as an escape inside MySQL string literals', () => {
    // \' keeps the quote inside the string, so the payload stays inert content.
    expect(() => assertReadOnlySql(`SELECT 'it\\'s fine', 1`)).not.toThrow()
    // \\ closes the string after one escaped backslash, so the DROP is real SQL.
    expect(() => assertReadOnlySql(`SELECT '\\\\'; DROP TABLE users; --'`)).toThrow()
    expect(() => assertReadOnlySql(`SELECT '\\\\' FROM users WHERE note = 'x'`)).not.toThrow()
    // A trailing backslash leaves the string unterminated: fail closed.
    expect(() => assertReadOnlySql(`SELECT 'abc\\`)).toThrow(/classify/i)
  })

  it('handles MySQL comment styles without hiding statements', () => {
    expect(() => assertReadOnlySql('SELECT 1 -- DROP TABLE users\n')).not.toThrow()
    // 1--1 is an expression, not a comment: -- needs trailing whitespace.
    expect(() => assertReadOnlySql('SELECT 1--1')).not.toThrow()
    expect(() => assertReadOnlySql('SELECT 1 # KILL 12')).not.toThrow()
  })

  it('rejects write targets, locking reads, and administrative statements', () => {
    expect(() => assertReadOnlySql('KILL 12')).toThrow(/read-only SQL/i)
    expect(() => assertReadOnlySql('EXPLAIN KILL 12')).toThrow(/KILL/)
    expect(() => assertReadOnlySql(
      "SELECT * INTO OUTFILE '/tmp/x' FROM users"
    )).toThrow(/INTO/)
    expect(() => assertReadOnlySql('SELECT * FROM users FOR UPDATE')).toThrow(/UPDATE/)
    expect(() => assertReadOnlySql('SELECT * FROM users LOCK IN SHARE MODE')).toThrow(/LOCK/)
    expect(() => assertReadOnlySql('SELECT GET_LOCK(\'report\', 10)')).toThrow(/GET_LOCK/)
  })

  it('serializes exact and binary values without leaking non-wire objects', () => {
    const circular: Record<string, unknown> = { ok: true }
    circular.self = circular

    const wire = toWireValue({
      bigint: 9_007_199_254_740_993n,
      unsafeInteger: Number.MAX_SAFE_INTEGER + 1,
      infinity: Number.POSITIVE_INFINITY,
      date: new Date('2026-08-31T00:00:00.000Z'),
      bytes: Buffer.from([1, 2, 3]),
      emptyJson: {},
      circular
    })

    expect(wire).toEqual({
      bigint: '9007199254740993',
      unsafeInteger: '9007199254740992',
      infinity: 'Infinity',
      date: '2026-08-31T00:00:00.000Z',
      bytes: { $binary: 'AQID' },
      emptyJson: {},
      circular: { ok: true, self: '[Circular]' }
    })
    expect(structuredClone(wire)).toEqual(wire)
  })

  it('truncates oversized single values with a visible marker', () => {
    const oversizedText = 'x'.repeat(MAX_WIRE_VALUE_BYTES + 1024 * 1024)
    const text = toWireValue(oversizedText) as string
    expect(text.length).toBeLessThan(oversizedText.length)
    expect(text.startsWith('x'.repeat(1024))).toBe(true)
    expect(text).toContain('[dbbbb truncated 1048576 bytes]')

    const binary = toWireValue(Buffer.alloc(MAX_WIRE_VALUE_BYTES + 1024 * 1024)) as {
      $binary: string
    }
    expect(binary.$binary).toContain('[dbbbb truncated 1048576 bytes]')
  })

  it('uses maxRows plus one as the truncation signal and enforces the byte budget', () => {
    expect(boundedRows([[1], [2], [3]], 2, 10_000)).toEqual({
      rows: [[1], [2]],
      truncated: true
    })

    const firstRowBytes = Buffer.byteLength(JSON.stringify(['ok']), 'utf8')
    expect(boundedRows([['ok'], ['too large']], 2, firstRowBytes)).toEqual({
      rows: [['ok']],
      truncated: true
    })
  })
})

describe('MySqlAdapter pool behavior', () => {
  it('maps sslMode onto the driver ssl option', () => {
    new MySqlAdapter({ ...input, sslMode: 'disable' })
    expect(currentPool().config.ssl).toBeUndefined()

    new MySqlAdapter({ ...input, sslMode: 'require' })
    expect(currentPool().config.ssl).toEqual({})

    new MySqlAdapter({ ...input, sslMode: 'verify-full' })
    expect(currentPool().config.ssl).toEqual({ rejectUnauthorized: true })
  })

  it('configures fidelity and safety options plus an idempotent read-only probe', async () => {
    const adapter = new MySqlAdapter(input)
    const pool = currentPool()
    const probe = poolConnection()
    pool.getConnection.mockResolvedValue(probe)

    expect(pool.config).toMatchObject({
      host: input.host,
      port: input.port,
      user: input.username,
      password: input.password,
      database: input.database,
      ssl: { rejectUnauthorized: true },
      connectTimeout: 10_000,
      connectionLimit: 4,
      idleTimeout: 30_000,
      dateStrings: true,
      supportBigNumbers: true,
      bigNumberStrings: true
    })

    await Promise.all([adapter.connect(), adapter.connect()])
    expect(pool.getConnection).toHaveBeenCalledTimes(1)
    expect(probe.query).toHaveBeenCalledWith('SET SESSION transaction_read_only = ON')
    expect(probe.release).toHaveBeenCalledTimes(1)

    await adapter.close()
    expect(pool.end).toHaveBeenCalledTimes(1)
  })

  it('destroys the probe instead of pooling it when read-only setup fails', async () => {
    const adapter = new MySqlAdapter(input)
    const pool = currentPool()
    const probe = poolConnection()
    probe.query.mockRejectedValueOnce(Object.assign(
      new Error('Unknown system variable'),
      { code: 'ER_UNKNOWN_SYSTEM_VARIABLE' }
    ))
    pool.getConnection.mockResolvedValueOnce(probe)

    await expect(adapter.connect()).rejects.toThrow(/could not connect/i)
    expect(probe.destroy).toHaveBeenCalledTimes(1)
    expect(probe.release).not.toHaveBeenCalled()
  })

  it('builds a database tree and safely quotes preview identifiers', async () => {
    const adapter = new MySqlAdapter(input)
    const pool = currentPool()
    const probe = poolConnection()
    pool.getConnection.mockResolvedValueOnce(probe)
    pool.query.mockResolvedValueOnce([
      [
        { TABLE_NAME: 'user`table', TABLE_TYPE: 'BASE TABLE' },
        { TABLE_NAME: 'monthly_report', TABLE_TYPE: 'VIEW' },
        { TABLE_NAME: 'sys_config', TABLE_TYPE: 'SYSTEM VIEW' }
      ],
      []
    ])

    const objects = await adapter.listObjects(profile)
    const database = objects.find((object) => object.kind === 'database')
    const table = objects.find((object) => object.name === 'user`table')
    const view = objects.find((object) => object.name === 'monthly_report')

    expect(database).toMatchObject({
      kind: 'database',
      name: input.database,
      detail: '2 objects'
    })
    expect(table).toMatchObject({ kind: 'table', parentId: database?.id })
    expect(view).toMatchObject({ kind: 'view', parentId: database?.id })
    expect(objects.some((object) => object.name === 'sys_config')).toBe(false)
    expect(pool.query).toHaveBeenCalledWith(
      expect.stringContaining('information_schema.TABLES'),
      [input.database]
    )

    const preview = await adapter.previewObject(profile, table!.id)
    expect(preview).toEqual({
      engine: 'mysql',
      kind: 'query',
      text: 'SELECT *\nFROM `product`.`user``table`\nLIMIT 100;'
    })
  })

  it('executes in array mode and emits aligned, precision-safe bounded rows', async () => {
    const adapter = new MySqlAdapter(writableInput)
    const pool = currentPool()
    const probe = poolConnection()
    const queryConnection = poolConnection()
    pool.getConnection.mockResolvedValueOnce(probe)
    await adapter.connect()
    pool.getConnection.mockResolvedValueOnce(queryConnection)

    queryConnection.query.mockResolvedValueOnce([
      [
        ['9007199254740993', '2026-08-31 12:34:56', Buffer.from([1, 2])],
        ['2', '2026-09-01 00:00:00', Buffer.from([3])],
        ['3', '2026-09-02 00:00:00', Buffer.from([4])]
      ],
      [
        { name: 'value', columnType: 8 },
        { name: 'created_at', columnType: 12 },
        { name: 'payload', columnType: 252 }
      ]
    ])

    const query = { engine: 'mysql', kind: 'query', text: 'SELECT * FROM events' } as const
    const databaseResult = await adapter.execute(writableProfile, query, options('rows'))

    expect(queryConnection.query).toHaveBeenCalledWith({
      sql: query.text,
      rowsAsArray: true
    })
    expect(databaseResult).toMatchObject({
      kind: 'rows',
      columns: [
        { key: 'value', dataType: 'longlong', align: 'end' },
        { key: 'created_at', dataType: 'datetime', align: 'start' },
        { key: 'payload', dataType: 'blob', align: 'start' }
      ],
      rows: [
        ['9007199254740993', '2026-08-31 12:34:56', { $binary: 'AQI=' }],
        ['2', '2026-09-01 00:00:00', { $binary: 'Aw==' }]
      ],
      meta: { count: 2, truncated: true, source: 'database' }
    })
    expect(queryConnection.release).toHaveBeenCalledTimes(1)
    expect(queryConnection.destroy).not.toHaveBeenCalled()
  })

  it('rejects mutating SQL on read-only connections before touching the pool', async () => {
    const adapter = new MySqlAdapter(input)
    const pool = currentPool()

    await expect(adapter.execute(
      profile,
      { engine: 'mysql', kind: 'query', text: 'DROP TABLE users' },
      options('read-only-guard')
    )).rejects.toThrow(/read-only/i)
    expect(pool.getConnection).not.toHaveBeenCalled()
  })

  it('remembers cancellation requested while the initial connection is pending', async () => {
    const adapter = new MySqlAdapter(input)
    const pool = currentPool()
    const probe = poolConnection()
    let resolveProbe!: (value: ReturnType<typeof poolConnection>) => void
    const pendingProbe = new Promise<ReturnType<typeof poolConnection>>((resolve) => {
      resolveProbe = resolve
    })
    pool.getConnection.mockReturnValueOnce(pendingProbe)

    const outcome = adapter
      .execute(
        profile,
        { engine: 'mysql', kind: 'query', text: 'SELECT 1' },
        options('cancel-before-connect')
      )
      .then(
        () => ({ status: 'resolved' as const }),
        (error: unknown) => ({ status: 'rejected' as const, error })
      )

    await vi.waitFor(() => expect(pool.getConnection).toHaveBeenCalledTimes(1))
    await adapter.cancel('cancel-before-connect')
    resolveProbe(probe)

    const settled = await outcome
    expect(settled.status).toBe('rejected')
    if (settled.status === 'rejected') {
      expect(settled.error).toBeInstanceOf(Error)
      expect((settled.error as Error).message).toMatch(/cancelled/i)
    }
    expect(pool.getConnection).toHaveBeenCalledTimes(1)
    expect(probe.release).toHaveBeenCalledTimes(1)
  })

  it('cancels an active query through a dedicated out-of-pool connection', async () => {
    const adapter = new MySqlAdapter(input)
    const pool = currentPool()
    const probe = poolConnection()
    const queryConnection = poolConnection(8124)
    pool.getConnection.mockResolvedValueOnce(probe)
    await adapter.connect()

    let rejectQuery!: (error: Error & { code: string; errno: number }) => void
    const pendingQuery = new Promise<never>((_resolve, reject) => {
      rejectQuery = reject
    })
    queryConnection.query.mockImplementation((arg: unknown) => {
      // The read-only session setup resolves; the user query stays pending.
      return typeof arg === 'string' ? Promise.resolve([[], []]) : pendingQuery
    })
    mysqlMock.createdConnectionQuery.mockImplementationOnce(async () => {
      rejectQuery(Object.assign(new Error('Query execution was interrupted'), {
        code: 'ER_QUERY_INTERRUPTED',
        errno: 1317
      }))
      return [[], []]
    })
    pool.getConnection.mockResolvedValueOnce(queryConnection)

    const outcome = adapter
      .execute(
        profile,
        { engine: 'mysql', kind: 'query', text: 'SELECT SLEEP(10)' },
        options('active-cancel')
      )
      .then(
        () => ({ status: 'resolved' as const }),
        (error: unknown) => ({ status: 'rejected' as const, error })
      )

    await vi.waitFor(() => expect(queryConnection.query).toHaveBeenCalledTimes(2))
    await adapter.cancel('active-cancel')
    const settled = await outcome

    expect(settled.status).toBe('rejected')
    if (settled.status === 'rejected') {
      expect((settled.error as Error).message).toMatch(/cancelled/i)
    }
    expect(mysqlMock.createdConnections).toHaveLength(1)
    const killConnection = mysqlMock.createdConnections[0]
    expect(killConnection.config).toMatchObject({
      host: input.host,
      port: input.port,
      database: input.database,
      ssl: { rejectUnauthorized: true }
    })
    expect(killConnection.query).toHaveBeenCalledWith('KILL QUERY 8124')
    expect(killConnection.end).toHaveBeenCalledTimes(1)
    expect(queryConnection.release).toHaveBeenCalledTimes(1)
  })

  it('destroys the connection instead of pooling it after a connection-level failure', async () => {
    const adapter = new MySqlAdapter(writableInput)
    const pool = currentPool()
    const probe = poolConnection()
    const queryConnection = poolConnection()
    pool.getConnection.mockResolvedValueOnce(probe)
    await adapter.connect()
    pool.getConnection.mockResolvedValueOnce(queryConnection)

    queryConnection.query.mockRejectedValueOnce(Object.assign(
      new Error('Connection lost: The server closed the connection.'),
      { code: 'PROTOCOL_CONNECTION_LOST', fatal: true }
    ))

    await expect(adapter.execute(
      writableProfile,
      { engine: 'mysql', kind: 'query', text: 'SELECT 1' },
      options('connection-failure')
    )).rejects.toThrow(/query failed/i)
    expect(queryConnection.destroy).toHaveBeenCalledTimes(1)
    expect(queryConnection.release).not.toHaveBeenCalled()
  })

  it('redacts credentials from driver errors while preserving a safe error code', async () => {
    const adapter = new MySqlAdapter(input)
    const pool = currentPool()
    pool.getConnection.mockRejectedValueOnce(Object.assign(
      new Error('password=top-secret mysql://dbbbb:top-secret@db.internal/product'),
      { code: 'ER_ACCESS_DENIED_ERROR' }
    ))

    const error = await adapter.connect().catch((caught: unknown) => caught)
    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).not.toContain(input.password)
    expect((error as Error).message).toContain('[redacted]')
    expect((error as Error & { code?: string }).code).toBe('ER_ACCESS_DENIED_ERROR')
  })
})
