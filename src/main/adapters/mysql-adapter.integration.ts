import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type {
  ConnectionProfile,
  MySqlConnectionInput,
  MySqlSslMode,
  RowResult
} from '../../shared/database'
import type { ExecuteOptions } from './database-adapter'
import { MySqlAdapter } from './mysql-adapter'

const connectionUrl = process.env.DBBBB_TEST_MYSQL_URL?.trim()
const describeWithMySql = connectionUrl ? describe : describe.skip

function connectionInputFromUrl(rawUrl: string): MySqlConnectionInput {
  const url = new URL(rawUrl)
  if (url.protocol !== 'mysql:') {
    throw new Error('DBBBB_TEST_MYSQL_URL must use the mysql protocol.')
  }

  const database = decodeURIComponent(url.pathname.replace(/^\//, ''))
  if (!url.hostname || !url.username || !database) {
    throw new Error('DBBBB_TEST_MYSQL_URL must include a host, username, and database.')
  }

  const requestedSslMode = url.searchParams.get('sslmode') ?? 'disable'
  if (!['disable', 'require', 'verify-full'].includes(requestedSslMode)) {
    throw new Error(
      'DBBBB_TEST_MYSQL_URL sslmode must be disable, require, or verify-full.'
    )
  }

  return {
    engine: 'mysql',
    name: 'MySQL integration test',
    host: url.hostname,
    port: url.port ? Number(url.port) : 3306,
    database,
    username: decodeURIComponent(url.username),
    password: decodeURIComponent(url.password),
    sslMode: requestedSslMode as MySqlSslMode,
    environment: 'development',
    readOnly: true
  }
}

function profileFromInput(input: MySqlConnectionInput): ConnectionProfile {
  return {
    id: 'mysql-integration',
    name: input.name,
    engine: 'mysql',
    endpoint: `${input.host}:${input.port}`,
    database: input.database,
    environment: input.environment,
    readOnly: input.readOnly,
    demo: false
  }
}

function executeOptions(requestId: string, timeoutMs = 5_000): ExecuteOptions {
  return {
    requestId,
    timeoutMs,
    maxRows: 100,
    maxBytes: 1024 * 1024
  }
}

function requireRows(result: Awaited<ReturnType<MySqlAdapter['execute']>>): RowResult {
  expect(result.kind).toBe('rows')
  if (result.kind !== 'rows') {
    throw new Error('Expected a relational row result.')
  }
  return result
}

describeWithMySql(
  'MySqlAdapter integration (set DBBBB_TEST_MYSQL_URL to enable)',
  () => {
    let adapter: MySqlAdapter | undefined
    let profile: ConnectionProfile

    beforeAll(async () => {
      const input = connectionInputFromUrl(connectionUrl!)
      profile = profileFromInput(input)
      adapter = new MySqlAdapter(input)
      await adapter.connect()
    })

    afterAll(async () => {
      await adapter?.close()
    })

    it('connects and executes a bounded SELECT with fidelity-safe values', async () => {
      const result = requireRows(
        await adapter!.execute(
          profile,
          {
            engine: 'mysql',
            kind: 'query',
            text: [
              'SELECT 1 AS value,',
              "       CAST('2026-08-31 12:34:56' AS DATETIME) AS happened_at,",
              '       CAST(9007199254740993 AS SIGNED) AS big_value'
            ].join('\n')
          },
          executeOptions('integration-select')
        )
      )

      const valueIndex = result.columns.findIndex((column) => column.label === 'value')
      const happenedAtIndex = result.columns.findIndex(
        (column) => column.label === 'happened_at'
      )
      const bigValueIndex = result.columns.findIndex(
        (column) => column.label === 'big_value'
      )
      expect(valueIndex).toBeGreaterThanOrEqual(0)
      expect(happenedAtIndex).toBeGreaterThanOrEqual(0)
      expect(bigValueIndex).toBeGreaterThanOrEqual(0)
      expect(result.rows[0]?.[valueIndex]).toBe(1)
      // Raw driver text (dateStrings), not a host-timezone Date re-encoding.
      expect(result.rows[0]?.[happenedAtIndex]).toBe('2026-08-31 12:34:56')
      // BIGINT crosses as a string (bigNumberStrings) to avoid precision loss.
      expect(result.rows[0]?.[bigValueIndex]).toBe('9007199254740993')
      expect(result.meta).toMatchObject({ count: 1, truncated: false, source: 'database' })
    })

    it('lists the bound database and returns internally consistent object parents', async () => {
      const objects = await adapter!.listObjects(profile)
      const ids = new Set(objects.map((object) => object.id))

      expect(objects.some((object) => object.kind === 'database')).toBe(true)
      for (const object of objects) {
        if (object.parentId) {
          expect(ids.has(object.parentId)).toBe(true)
        }
      }
    })

    it('puts the session in read-only mode without writing fixture data', async () => {
      const result = requireRows(
        await adapter!.execute(
          profile,
          {
            engine: 'mysql',
            kind: 'query',
            text: 'SELECT @@session.transaction_read_only AS read_only'
          },
          executeOptions('integration-read-only')
        )
      )

      const readOnlyIndex = result.columns.findIndex((column) => column.label === 'read_only')
      expect(readOnlyIndex).toBeGreaterThanOrEqual(0)
      expect([1, '1']).toContain(result.rows[0]?.[readOnlyIndex])
    })

    it('cancels only the requested query and leaves the adapter usable', async () => {
      const requestId = 'integration-cancel'
      const outcomePromise = adapter!
        .execute(
          profile,
          { engine: 'mysql', kind: 'query', text: 'SELECT SLEEP(10)' },
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
          { engine: 'mysql', kind: 'query', text: 'SELECT 1 AS value' },
          executeOptions('integration-after-cancel')
        )
      )
      expect(followUp.rows[0]?.[0]).toBe(1)
    })
  }
)
