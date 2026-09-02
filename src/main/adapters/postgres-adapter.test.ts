// @vitest-environment node
import { Buffer } from 'node:buffer'
import { Readable } from 'node:stream'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ConnectionProfile, PostgresConnectionInput } from '../../shared/database'
import type { AdapterDataChange, ExecuteOptions } from './database-adapter'

interface MockPool {
  config: Record<string, unknown>
  connect: ReturnType<typeof vi.fn>
  query: ReturnType<typeof vi.fn>
  end: ReturnType<typeof vi.fn>
}

interface MockClient {
  config: Record<string, unknown>
  connect: ReturnType<typeof vi.fn>
  query: ReturnType<typeof vi.fn>
  end: ReturnType<typeof vi.fn>
}

const pgMock = vi.hoisted(() => ({
  pools: [] as MockPool[],
  clients: [] as MockClient[],
  clientQuery: vi.fn(),
  setTypeParser: vi.fn(),
  escapeIdentifier: vi.fn((value: string) => `"${value.replaceAll('"', '""')}"`)
}))

vi.mock('pg', () => {
  class Pool implements MockPool {
    readonly config: Record<string, unknown>
    readonly connect = vi.fn()
    readonly query = vi.fn()
    readonly end = vi.fn(async () => undefined)

    constructor(config: Record<string, unknown>) {
      this.config = config
      pgMock.pools.push(this)
    }
  }

  class Client implements MockClient {
    readonly config: Record<string, unknown>
    readonly connect = vi.fn(async () => undefined)
    readonly query = vi.fn((...args: unknown[]) => pgMock.clientQuery(...args))
    readonly end = vi.fn(async () => undefined)

    constructor(config: Record<string, unknown>) {
      this.config = config
      pgMock.clients.push(this)
    }
  }

  return {
    Client,
    Pool,
    escapeIdentifier: pgMock.escapeIdentifier,
    types: {
      builtins: {
        BOOL: 16,
        BYTEA: 17,
        INT8: 20,
        INT2: 21,
        INT4: 23,
        TEXT: 25,
        OID: 26,
        JSON: 114,
        FLOAT4: 700,
        FLOAT8: 701,
        MONEY: 790,
        DATE: 1082,
        TIMESTAMP: 1114,
        TIMESTAMPTZ: 1184,
        NUMERIC: 1700,
        JSONB: 3802
      },
      setTypeParser: pgMock.setTypeParser
    }
  }
})

import {
  MAX_WIRE_VALUE_BYTES,
  PostgresAdapter,
  assertReadOnlySql,
  boundedRows,
  postgresImportBatchSize,
  toWireValue
} from './postgres-adapter'

const input: PostgresConnectionInput = {
  engine: 'postgresql',
  name: 'Local PostgreSQL',
  host: 'db.internal',
  port: 5432,
  database: 'product',
  username: 'dbbbb',
  password: 'top-secret',
  sslMode: 'verify-full',
  environment: 'development',
  readOnly: true
}

const profile: ConnectionProfile = {
  id: 'postgres-test',
  name: input.name,
  engine: 'postgresql',
  endpoint: `${input.host}:${input.port}`,
  database: input.database,
  environment: input.environment,
  readOnly: true,
  demo: false
}

const writableInput: PostgresConnectionInput = { ...input, readOnly: false }
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

function client() {
  return {
    query: vi.fn(),
    release: vi.fn()
  }
}

function result(rows: unknown[][], fields: Array<{ name: string; dataTypeID: number }> = []) {
  return {
    command: 'SELECT',
    rowCount: rows.length,
    oid: 0,
    rows,
    fields
  }
}

function currentPool(): MockPool {
  const pool = pgMock.pools.at(-1)
  if (!pool) throw new Error('Expected a mocked PostgreSQL pool.')
  return pool
}

async function introspectTarget(
  adapter: PostgresAdapter,
  pool: MockPool,
  schema = 'public',
  name = 'events',
  relationKind = 'r'
) {
  const probe = client()
  pool.connect.mockResolvedValueOnce(probe)
  pool.query.mockResolvedValueOnce(result([[schema, name, relationKind]]))
  const objects = await adapter.listObjects(writableProfile)
  const target = objects.find((object) => object.name === name)
  if (!target) throw new Error('Expected an introspected test target.')
  return target
}

beforeEach(() => {
  pgMock.pools.length = 0
  pgMock.clients.length = 0
  pgMock.clientQuery.mockReset()
  pgMock.escapeIdentifier.mockClear()
})

