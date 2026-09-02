import { randomUUID } from 'node:crypto'
import { Readable } from 'node:stream'
import { Pool, escapeIdentifier } from 'pg'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type {
  ConnectionProfile,
  PostgresConnectionInput,
  PostgresSslMode,
  RowResult,
  WireValue
} from '../../shared/database'
import type { ExecuteOptions } from './database-adapter'
import { PostgresAdapter } from './postgres-adapter'

const connectionUrl = process.env.DBBBB_TEST_POSTGRES_URL?.trim()
const describeWithPostgres = connectionUrl ? describe : describe.skip
const writeEnabled = Boolean(
  connectionUrl && process.env.DBBBB_TEST_POSTGRES_ENABLE_WRITE?.trim() === '1'
)
const describeWithPostgresWrites = writeEnabled ? describe : describe.skip

function connectionInputFromUrl(rawUrl: string): PostgresConnectionInput {
  const url = new URL(rawUrl)
  if (!['postgres:', 'postgresql:'].includes(url.protocol)) {
    throw new Error('DBBBB_TEST_POSTGRES_URL must use the postgres or postgresql protocol.')
  }

  const database = decodeURIComponent(url.pathname.replace(/^\//, ''))
  if (!url.hostname || !url.username || !database) {
    throw new Error('DBBBB_TEST_POSTGRES_URL must include a host, username, and database.')
  }

  const requestedSslMode = url.searchParams.get('sslmode') ?? 'disable'
  if (!['disable', 'require', 'verify-full'].includes(requestedSslMode)) {
    throw new Error(
      'DBBBB_TEST_POSTGRES_URL sslmode must be disable, require, or verify-full.'
    )
  }

  return {
    engine: 'postgresql',
    name: 'PostgreSQL integration test',
    host: url.hostname,
    port: url.port ? Number(url.port) : 5432,
    database,
    username: decodeURIComponent(url.username),
    password: decodeURIComponent(url.password),
    sslMode: requestedSslMode as PostgresSslMode,
    environment: 'development',
    readOnly: true
  }
}

function profileFromInput(input: PostgresConnectionInput): ConnectionProfile {
  return {
    id: 'postgres-integration',
    name: input.name,
    engine: 'postgresql',
    endpoint: `${input.host}:${input.port}`,
    database: input.database,
    environment: input.environment,
    readOnly: input.readOnly,
    demo: false
  }
}

function fixturePool(input: PostgresConnectionInput): Pool {
  return new Pool({
    host: input.host,
    port: input.port,
    user: input.username,
    password: input.password,
    database: input.database,
    ssl: input.sslMode === 'disable'
      ? false
      : { rejectUnauthorized: input.sslMode === 'verify-full' },
    application_name: 'dbbbb integration fixture',
    connectionTimeoutMillis: 10_000,
    max: 1
  })
}

function executeOptions(requestId: string, timeoutMs = 5_000): ExecuteOptions {
  return {
    requestId,
    timeoutMs,
    maxRows: 100,
    maxBytes: 1024 * 1024
  }
}

function requireRows(result: Awaited<ReturnType<PostgresAdapter['execute']>>): RowResult {
  expect(result.kind).toBe('rows')
  if (result.kind !== 'rows') {
    throw new Error('Expected a relational row result.')
  }
  return result
}

describeWithPostgres(
  'PostgresAdapter integration (set DBBBB_TEST_POSTGRES_URL to enable)',
  () => {
    let adapter: PostgresAdapter | undefined
    let profile: ConnectionProfile

    beforeAll(async () => {
      const input = connectionInputFromUrl(connectionUrl!)
      profile = profileFromInput(input)
      adapter = new PostgresAdapter(input)
      await adapter.connect()
    })

    afterAll(async () => {
      await adapter?.close()
    })

    it('connects and executes a bounded SELECT', async () => {
      const result = requireRows(
        await adapter!.execute(
          profile,
          { engine: 'postgresql', kind: 'query', text: 'SELECT 1::int4 AS value' },
          executeOptions('integration-select')
        )
      )

      const valueIndex = result.columns.findIndex((column) => column.label === 'value')
      expect(valueIndex).toBeGreaterThanOrEqual(0)
      expect(result.rows[0]?.[valueIndex]).toBe(1)
      expect(result.meta).toMatchObject({ count: 1, truncated: false, source: 'database' })
    })

    it('lists schemas and returns internally consistent object parents', async () => {
      const objects = await adapter!.listObjects(profile)
      const ids = new Set(objects.map((object) => object.id))

      expect(objects.some((object) => object.kind === 'schema')).toBe(true)
      for (const object of objects) {
        if (object.parentId) {
          expect(ids.has(object.parentId)).toBe(true)
        }
      }
    })

    it('puts the database session in read-only mode without writing fixture data', async () => {
      const result = requireRows(
        await adapter!.execute(
          profile,
          {
            engine: 'postgresql',
            kind: 'query',
            text: "SELECT current_setting('transaction_read_only') AS read_only"
          },
          executeOptions('integration-read-only')
        )
      )

      const readOnlyIndex = result.columns.findIndex((column) => column.label === 'read_only')
      expect(readOnlyIndex).toBeGreaterThanOrEqual(0)
      expect(result.rows[0]?.[readOnlyIndex]).toBe('on')
    })

    it('cancels only the requested query and leaves the adapter usable', async () => {
      const requestId = 'integration-cancel'
      const outcomePromise = adapter!
        .execute(
          profile,
          { engine: 'postgresql', kind: 'query', text: 'SELECT pg_sleep(10)' },
          executeOptions(requestId, 5_000)
        )
        .then(
          () => ({ status: 'resolved' as const }),
          (error: unknown) => ({ status: 'rejected' as const, error })
        )

      await new Promise((resolve) => setTimeout(resolve, 150))
      await adapter!.cancel(requestId)

      const outcome = await outcomePromise
      expect(outcome.status).toBe('rejected')
      if (outcome.status === 'rejected') {
        expect(outcome.error).toBeInstanceOf(Error)
        expect((outcome.error as Error).message).toMatch(/cancel/i)
      }

      const followUp = requireRows(
        await adapter!.execute(
          profile,
          { engine: 'postgresql', kind: 'query', text: 'SELECT 1::int4 AS value' },
          executeOptions('integration-after-cancel')
        )
      )
      expect(followUp.rows[0]?.[0]).toBe(1)
    })
  }
)

describeWithPostgresWrites(
  'PostgresAdapter isolated writes (also set DBBBB_TEST_POSTGRES_ENABLE_WRITE=1)',
  () => {
    let adapter: PostgresAdapter | undefined
    let adminPool: Pool | undefined
    let profile: ConnectionProfile
    let schemaName = ''
    const tableName = 'editable_rows'
    const temporalTableName = 'editable_temporal'
    let tableObjectId = ''
    let temporalTableObjectId = ''

    beforeAll(async () => {
      const input: PostgresConnectionInput = {
        ...connectionInputFromUrl(connectionUrl!),
        name: 'PostgreSQL write integration test',
        readOnly: false
      }
      profile = profileFromInput(input)
      schemaName = `dbbbb_it_${randomUUID().replaceAll('-', '_')}`
      adminPool = fixturePool(input)

      await adminPool.query(`CREATE SCHEMA ${escapeIdentifier(schemaName)}`)
      await adminPool.query([
        `CREATE TABLE ${escapeIdentifier(schemaName)}.${escapeIdentifier(tableName)} (`,
        '  id integer PRIMARY KEY,',
        '  name text NOT NULL,',
        '  note text,',
        '  version integer NOT NULL DEFAULT 1,',
        "  payload bytea NOT NULL DEFAULT pg_catalog.decode('010203', 'hex')",
        ')'
      ].join('\n'))
      await adminPool.query([
        `CREATE TABLE ${escapeIdentifier(schemaName)}.${escapeIdentifier(temporalTableName)} (`,
        '  id integer PRIMARY KEY,',
        '  name text NOT NULL,',
        '  happened_on date NOT NULL,',
        '  happened_at timestamp with time zone NOT NULL',
        ')'
      ].join('\n'))

      adapter = new PostgresAdapter(input)
      await adapter.connect()
      const objects = await adapter.listObjects(profile)
      const schema = objects.find(
        (object) => object.kind === 'schema' && object.name === schemaName
      )
      const table = objects.find(
        (object) =>
          object.kind === 'table' &&
          object.name === tableName &&
          object.parentId === schema?.id
      )
      const temporalTable = objects.find(
        (object) =>
          object.kind === 'table' &&
          object.name === temporalTableName &&
          object.parentId === schema?.id
      )
      if (!schema || !table || !temporalTable) {
        throw new Error('The isolated PostgreSQL write fixture was not introspected.')
      }
      tableObjectId = table.id
      temporalTableObjectId = temporalTable.id
    })

    afterAll(async () => {
      let cleanupError: unknown
      try {
        if (adminPool && schemaName) {
          await adminPool.query(
            `DROP SCHEMA IF EXISTS ${escapeIdentifier(schemaName)} CASCADE`
          )
        }
      } catch (error) {
        cleanupError = error
      } finally {
        const closing: Promise<void>[] = []
        if (adapter) closing.push(adapter.close())
        if (adminPool) closing.push(adminPool.end())
        await Promise.allSettled(closing)
      }
      if (cleanupError) throw cleanupError
    })

    it('imports, previews, updates optimistically, rejects stale data, and deletes', async () => {
      const headerImport = await adapter!.importData(
        profile,
        tableObjectId,
        Readable.from(['id,name,note,version\n1,Ada,,1\n']),
        { format: 'csv', hasHeader: true }
      )
      expect(headerImport).toEqual({ processed: 1, inserted: 1, failed: 0 })

      const headerlessImport = await adapter!.importData(
        profile,
        tableObjectId,
        Readable.from(['2,Bob,initial,1,\n']),
        { format: 'csv', hasHeader: false }
      )
      expect(headerlessImport).toEqual({ processed: 1, inserted: 1, failed: 0 })

      const preview = await adapter!.previewObject(profile, tableObjectId)
      expect(preview.kind).toBe('query')
      if (preview.kind !== 'query') throw new Error('Expected a PostgreSQL preview query.')
      const previewRows = requireRows(
        await adapter!.execute(profile, preview, executeOptions('write-preview'))
      )
      const idIndex = previewRows.columns.findIndex((column) => column.label === 'id')
      const noteIndex = previewRows.columns.findIndex((column) => column.label === 'note')
      const payloadIndex = previewRows.columns.findIndex((column) => column.label === 'payload')
      expect(idIndex).toBeGreaterThanOrEqual(0)
      expect(noteIndex).toBeGreaterThanOrEqual(0)
      expect(payloadIndex).toBeGreaterThanOrEqual(0)
      expect(previewRows.rows.find((row) => row[idIndex] === 1)?.[noteIndex]).toBe('')
      expect(previewRows.rows.find((row) => row[idIndex] === 1)?.[payloadIndex]).toEqual({
        $binary: 'AQID'
      })
      expect(previewRows.rows.find((row) => row[idIndex] === 2)?.[payloadIndex]).toEqual({
        $binary: ''
      })
      expect(previewRows.rows.some((row) => row[idIndex] === 2)).toBe(true)

      const original = {
        id: 1,
        name: 'Ada',
        note: '',
        version: 1,
        payload: { $binary: 'AQID' }
      }
      const current = {
        id: 1,
        name: 'Ada Lovelace',
        note: 'edited',
        version: 2,
        payload: { $binary: 'BAUG' }
      }
      await expect(adapter!.applyDataChange(profile, tableObjectId, {
        action: 'update',
        original,
        current
      })).resolves.toEqual({ action: 'update', affected: 1 })

      await expect(adapter!.applyDataChange(profile, tableObjectId, {
        action: 'update',
        original,
        current
      })).rejects.toThrow(/optimistic-concurrency conflict/i)

      await expect(adapter!.applyDataChange(profile, tableObjectId, {
        action: 'delete',
        original: current
      })).resolves.toEqual({ action: 'delete', affected: 1 })

      const finalRows = requireRows(
        await adapter!.execute(
          profile,
          {
            engine: 'postgresql',
            kind: 'query',
            text: [
              'SELECT id, name, note, version',
              `FROM ${escapeIdentifier(schemaName)}.${escapeIdentifier(tableName)}`,
              'ORDER BY id'
            ].join('\n')
          },
          executeOptions('write-final')
        )
      )
      expect(finalRows.rows).toEqual([[2, 'Bob', 'initial', 1]])
    })

    it('round-trips date and timestamptz columns through an optimistic edit', async () => {
      await adminPool!.query(
        [
          `INSERT INTO ${escapeIdentifier(schemaName)}.${escapeIdentifier(temporalTableName)}`,
          '(id, name, happened_on, happened_at)',
          "VALUES (1, 'Cara', '2026-08-31', '2026-08-31 12:34:56.789123+00')"
        ].join('\n')
      )

      const readRow = async (requestId: string) => {
        const rows = requireRows(
          await adapter!.execute(
            profile,
            {
              engine: 'postgresql',
              kind: 'query',
              text: [
                'SELECT *',
                `FROM ${escapeIdentifier(schemaName)}.${escapeIdentifier(temporalTableName)}`,
                'WHERE id = 1'
              ].join('\n')
            },
            executeOptions(requestId)
          )
        )
        const row = rows.rows[0]
        expect(row).toBeDefined()
        const record = Object.create(null) as Record<string, WireValue>
        rows.columns.forEach((column, index) => {
          record[column.label] = row[index]
        })
        return record
      }

      const original = await readRow('write-temporal-read')
      // Raw driver text, not a host-timezone Date re-encoding.
      expect(original.happened_on).toBe('2026-08-31')
      expect(String(original.happened_at)).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)

      await expect(adapter!.applyDataChange(profile, temporalTableObjectId, {
        action: 'update',
        original,
        current: { ...original, name: 'Cara S.' }
      })).resolves.toEqual({ action: 'update', affected: 1 })

      const reread = await readRow('write-temporal-reread')
      expect(reread.name).toBe('Cara S.')
      expect(reread.happened_on).toBe(original.happened_on)
      expect(reread.happened_at).toBe(original.happened_at)

      await expect(adapter!.applyDataChange(profile, temporalTableObjectId, {
        action: 'delete',
        original: reread
      })).resolves.toEqual({ action: 'delete', affected: 1 })
    })
  }
)
