import { randomUUID } from 'node:crypto'
import { Readable } from 'node:stream'
import { MongoClient } from 'mongodb'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import type {
  ConnectionProfile,
  DocumentResult,
  MongoConnectionInput
} from '../../shared/database'
import type { ExecuteOptions } from './database-adapter'
import { MongoAdapter, mongoClientOptions } from './mongo-adapter'

const connectionUrl = process.env.DBBBB_TEST_MONGO_URL?.trim()
const databaseOverride = process.env.DBBBB_TEST_MONGO_DATABASE?.trim()
const dedicatedRunner = process.env.DBBBB_MONGO_INTEGRATION_RUNNER === '1'
const enableLongQuery = process.env.DBBBB_TEST_MONGO_ENABLE_LONG_QUERY === '1'
const enableWrites = process.env.DBBBB_TEST_MONGO_ENABLE_WRITE === '1'
const describeWithMongo = dedicatedRunner && connectionUrl ? describe : describe.skip
const itWithLongQuery = enableLongQuery ? it : it.skip
const describeWithMongoWrites =
  dedicatedRunner && connectionUrl && enableWrites ? describe : describe.skip

function queryOption(rawUrl: string, optionNames: string[]): string | undefined {
  const queryStart = rawUrl.indexOf('?')
  if (queryStart === -1) return undefined

  const names = new Set(optionNames.map((name) => name.toLowerCase()))
  for (const [key, value] of new URLSearchParams(rawUrl.slice(queryStart + 1))) {
    if (names.has(key.toLowerCase())) return value
  }
  return undefined
}

function databaseFromUrl(rawUrl: string): string | undefined {
  const schemeEnd = rawUrl.indexOf('://')
  if (schemeEnd === -1) return undefined

  const authorityStart = schemeEnd + 3
  const pathStart = rawUrl.indexOf('/', authorityStart)
  const queryStart = rawUrl.indexOf('?', authorityStart)
  if (pathStart === -1 || (queryStart !== -1 && pathStart > queryStart)) return undefined

  const encoded = rawUrl.slice(pathStart + 1, queryStart === -1 ? undefined : queryStart)
  if (!encoded) return undefined

  try {
    return decodeURIComponent(encoded)
  } catch {
    throw new Error('The database name in DBBBB_TEST_MONGO_URL is not valid URL encoding.')
  }
}

function tlsFromUrl(rawUrl: string, srv: boolean): boolean {
  const value = queryOption(rawUrl, ['tls', 'ssl'])
  if (value === undefined) return srv
  if (value.toLowerCase() === 'true') return true
  if (value.toLowerCase() === 'false') return false
  throw new Error('DBBBB_TEST_MONGO_URL tls/ssl must be true or false.')
}

function connectionInputFromUrl(rawUrl: string): MongoConnectionInput {
  const scheme = rawUrl.startsWith('mongodb+srv://')
    ? 'mongodb+srv'
    : rawUrl.startsWith('mongodb://')
      ? 'mongodb'
      : undefined
  if (!scheme) {
    throw new Error('DBBBB_TEST_MONGO_URL must use the mongodb or mongodb+srv protocol.')
  }

  const database = databaseOverride || databaseFromUrl(rawUrl)
  if (!database) {
    throw new Error(
      'Set DBBBB_TEST_MONGO_DATABASE or include an explicit database in DBBBB_TEST_MONGO_URL.'
    )
  }

  return {
    engine: 'mongodb',
    name: 'MongoDB integration test',
    uri: rawUrl,
    database,
    environment: 'development',
    readOnly: true,
    tls: tlsFromUrl(rawUrl, scheme === 'mongodb+srv')
  }
}

function profileFromInput(input: MongoConnectionInput): ConnectionProfile {
  return {
    id: 'mongo-integration',
    name: input.name,
    engine: 'mongodb',
    endpoint: 'configured MongoDB integration endpoint',
    database: input.database,
    environment: input.environment,
    readOnly: input.readOnly,
    demo: false
  }
}