describe('PostgresAdapter pure boundaries', () => {
  it('accepts read-only SQL with quoted keywords and rejects mutations', () => {
    expect(() => assertReadOnlySql(
      `SELECT "update", 'delete; insert', $$drop table hidden$$ FROM "insert";`
    )).not.toThrow()
    expect(() => assertReadOnlySql('WITH changed AS (DELETE FROM users) SELECT 1')).toThrow(
      /DELETE/
    )
    expect(() => assertReadOnlySql('SELECT nextval(\'order_id_seq\')')).toThrow(/NEXTVAL/)
    expect(() => assertReadOnlySql('SELECT 1; SELECT 2')).toThrow(/one SQL statement/i)
  })

  it('treats backslash as literal in plain strings but as an escape in E-strings', () => {
    // With standard_conforming_strings=on, '\' closes the string and the DROP
    // statement is real SQL, so classification must reject the payload.
    expect(() => assertReadOnlySql(`SELECT '\\'; DROP TABLE users; --'`)).toThrow()
    expect(() => assertReadOnlySql(`SELECT '\\' DROP TABLE users`)).toThrow(/DROP/)
    // In an E'...' escape string the same payload is inert string content.
    expect(() => assertReadOnlySql(`SELECT E'\\\\\\'; DROP TABLE users; --'`)).not.toThrow()
    expect(() => assertReadOnlySql(`SELECT e'it\\'s fine', 1`)).not.toThrow()
  })

  it('rejects administrative functions on read-only connections', () => {
    expect(() => assertReadOnlySql(
      'SELECT pg_terminate_backend(pid) FROM pg_stat_activity'
    )).toThrow(/PG_TERMINATE_BACKEND/)
    expect(() => assertReadOnlySql(
      'SELECT pg_cancel_backend(pid) FROM pg_stat_activity'
    )).toThrow(/PG_CANCEL_BACKEND/)
    expect(() => assertReadOnlySql('SELECT pg_reload_conf()')).toThrow(/PG_RELOAD_CONF/)
    expect(() => assertReadOnlySql('SELECT pg_rotate_logfile()')).toThrow(/PG_ROTATE_LOGFILE/)
  })

  it('keeps temporal column values as raw driver text', () => {
    for (const oid of [1082, 1114, 1184]) {
      expect(pgMock.setTypeParser).toHaveBeenCalledWith(oid, expect.any(Function))
    }
    const parser = pgMock.setTypeParser.mock.calls.find(([oid]) => oid === 1184)?.[1] as (
      value: string
    ) => string
    expect(parser('2026-08-31 12:34:56.789123+00')).toBe('2026-08-31 12:34:56.789123+00')
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

  it('derives a PostgreSQL-safe batch size from the 65,535 parameter ceiling', () => {
    const batchSize = postgresImportBatchSize(132)
    expect(batchSize).toBe(496)
    expect(batchSize * 132).toBeLessThanOrEqual(65_535)
    expect((batchSize + 1) * 132).toBeGreaterThan(65_535)
    expect(postgresImportBatchSize(2)).toBe(500)
    expect(() => postgresImportBatchSize(0)).toThrow(/insertable column/i)
  })
})

describe('PostgresAdapter pool behavior', () => {
  it('configures TLS, server-side safety settings, and an idempotent connection probe', async () => {
    const adapter = new PostgresAdapter(input)
    const pool = currentPool()
    const probe = client()
    pool.connect.mockResolvedValue(probe)

    expect(pool.config).toMatchObject({
      host: input.host,
      port: input.port,
      user: input.username,
      password: input.password,
      database: input.database,
      ssl: { rejectUnauthorized: true },
      connectionTimeoutMillis: 10_000,
      statement_timeout: 30_000,
      options: '-c default_transaction_read_only=on'
    })

    await Promise.all([adapter.connect(), adapter.connect()])
    expect(pool.connect).toHaveBeenCalledTimes(1)
    expect(probe.release).toHaveBeenCalledTimes(1)

    await adapter.close()
    expect(pool.end).toHaveBeenCalledTimes(1)
  })

  it('builds a schema tree and safely quotes preview identifiers', async () => {
    const adapter = new PostgresAdapter(input)
    const pool = currentPool()
    const probe = client()
    pool.connect.mockResolvedValueOnce(probe)
    pool.query.mockResolvedValueOnce(result([
      ['odd"schema', null, null],
      ['odd"schema', 'user"table', 'r'],
      ['public', 'monthly_report', 'm']
    ]))

    const objects = await adapter.listObjects(profile)
    const table = objects.find((object) => object.name === 'user"table')
    const parent = objects.find((object) => object.id === table?.parentId)

    expect(table).toMatchObject({ kind: 'table', name: 'user"table' })
    expect(parent).toMatchObject({ kind: 'schema', name: 'odd"schema', detail: '1 object' })
    expect(pool.query).toHaveBeenCalledWith(expect.objectContaining({ rowMode: 'array' }))

    const preview = await adapter.previewObject(profile, table!.id)
    expect(preview).toEqual({
      engine: 'postgresql',
      kind: 'query',
      text: 'SELECT *\nFROM "odd""schema"."user""table"\nLIMIT 100;'
    })
  })

  it('executes in array mode and emits aligned, precision-safe bounded rows', async () => {
    const adapter = new PostgresAdapter(input)
    const pool = currentPool()
    const probe = client()
    const queryClient = client()
    pool.connect.mockResolvedValueOnce(probe)
    await adapter.connect()
    pool.connect.mockResolvedValueOnce(queryClient)

    queryClient.query
      .mockResolvedValueOnce(result([[7312]]))
      .mockResolvedValueOnce(result([
        [9_007_199_254_740_993n, '2026-08-31 00:00:00+00', Buffer.from([1, 2])],
        [2n, '2026-09-01 00:00:00+00', Buffer.from([3])],
        [3n, '2026-09-02 00:00:00+00', Buffer.from([4])]
      ], [
        { name: 'value', dataTypeID: 20 },
        { name: 'created_at', dataTypeID: 1184 },
        { name: 'payload', dataTypeID: 17 }
      ]))

    const query = { engine: 'postgresql', kind: 'query', text: 'SELECT * FROM events' } as const
    const databaseResult = await adapter.execute(profile, query, options('rows'))

    expect(queryClient.query).toHaveBeenNthCalledWith(1, {
      text: 'SELECT pg_catalog.pg_backend_pid()',
      rowMode: 'array'
    })
    expect(queryClient.query).toHaveBeenNthCalledWith(2, {
      text: query.text,
      rowMode: 'array'
    })
    expect(databaseResult).toMatchObject({
      kind: 'rows',
      columns: [
        { key: 'value', dataType: 'int8', align: 'end' },
        { key: 'created_at', dataType: 'timestamptz', align: 'start' },
        { key: 'payload', dataType: 'bytea', align: 'start' }
      ],
      rows: [
        ['9007199254740993', '2026-08-31 00:00:00+00', { $binary: 'AQI=' }],
        ['2', '2026-09-01 00:00:00+00', { $binary: 'Aw==' }]
      ],
      meta: { count: 2, truncated: true, source: 'database' }
    })
    expect(queryClient.release).toHaveBeenCalledTimes(1)
  })

  it('remembers cancellation requested while the initial connection is pending', async () => {
    const adapter = new PostgresAdapter(input)
    const pool = currentPool()
    const probe = client()
    let resolveProbe!: (value: ReturnType<typeof client>) => void
    const pendingProbe = new Promise<ReturnType<typeof client>>((resolve) => {
      resolveProbe = resolve
    })
    pool.connect.mockReturnValueOnce(pendingProbe)

    const outcome = adapter
      .execute(
        profile,
        { engine: 'postgresql', kind: 'query', text: 'SELECT 1' },
        options('cancel-before-connect')
      )
      .then(
        () => ({ status: 'resolved' as const }),
        (error: unknown) => ({ status: 'rejected' as const, error })
      )

    await vi.waitFor(() => expect(pool.connect).toHaveBeenCalledTimes(1))
    await adapter.cancel('cancel-before-connect')
    resolveProbe(probe)

    const settled = await outcome
    expect(settled.status).toBe('rejected')
    if (settled.status === 'rejected') {
      expect(settled.error).toBeInstanceOf(Error)
      expect((settled.error as Error).message).toMatch(/cancelled/i)
    }
    expect(pool.connect).toHaveBeenCalledTimes(1)
    expect(probe.release).toHaveBeenCalledTimes(1)
  })

  it('cancels an active query through a dedicated out-of-pool client', async () => {
    const adapter = new PostgresAdapter(input)
    const pool = currentPool()
    const probe = client()
    const queryClient = client()
    pool.connect.mockResolvedValueOnce(probe)
    await adapter.connect()

    let rejectQuery!: (error: Error & { code: string }) => void
    const pendingQuery = new Promise<never>((_resolve, reject) => {
      rejectQuery = reject
    })
    queryClient.query
      .mockResolvedValueOnce(result([[8124]]))
      .mockReturnValueOnce(pendingQuery)
    pgMock.clientQuery.mockImplementationOnce(async () => {
      rejectQuery(Object.assign(new Error('canceling statement due to user request'), {
        code: '57014'
      }))
      return result([[true]])
    })
    pool.connect.mockResolvedValueOnce(queryClient)

    const outcome = adapter
      .execute(
        profile,
        { engine: 'postgresql', kind: 'query', text: 'SELECT pg_sleep(10)' },
        options('active-cancel')
      )
      .then(
        () => ({ status: 'resolved' as const }),
        (error: unknown) => ({ status: 'rejected' as const, error })
      )

    await vi.waitFor(() => expect(queryClient.query).toHaveBeenCalledTimes(2))
    await adapter.cancel('active-cancel')
    const settled = await outcome

    expect(settled.status).toBe('rejected')
    if (settled.status === 'rejected') {
      expect((settled.error as Error).message).toMatch(/cancelled/i)
    }
    expect(pgMock.clients).toHaveLength(1)
    const cancelClient = pgMock.clients[0]
    expect(cancelClient.config).toMatchObject({
      host: input.host,
      port: input.port,
      database: input.database,
      application_name: 'dbbbb'
    })
    expect(cancelClient.connect).toHaveBeenCalledTimes(1)
    expect(cancelClient.query).toHaveBeenCalledWith({
      text: 'SELECT pg_catalog.pg_cancel_backend($1)',
      values: [8124],
      rowMode: 'array'
    })
    expect(cancelClient.end).toHaveBeenCalledTimes(1)
    expect(queryClient.release).toHaveBeenCalledTimes(1)
  })

  it('destroys the client instead of pooling it after a connection-level failure', async () => {
    const adapter = new PostgresAdapter(input)
    const pool = currentPool()
    const probe = client()
    const queryClient = client()
    pool.connect.mockResolvedValueOnce(probe)
    await adapter.connect()
    pool.connect.mockResolvedValueOnce(queryClient)

    const failure = Object.assign(new Error('Connection terminated unexpectedly'), {
      code: 'ECONNRESET'
    })
    queryClient.query
      .mockResolvedValueOnce(result([[7312]]))
      .mockRejectedValueOnce(failure)

    await expect(adapter.execute(
      profile,
      { engine: 'postgresql', kind: 'query', text: 'SELECT 1' },
      options('connection-failure')
    )).rejects.toThrow(/query failed/i)
    expect(queryClient.release).toHaveBeenCalledWith(failure)
  })

  it('redacts credentials from driver errors while preserving a safe SQLSTATE', async () => {
    const adapter = new PostgresAdapter(input)
    const pool = currentPool()
    pool.connect.mockRejectedValueOnce(Object.assign(
      new Error('password=top-secret postgresql://dbbbb:top-secret@db.internal/product'),
      { code: '28P01' }
    ))

    const error = await adapter.connect().catch((caught: unknown) => caught)
    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).not.toContain(input.password)
    expect((error as Error).message).toContain('[redacted]')
    expect((error as Error & { code?: string }).code).toBe('28P01')
  })
})

describe('PostgresAdapter single-row changes', () => {
  it('plans and applies a parameterized composite-key update in catalog order', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool, 'odd"schema', 'user"table')
    const changeClient = client()
    const hostileValue = "after'); DROP TABLE audit; --"
    pool.connect.mockResolvedValueOnce(changeClient)
    changeClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      if (text.includes('primary_key_ordinal')) {
        return result([
          ['id', 23, 'int4', 2],
          ['tenant_id', 23, 'int4', 1],
          ['display"name', 25, 'text', 0],
          ['note', 25, 'text', 0]
        ])
      }
      if (text.startsWith('UPDATE ')) return { ...result([[]]), rowCount: 1 }
      return result([])
    })

    const changed = await adapter.applyDataChange(writableProfile, target.id, {
      action: 'update',
      original: {
        note: null,
        'display"name': 'before',
        tenant_id: 9,
        id: 42
      },
      current: {
        tenant_id: 9,
        id: 42,
        note: '',
        'display"name': hostileValue
      }
    })

    expect(changed).toEqual({ action: 'update', affected: 1 })
    expect(changeClient.query).toHaveBeenNthCalledWith(1, 'BEGIN')
    expect(changeClient.query).toHaveBeenNthCalledWith(2, expect.objectContaining({
      values: ['odd"schema', 'user"table'],
      rowMode: 'array'
    }))
    const metadataQuery = changeClient.query.mock.calls[1][0] as { text: string }
    expect(metadataQuery.text).toContain('a.atttypid')
    expect(metadataQuery.text).toContain('t.typname')
    expect(metadataQuery.text).toContain('has_column_privilege')
    expect(metadataQuery.text).toContain('WITH ORDINALITY')
    expect(metadataQuery.text).not.toContain('array_position')
    expect(metadataQuery.text).toContain('ORDER BY a.attnum')
    expect(changeClient.query).toHaveBeenNthCalledWith(3, {
      text: [
        'UPDATE "odd""schema"."user""table"',
        'SET "display""name" = $1,',
        '    "note" = $2',
        'WHERE "tenant_id" IS NOT DISTINCT FROM $3',
        '  AND "id" IS NOT DISTINCT FROM $4',
        '  AND "display""name" IS NOT DISTINCT FROM $5',
        '  AND "note" IS NOT DISTINCT FROM $6',
        'RETURNING *;'
      ].join('\n'),
      values: [hostileValue, '', 9, 42, 'before', null],
      rowMode: 'array'
    })
    expect((changeClient.query.mock.calls[2][0] as { text: string }).text).not.toContain(
      hostileValue
    )
    expect(changeClient.query).toHaveBeenNthCalledWith(4, 'COMMIT')
    expect(changeClient.release).toHaveBeenCalledTimes(1)
  })

  it('decodes canonical bytea wire values without treating tagged JSON as binary', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool)
    const changeClient = client()
    const originalDocument = { $binary: 'ordinary JSON' }
    const currentDocument = { $binary: 'still ordinary JSON' }
    pool.connect.mockResolvedValueOnce(changeClient)
    changeClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      if (text.includes('primary_key_ordinal')) {
        return result([
          ['id', 23, 'int4', 1],
          ['payload', 17, 'bytea', 0],
          ['document', 3802, 'jsonb', 0]
        ])
      }
      if (text.startsWith('UPDATE ')) return { ...result([[]]), rowCount: 1 }
      return result([])
    })

    await expect(adapter.applyDataChange(writableProfile, target.id, {
      action: 'update',
      original: {
        id: 1,
        payload: { $binary: 'AQID' },
        document: originalDocument
      },
      current: {
        id: 1,
        payload: { $binary: 'BAUG' },
        document: currentDocument
      }
    })).resolves.toEqual({ action: 'update', affected: 1 })

    expect(changeClient.query).toHaveBeenNthCalledWith(3, {
      text: [
        'UPDATE "public"."events"',
        'SET "payload" = $1,',
        '    "document" = $2',
        'WHERE "id" IS NOT DISTINCT FROM $3',
        '  AND "payload" IS NOT DISTINCT FROM $4',
        '  AND "document" IS NOT DISTINCT FROM $5',
        'RETURNING *;'
      ].join('\n'),
      values: [
        Buffer.from([4, 5, 6]),
        currentDocument,
        1,
        Buffer.from([1, 2, 3]),
        originalDocument
      ],
      rowMode: 'array'
    })
  })

  it('rejects non-canonical bytea wire values before issuing DML', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool)
    const changeClient = client()
    pool.connect.mockResolvedValueOnce(changeClient)
    changeClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      return text.includes('primary_key_ordinal')
        ? result([['id', 23, 'int4', 1], ['payload', 17, 'bytea', 0]])
        : result([])
    })

    await expect(adapter.applyDataChange(writableProfile, target.id, {
      action: 'update',
      original: { id: 1, payload: { $binary: 'AQI' } },
      current: { id: 1, payload: { $binary: 'AQID' } }
    })).rejects.toThrow(/canonical PostgreSQL binary value/i)

    expect(changeClient.query).toHaveBeenCalledWith('ROLLBACK')
    expect(changeClient.query.mock.calls.some(([query]) =>
      typeof query !== 'string' && /^(UPDATE|DELETE) /.test(query.text)
    )).toBe(false)
  })

  it('plans and applies a parameterized delete', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool)
    const changeClient = client()
    pool.connect.mockResolvedValueOnce(changeClient)
    changeClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      if (text.includes('primary_key_ordinal')) {
        return result([['id', 23, 'int4', 1], ['status', 25, 'text', 0]])
      }
      if (text.startsWith('DELETE ')) return { ...result([[]]), rowCount: 1 }
      return result([])
    })

    const changed = await adapter.applyDataChange(writableProfile, target.id, {
      action: 'delete',
      original: { status: 'active', id: 'event-1' }
    })

    expect(changed).toEqual({ action: 'delete', affected: 1 })
    expect(changeClient.query).toHaveBeenNthCalledWith(3, {
      text: [
        'DELETE FROM "public"."events"',
        'WHERE "id" IS NOT DISTINCT FROM $1',
        '  AND "status" IS NOT DISTINCT FROM $2',
        'RETURNING *;'
      ].join('\n'),
      values: ['event-1', 'active'],
      rowMode: 'array'
    })
    expect(changeClient.query).toHaveBeenNthCalledWith(4, 'COMMIT')
  })

  it('rolls back and reports a clear optimistic-concurrency conflict for zero rows', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool)
    const changeClient = client()
    pool.connect.mockResolvedValueOnce(changeClient)
    changeClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      if (text.includes('primary_key_ordinal')) {
        return result([['id', 23, 'int4', 1], ['status', 25, 'text', 0]])
      }
      if (text.startsWith('UPDATE ')) return { ...result([]), rowCount: 0 }
      return result([])
    })

    const changing = adapter.applyDataChange(writableProfile, target.id, {
      action: 'update',
      original: { id: 1, status: 'before' },
      current: { id: 1, status: 'after' }
    })

    await expect(changing).rejects.toThrow(/optimistic-concurrency conflict/i)
    expect(changeClient.query).toHaveBeenCalledWith('ROLLBACK')
    expect(changeClient.query).not.toHaveBeenCalledWith('COMMIT')
    expect(changeClient.release).toHaveBeenCalledTimes(1)
  })

  it('rolls back instead of accepting an unexpected multi-row result', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool)
    const changeClient = client()
    pool.connect.mockResolvedValueOnce(changeClient)
    changeClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      if (text.includes('primary_key_ordinal')) {
        return result([['id', 23, 'int4', 1], ['status', 25, 'text', 0]])
      }
      if (text.startsWith('DELETE ')) return { ...result([[], []]), rowCount: 2 }
      return result([])
    })

    await expect(adapter.applyDataChange(writableProfile, target.id, {
      action: 'delete',
      original: { id: 1, status: 'active' }
    })).rejects.toThrow(/unexpected affected-row count/i)
    expect(changeClient.query).toHaveBeenCalledWith('ROLLBACK')
    expect(changeClient.query).not.toHaveBeenCalledWith('COMMIT')
  })

  it('rejects absent or malformed primary-key and field metadata before DML', async () => {
    const cases: Array<{
      metadata: unknown[][]
      change: AdapterDataChange
      message: RegExp
    }> = [
      {
        metadata: [['id', 23, 'int4', 0], ['name', 25, 'text', 0]],
        change: {
          action: 'update' as const,
          original: { id: 1, name: 'before' },
          current: { id: 1, name: 'after' }
        },
        message: /require a table primary key/i
      },
      {
        metadata: [['id', 23, 'int4', 1], ['name', 25, 'text', 0]],
        change: {
          action: 'update' as const,
          original: { name: 'before' },
          current: { name: 'after' }
        },
        message: /missing a primary-key value/i
      },
      {
        metadata: [['id', 23, 'int4', 1], ['name', 25, 'text', 0]],
        change: {
          action: 'update' as const,
          original: { id: 1, name: 'before', injected: 'private' },
          current: { id: 1, name: 'after', injected: 'private' }
        },
        message: /unknown table field/i
      },
      {
        metadata: [['id', 23, 'int4', 1], ['name', 25, 'text', 0]],
        change: {
          action: 'update' as const,
          original: { id: 1, name: 'before' },
          current: { id: 2, name: 'after' }
        },
        message: /cannot be edited/i
      },
      {
        metadata: [['id', 23, 'int4', 1], ['payload', 114, 'json', 0]],
        change: {
          action: 'update' as const,
          original: { id: 1, payload: '{"a":1}' },
          current: { id: 1, payload: '{"a":2}' }
        },
        message: /do not round-trip losslessly/i
      },
      {
        metadata: [['id', 23, 'int4', 1], ['span', 3904, 'int4range', 0]],
        change: {
          action: 'delete' as const,
          original: { id: 1, span: '[1,5)' }
        },
        message: /do not round-trip losslessly/i
      }
    ]

    for (const testCase of cases) {
      const adapter = new PostgresAdapter(writableInput)
      const pool = currentPool()
      const target = await introspectTarget(adapter, pool)
      const changeClient = client()
      pool.connect.mockResolvedValueOnce(changeClient)
      changeClient.query.mockImplementation(async (query: string | { text: string }) => {
        const text = typeof query === 'string' ? query : query.text
        return text.includes('primary_key_ordinal')
          ? result(testCase.metadata)
          : result([])
      })

      await expect(
        adapter.applyDataChange(writableProfile, target.id, testCase.change)
      ).rejects.toThrow(testCase.message)
      expect(changeClient.query).toHaveBeenCalledWith('ROLLBACK')
      expect(changeClient.query.mock.calls.some(([query]) =>
        typeof query !== 'string' && /^(UPDATE|DELETE) /.test(query.text)
      )).toBe(false)
    }
  })

  it('rejects read-only, invalid, and non-table requests before opening a write client', async () => {
    const writableAdapter = new PostgresAdapter(writableInput)
    const writablePool = currentPool()
    await expect(writableAdapter.applyDataChange(writableProfile, 'missing', {
      action: 'update',
      original: { id: 1 },
      current: { id: 1 }
    })).rejects.toThrow(/introspected table/i)
    await expect(writableAdapter.applyDataChange(writableProfile, 'missing', {
      action: 'update',
      original: { id: 1 }
    })).rejects.toThrow(/requires current/i)
    await expect(writableAdapter.applyDataChange(
      { ...writableProfile, demo: true },
      'missing',
      { action: 'delete', original: { id: 1 } }
    )).rejects.toThrow(/real database/i)
    expect(writablePool.connect).not.toHaveBeenCalled()

    const readOnlyAdapter = new PostgresAdapter(input)
    const readOnlyPool = currentPool()
    await expect(readOnlyAdapter.applyDataChange({ ...profile, readOnly: false }, 'anything', {
      action: 'delete',
      original: { id: 1 }
    })).rejects.toThrow(/read-only/i)
    expect(readOnlyPool.connect).not.toHaveBeenCalled()

    const profileReadOnlyAdapter = new PostgresAdapter(writableInput)
    const profileReadOnlyPool = currentPool()
    await expect(profileReadOnlyAdapter.applyDataChange(
      { ...writableProfile, readOnly: true },
      'anything',
      { action: 'delete', original: { id: 1 } }
    )).rejects.toThrow(/read-only/i)
    expect(profileReadOnlyPool.connect).not.toHaveBeenCalled()

    const viewAdapter = new PostgresAdapter(writableInput)
    const viewPool = currentPool()
    const view = await introspectTarget(viewAdapter, viewPool, 'public', 'report', 'v')
    await expect(viewAdapter.applyDataChange(writableProfile, view.id, {
      action: 'delete',
      original: { id: 1 }
    })).rejects.toThrow(/table target/i)
    expect(viewPool.connect).toHaveBeenCalledTimes(1)
  })

  it('rolls back driver errors and redacts credentials', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool)
    const changeClient = client()
    pool.connect.mockResolvedValueOnce(changeClient)
    changeClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      if (text.includes('primary_key_ordinal')) {
        return result([['id', 23, 'int4', 1], ['status', 25, 'text', 0]])
      }
      if (text.startsWith('DELETE ')) {
        throw Object.assign(new Error(`password=${input.password}`), { code: '23514' })
      }
      return result([])
    })

    const error = await adapter.applyDataChange(writableProfile, target.id, {
      action: 'delete',
      original: { id: 1, status: 'active' }
    }).catch((caught: unknown) => caught)

    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).not.toContain(input.password)
    expect((error as Error).message).toContain('[redacted]')
    expect((error as Error & { code?: string }).code).toBe('23514')
    expect(changeClient.query).toHaveBeenCalledWith('ROLLBACK')
    expect(changeClient.release).toHaveBeenCalledTimes(1)
  })
})