function fixtureClient(input: MongoConnectionInput): MongoClient {
  return new MongoClient(input.uri, mongoClientOptions(input))
}

function fixtureCollectionName(): string {
  return `dbbbb_it_${randomUUID().replaceAll('-', '_')}`
}

function executeOptions(requestId: string, timeoutMs = 5_000): ExecuteOptions {
  return {
    requestId,
    timeoutMs,
    maxRows: 5,
    maxBytes: 1024 * 1024
  }
}

function requireDocuments(result: Awaited<ReturnType<MongoAdapter['execute']>>): DocumentResult {
  expect(result.kind).toBe('documents')
  if (result.kind !== 'documents') {
    throw new Error('Expected a MongoDB document result.')
  }
  return result
}

describeWithMongo(
  'MongoAdapter integration (set DBBBB_TEST_MONGO_URL to enable)',
  () => {
    let adapter: MongoAdapter | undefined
    let fixture: MongoClient | undefined
    let profile: ConnectionProfile
    let collectionName = ''
    const fixtureDocuments = [
      { key: 'alpha', n: 1 },
      { key: 'beta', n: 2 },
      { key: 'gamma', n: 3 }
    ]

    beforeAll(async () => {
      const input = connectionInputFromUrl(connectionUrl!)
      profile = profileFromInput(input)
      collectionName = fixtureCollectionName()
      fixture = fixtureClient(input)
      await fixture.db(input.database).collection(collectionName).insertMany(fixtureDocuments)
      adapter = new MongoAdapter(input)
      await adapter.connect()
    })

    afterAll(async () => {
      if (fixture && collectionName) {
        await fixture
          .db(profile.database)
          .collection(collectionName)
          .drop()
          .catch(() => undefined)
      }
      await adapter?.close()
      await fixture?.close(true)
    })

    it('connects to the explicitly configured database', async () => {
      await expect(adapter!.connect()).resolves.toBeUndefined()
    })

    it('lists collections with a consistent database parent', async () => {
      const objects = await adapter!.listObjects(profile)
      const databaseNodes = objects.filter((object) => object.kind === 'database')

      expect(databaseNodes).toHaveLength(1)
      expect(databaseNodes[0]?.name).toBe(profile.database)
      for (const collection of objects.filter((object) => object.kind === 'collection')) {
        expect(collection.parentId).toBe(databaseNodes[0]?.id)
      }
      expect(
        objects.some((object) => object.kind === 'collection' && object.name === collectionName)
      ).toBe(true)
    })

    it('executes a bounded find with canonical Extended JSON', async () => {
      const result = requireDocuments(
        await adapter!.execute(
          profile,
          {
            engine: 'mongodb',
            kind: 'find',
            collection: collectionName,
            text: '{"__dbbbb_ejson_probe__":{"$ne":{"$numberLong":"9223372036854775807"}}}'
          },
          executeOptions('mongo-integration-find')
        )
      )

      expect(result.meta.source).toBe('database')
      expect(result.documents.map((document) => document.key).sort()).toEqual([
        'alpha',
        'beta',
        'gamma'
      ])
      expect(structuredClone(result.documents)).toEqual(result.documents)
    })

    itWithLongQuery(
      'cancels an opt-in read-only $function query and remains usable',
      async () => {
        const requestId = 'mongo-integration-cancel'
        const pipeline = JSON.stringify([
          { $limit: 1 },
          {
            $project: {
              _id: 1,
              __dbbbbCancelProbe: {
                $function: {
                  body: 'function () { const until = Date.now() + 10000; while (Date.now() < until) {} return true; }',
                  args: [],
                  lang: 'js'
                }
              }
            }
          }
        ])
        const outcomePromise = adapter!
          .execute(
            profile,
            { engine: 'mongodb', kind: 'aggregate', collection: collectionName, text: pipeline },
            executeOptions(requestId, 7_000)
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

        const followUp = requireDocuments(
          await adapter!.execute(
            profile,
            {
              engine: 'mongodb',
              kind: 'find',
              collection: collectionName,
              text: '{"_id":{"$exists":true}}'
            },
            { ...executeOptions('mongo-integration-after-cancel'), maxRows: 1 }
          )
        )
        expect(followUp.documents.length).toBeLessThanOrEqual(1)
      }
    )
  }
)

describeWithMongoWrites(
  'MongoAdapter isolated writes (also set DBBBB_TEST_MONGO_ENABLE_WRITE=1)',
  () => {
    let adapter: MongoAdapter | undefined
    let fixture: MongoClient | undefined
    let profile: ConnectionProfile
    let collectionName = ''
    let collectionObjectId = ''

    beforeAll(async () => {
      const input: MongoConnectionInput = {
        ...connectionInputFromUrl(connectionUrl!),
        name: 'MongoDB write integration test',
        readOnly: false
      }
      profile = profileFromInput(input)
      collectionName = fixtureCollectionName()
      fixture = fixtureClient(input)
      await fixture.db(input.database).createCollection(collectionName)

      adapter = new MongoAdapter(input)
      await adapter.connect()
      const collection = (await adapter.listObjects(profile)).find(
        (object) => object.kind === 'collection' && object.name === collectionName
      )
      if (!collection) {
        throw new Error('The isolated MongoDB write fixture was not introspected.')
      }
      collectionObjectId = collection.id
    })

    afterAll(async () => {
      if (fixture && collectionName) {
        await fixture
          .db(profile.database)
          .collection(collectionName)
          .drop()
          .catch(() => undefined)
      }
      await adapter?.close()
      await fixture?.close(true)
    })

    it('imports JSONL, updates optimistically, rejects stale data, and deletes', async () => {
      const summary = await adapter!.importData(
        profile,
        collectionObjectId,
        Readable.from(['{"key":"delta","n":4}\n{"key":"epsilon","n":5}\n']),
        { format: 'jsonl', hasHeader: false }
      )
      expect(summary).toEqual({ processed: 2, inserted: 2, failed: 0 })

      const preview = await adapter!.previewObject(profile, collectionObjectId)
      expect(preview).toEqual({
        engine: 'mongodb',
        kind: 'find',
        collection: collectionName,
        text: '{}'
      })

      const loaded = requireDocuments(
        await adapter!.execute(
          profile,
          {
            engine: 'mongodb',
            kind: 'find',
            collection: collectionName,
            text: '{"key":"delta"}'
          },
          executeOptions('mongo-write-load')
        )
      )
      expect(loaded.documents).toHaveLength(1)
      const original = loaded.documents[0]
      const current = { ...original, n: { $numberInt: '6' }, note: 'edited' }

      await expect(adapter!.applyDataChange(profile, collectionObjectId, {
        action: 'update',
        original,
        current
      })).resolves.toEqual({ action: 'update', affected: 1 })

      await expect(adapter!.applyDataChange(profile, collectionObjectId, {
        action: 'update',
        original,
        current
      })).rejects.toThrow(/changed or was deleted/i)

      await expect(adapter!.applyDataChange(profile, collectionObjectId, {
        action: 'delete',
        original: current
      })).resolves.toEqual({ action: 'delete', affected: 1 })

      const finalDocuments = requireDocuments(
        await adapter!.execute(
          profile,
          {
            engine: 'mongodb',
            kind: 'find',
            collection: collectionName,
            text: '{}'
          },
          executeOptions('mongo-write-final')
        )
      )
      expect(finalDocuments.documents).toHaveLength(1)
      expect(finalDocuments.documents[0]).toMatchObject({
        key: 'epsilon',
        n: { $numberInt: '5' }
      })
    })
  }
)