describe('PostgresAdapter CSV import', () => {
  it('imports a header-mapped batch in one explicit transaction and preserves empty strings', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool, 'odd"schema', 'user"table')
    const importClient = client()
    pool.connect.mockResolvedValueOnce(importClient)
    importClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      if (text.includes('pg_catalog.pg_attribute')) {
        return result([['id'], ['name'], ['note']])
      }
      return result([])
    })

    const csv = 'name,id,note\nAda,1,\nBob,2,hello\n'
    const onProgress = vi.fn()
    const summary = await adapter.importData(
      writableProfile,
      target.id,
      Readable.from([csv]),
      { format: 'csv', hasHeader: true, onProgress }
    )

    expect(summary).toEqual({ processed: 2, inserted: 2, failed: 0 })
    expect(onProgress).toHaveBeenLastCalledWith({
      processed: 2,
      inserted: 2,
      failed: 0,
      bytes: Buffer.byteLength(csv)
    })
    expect(importClient.query).toHaveBeenNthCalledWith(1, expect.objectContaining({
      values: ['odd"schema', 'user"table'],
      rowMode: 'array'
    }))
    const metadataQuery = importClient.query.mock.calls[0][0] as { text: string }
    expect(metadataQuery.text).toContain('ORDER BY a.attnum')
    expect(metadataQuery.text).toContain("a.attgenerated = ''")
    expect(metadataQuery.text).toContain("a.attidentity <> 'a'")
    expect(metadataQuery.text).toContain('has_column_privilege')
    expect(importClient.query).toHaveBeenNthCalledWith(2, 'BEGIN')
    expect(importClient.query).toHaveBeenNthCalledWith(3, {
      text: [
        'INSERT INTO "odd""schema"."user""table"',
        '("name", "id", "note")',
        'VALUES ($1, $2, $3),',
        '       ($4, $5, $6)'
      ].join('\n'),
      values: ['Ada', '1', '', 'Bob', '2', 'hello']
    })
    expect(importClient.query).toHaveBeenNthCalledWith(4, 'COMMIT')
    expect(importClient.release).toHaveBeenCalledTimes(1)
  })

  it('uses attnum column order as an explicit header for headerless CSV', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool)
    const importClient = client()
    pool.connect.mockResolvedValueOnce(importClient)
    importClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      return text.includes('pg_catalog.pg_attribute')
        ? result([['id'], ['name'], ['note']])
        : result([])
    })

    const summary = await adapter.importData(
      writableProfile,
      target.id,
      Readable.from(['1,Ada,\n2,Bob,x\n']),
      { format: 'csv', hasHeader: false }
    )

    expect(summary).toEqual({ processed: 2, inserted: 2, failed: 0 })
    expect(importClient.query).toHaveBeenNthCalledWith(3, {
      text: [
        'INSERT INTO "public"."events"',
        '("id", "name", "note")',
        'VALUES ($1, $2, $3),',
        '       ($4, $5, $6)'
      ].join('\n'),
      values: ['1', 'Ada', '', '2', 'Bob', 'x']
    })
  })

  it('rejects unsupported, read-only, and non-introspected targets before writing', async () => {
    const writableAdapter = new PostgresAdapter(writableInput)
    const writablePool = currentPool()

    await expect(writableAdapter.importData(
      writableProfile,
      'missing-table',
      Readable.from(['id\n1\n']),
      { format: 'jsonl', hasHeader: true }
    )).rejects.toThrow(/only supports CSV/i)
    await expect(writableAdapter.importData(
      writableProfile,
      'missing-table',
      Readable.from(['id\n1\n']),
      { format: 'csv', hasHeader: true }
    )).rejects.toThrow(/introspected table/i)
    expect(writablePool.connect).not.toHaveBeenCalled()

    const readOnlyAdapter = new PostgresAdapter(input)
    const readOnlyPool = currentPool()
    await expect(readOnlyAdapter.importData(
      { ...profile, readOnly: false },
      'anything',
      Readable.from(['id\n1\n']),
      { format: 'csv', hasHeader: true }
    )).rejects.toThrow(/read-only/i)
    expect(readOnlyPool.connect).not.toHaveBeenCalled()

    const profileReadOnlyAdapter = new PostgresAdapter(writableInput)
    const profileReadOnlyPool = currentPool()
    await expect(profileReadOnlyAdapter.importData(
      { ...writableProfile, readOnly: true },
      'anything',
      Readable.from(['id\n1\n']),
      { format: 'csv', hasHeader: true }
    )).rejects.toThrow(/read-only/i)
    expect(profileReadOnlyPool.connect).not.toHaveBeenCalled()

    const viewAdapter = new PostgresAdapter(writableInput)
    const viewPool = currentPool()
    const view = await introspectTarget(viewAdapter, viewPool, 'public', 'report', 'v')
    await expect(viewAdapter.importData(
      writableProfile,
      view.id,
      Readable.from(['id\n1\n']),
      { format: 'csv', hasHeader: true }
    )).rejects.toThrow(/table target/i)
    expect(viewPool.connect).toHaveBeenCalledTimes(1)
  })

  it('rolls back the whole import when a batch insert fails', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool)
    const importClient = client()
    pool.connect.mockResolvedValueOnce(importClient)
    importClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      if (text.includes('pg_catalog.pg_attribute')) return result([['id'], ['note']])
      if (text.startsWith('INSERT INTO')) {
        throw new Error('database rejected PRIVATE_ROW_CONTENT')
      }
      return result([])
    })

    const importing = adapter.importData(
      writableProfile,
      target.id,
      Readable.from(['id,note\n1,PRIVATE_ROW_CONTENT\n']),
      { format: 'csv', hasHeader: true }
    )
    const error = await importing.catch((caught: unknown) => caught)

    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).toMatch(/import failed/i)
    expect((error as Error).message).not.toContain('PRIVATE_ROW_CONTENT')
    expect(importClient.query).toHaveBeenCalledWith('ROLLBACK')
    expect(importClient.query).not.toHaveBeenCalledWith('COMMIT')
    expect(importClient.release).toHaveBeenCalledTimes(1)
  })

  it('checks AbortSignal around every batch and rolls back with a sanitized error', async () => {
    const adapter = new PostgresAdapter(writableInput)
    const pool = currentPool()
    const target = await introspectTarget(adapter, pool)
    const importClient = client()
    const controller = new AbortController()
    pool.connect.mockResolvedValueOnce(importClient)
    importClient.query.mockImplementation(async (query: string | { text: string }) => {
      const text = typeof query === 'string' ? query : query.text
      if (text.includes('pg_catalog.pg_attribute')) return result([['id']])
      if (text.startsWith('INSERT INTO')) {
        controller.abort(new Error('PRIVATE_ABORT_REASON'))
      }
      return result([])
    })

    const importing = adapter.importData(
      writableProfile,
      target.id,
      Readable.from(['id\n1\n']),
      { format: 'csv', hasHeader: true, signal: controller.signal }
    )
    const error = await importing.catch((caught: unknown) => caught)

    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).toBe('PostgreSQL import was aborted.')
    expect((error as Error).message).not.toContain('PRIVATE_ABORT_REASON')
    expect(importClient.query).toHaveBeenCalledWith('ROLLBACK')
    expect(importClient.query).not.toHaveBeenCalledWith('COMMIT')
    expect(importClient.release).toHaveBeenCalledTimes(1)
  })
})
