// @vitest-environment node
import { Buffer } from 'node:buffer'
import { Readable } from 'node:stream'
import { Binary, Decimal128, Int32, Long, ObjectId } from 'mongodb'
import { describe, expect, it, vi } from 'vitest'
import type { ConnectionProfile, MongoConnectionInput } from '../../shared/database'
import { assertReadOnlyPipeline, documentToWire, mongoClientOptions, parseMongoInput } from './mongo-adapter'
import { MongoAdapter } from './mongo-adapter'

function adapterHarness(readOnly = false) {
  const input: MongoConnectionInput = {
    engine: 'mongodb',
    name: 'Unit test MongoDB',
    uri: 'mongodb://unused.invalid',
    database: 'dbbbb_test',
    environment: 'development',
    readOnly,
    tls: false
  }
  const profile: ConnectionProfile = {
    id: 'mongo-unit',
    name: input.name,
    engine: 'mongodb',
    endpoint: 'unused.invalid',
    database: input.database,
    environment: input.environment,
    readOnly,
    demo: false
  }
  const insertMany = vi.fn(async (
    documents: readonly Record<string, unknown>[],
    _options?: { ordered?: boolean; signal?: AbortSignal }
  ) => ({ insertedCount: documents.length }))
  const updateOne = vi.fn(async (
    _filter: Record<string, unknown>,
    _update: Record<string, unknown>,
    _options?: { upsert?: boolean; maxTimeMS?: number }
  ) => ({ matchedCount: 1, modifiedCount: 1 }))
  const deleteOne = vi.fn(async (
    _filter: Record<string, unknown>,
    _options?: { maxTimeMS?: number }
  ) => ({ deletedCount: 1 }))
  const database = {
    listCollections: vi.fn(() => ({
      toArray: vi.fn(async () => [{ name: 'people' }])
    })),
    collection: vi.fn(() => ({ insertMany, updateOne, deleteOne }))
  }
  const client = {
    db: vi.fn(() => database),
    close: vi.fn(async () => undefined)
  }
  const adapter = new MongoAdapter(input)
  Object.defineProperty(adapter, 'client', { value: client, configurable: true })
  return { adapter, profile, client, insertMany, updateOne, deleteOne }
}

async function introspectedCollectionId(
  adapter: MongoAdapter,
  profile: ConnectionProfile
): Promise<string> {
  const object = (await adapter.listObjects(profile)).find((candidate) => candidate.kind === 'collection')
  if (!object) throw new Error('Expected the unit-test collection to be introspected.')
  return object.id
}

describe('MongoDB adapter wire boundary', () => {
  it('parses canonical Extended JSON without eval', () => {
    const filter = parseMongoInput(
      'find',
      '{"_id":{"$oid":"507f1f77bcf86cd799439011"},"total":{"$numberDecimal":"12.30"}}'
    )
    expect(filter).toMatchObject({
      _id: expect.any(ObjectId),
      total: expect.any(Decimal128)
    })
  })

  it('requires an array for aggregation pipelines', () => {
    expect(() => parseMongoInput('aggregate', '{"$match":{}}')).toThrow(/JSON array/i)
    expect(parseMongoInput('aggregate', '[{"$match":{"active":true}}]')).toHaveLength(1)
  })

  it('blocks aggregation stages that can write data', () => {
    expect(() => assertReadOnlyPipeline([{ $out: 'archive' }])).toThrow(/writes data/i)
    expect(() => assertReadOnlyPipeline([{ $merge: { into: 'archive' } }])).toThrow(/writes data/i)
    expect(() => assertReadOnlyPipeline([{ $match: { active: true } }])).not.toThrow()
  })

  it('checks every key of an aggregation stage, not just the first one', () => {
    expect(() => assertReadOnlyPipeline([{ $match: {}, $out: 'archive' }])).toThrow(/writes data/i)
    expect(() => assertReadOnlyPipeline([{ $match: {}, $merge: { into: 'archive' } }])).toThrow(/writes data/i)
  })

  it('serializes BSON values to canonical EJSON wire tags', () => {
    const wire = documentToWire({
      _id: new ObjectId('507f1f77bcf86cd799439011'),
      amount: Decimal128.fromString('9007199254740993.10'),
      payload: new Binary(Buffer.from([1, 2, 3])),
      createdAt: new Date('2026-08-31T00:00:00.000Z'),
      nested: { values: [Long.fromString('9007199254740993')] }
    })

    expect(wire).toEqual({
      _id: { $oid: '507f1f77bcf86cd799439011' },
      amount: { $numberDecimal: '9007199254740993.10' },
      payload: { $binary: { base64: 'AQID', subType: '00' } },
      createdAt: { $date: { $numberLong: '1788134400000' } },
      nested: { values: [{ $numberLong: '9007199254740993' }] }
    })
    expect(structuredClone(wire)).toEqual(wire)
  })
})

describe('MongoDB client options', () => {
  const baseInput: MongoConnectionInput = {
    engine: 'mongodb',
    name: 'Options test MongoDB',
    uri: 'mongodb://mongo.example.test:27017/app',
    database: 'app',
    environment: 'development',
    readOnly: true,
    tls: false
  }

  it('maps TLS, credentials, and connection timeouts onto MongoClient options', () => {
    expect(mongoClientOptions({
      ...baseInput,
      tls: true,
      username: 'line_user',
      password: 'session-secret'
    })).toEqual({
      appName: 'dbbbb',
      connectTimeoutMS: 10_000,
      serverSelectionTimeoutMS: 10_000,
      tls: true,
      auth: { username: 'line_user', password: 'session-secret' }
    })
  })

  it('omits auth when no username is configured', () => {
    const options = mongoClientOptions(baseInput)
    expect(options.tls).toBe(false)
    expect(options).not.toHaveProperty('auth')
  })

  it('rejects SRV URIs without TLS instead of downgrading to plaintext', () => {
    const srvInput = { ...baseInput, uri: 'mongodb+srv://cluster.example.test/app' }
    expect(() => mongoClientOptions(srvInput)).toThrow(/require TLS/i)
    expect(() => new MongoAdapter(srvInput)).toThrow(/require TLS/i)
    expect(() => mongoClientOptions({ ...srvInput, tls: true })).not.toThrow()
    expect(() => mongoClientOptions(baseInput)).not.toThrow()
  })
})

describe('MongoDB execution safeguards', () => {
  function executeOptions(requestId: string, timeoutMs = 5_000) {
    return { requestId, timeoutMs, maxRows: 5, maxBytes: 1024 * 1024 }
  }

  it('rejects a query whose request id was cancelled before execution started', async () => {
    const { adapter, profile, client } = adapterHarness()

    await adapter.cancel('mongo-cancel-early')
    await expect(adapter.execute(
      profile,
      { engine: 'mongodb', kind: 'find', collection: 'people', text: '{}' },
      executeOptions('mongo-cancel-early')
    )).rejects.toThrow(/cancelled/i)
    expect(client.db).not.toHaveBeenCalled()
  })

  it('allows a request id to be reused after its cancellation was consumed', async () => {
    const { adapter, profile } = adapterHarness()
    await adapter.cancel('mongo-cancel-reuse')
    await expect(adapter.execute(
      profile,
      { engine: 'mongodb', kind: 'find', collection: 'people', text: '{}' },
      executeOptions('mongo-cancel-reuse')
    )).rejects.toThrow(/cancelled/i)
    await adapter.cancel('mongo-cancel-reuse')
    await expect(adapter.execute(
      profile,
      { engine: 'mongodb', kind: 'find', collection: 'people', text: '{}' },
      executeOptions('mongo-cancel-reuse')
    )).rejects.toThrow(/cancelled/i)
  })

  it('rejects a zero timeout instead of silently disabling the time limit', async () => {
    const { adapter, profile } = adapterHarness()
    await expect(adapter.execute(
      profile,
      { engine: 'mongodb', kind: 'find', collection: 'people', text: '{}' },
      executeOptions('mongo-zero-timeout', 0)
    )).rejects.toThrow(/execution options are invalid/i)
  })

  it('rejects profiles that do not belong to a MongoDB connection', async () => {
    const { adapter, profile } = adapterHarness()
    const postgresProfile = { ...profile, engine: 'postgresql' as const }
    await expect(adapter.listObjects(postgresProfile)).rejects.toThrow(/not a MongoDB connection/i)
    await expect(adapter.execute(
      postgresProfile,
      { engine: 'mongodb', kind: 'find', collection: 'people', text: '{}' },
      executeOptions('mongo-wrong-engine')
    )).rejects.toThrow(/not a MongoDB connection/i)
  })
})

describe('MongoDB single-document changes', () => {
  const objectIdWire = { $oid: '507f1f77bcf86cd799439011' } as const

  it('decodes canonical EJSON and applies one planned optimistic update', async () => {
    const { adapter, profile, updateOne } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)

    const result = await adapter.applyDataChange(profile, objectId, {
      action: 'update',
      original: {
        _id: objectIdWire,
        name: 'before',
        obsolete: true,
        unchanged: { $numberLong: '9007199254740993' }
      },
      current: {
        _id: objectIdWire,
        name: 'after',
        unchanged: { $numberLong: '9007199254740993' },
        added: 4
      }
    })

    expect(result).toEqual({ action: 'update', affected: 1 })
    expect(updateOne).toHaveBeenCalledTimes(1)
    const [filter, update, options] = updateOne.mock.calls[0]
    expect((filter._id as { $eq: unknown }).$eq).toBeInstanceOf(ObjectId)
    expect(((filter._id as { $eq: ObjectId }).$eq).toHexString()).toBe(objectIdWire.$oid)
    expect(filter).toMatchObject({
      name: { $eq: 'before' },
      obsolete: { $eq: true },
      added: { $exists: false }
    })
    expect(update).toMatchObject({
      $set: { name: 'after' },
      $unset: { obsolete: '' }
    })
    expect((update.$set as Record<string, unknown>).added).toBeInstanceOf(Int32)
    expect(((update.$set as Record<string, Int32>).added).value).toBe(4)
    expect(options).toEqual({ upsert: false, maxTimeMS: 30_000 })
  })

  it('deletes with _id and every original field as operator-safe concurrency conditions', async () => {
    const { adapter, profile, deleteOne } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)

    const result = await adapter.applyDataChange(profile, objectId, {
      action: 'delete',
      original: {
        _id: objectIdWire,
        name: 'before',
        nullable: null,
        criteria: { $ne: 'must remain data' }
      }
    })

    expect(result).toEqual({ action: 'delete', affected: 1 })
    const [filter, options] = deleteOne.mock.calls[0]
    expect(((filter._id as { $eq: ObjectId }).$eq).toHexString()).toBe(objectIdWire.$oid)
    expect(filter).toMatchObject({
      name: { $eq: 'before' },
      nullable: { $eq: null, $exists: true },
      criteria: { $eq: { $ne: 'must remain data' } }
    })
    expect(options).toEqual({ maxTimeMS: 30_000 })
  })

  it('rejects read-only connections and targets that were not introspected', async () => {
    const readonlyHarness = adapterHarness(true)
    await expect(readonlyHarness.adapter.applyDataChange(readonlyHarness.profile, 'unknown', {
      action: 'delete',
      original: { _id: objectIdWire }
    })).rejects.toThrow(/read-only/i)
    expect(readonlyHarness.deleteOne).not.toHaveBeenCalled()

    const writableHarness = adapterHarness()
    await expect(writableHarness.adapter.applyDataChange(writableHarness.profile, 'unknown', {
      action: 'delete',
      original: { _id: objectIdWire }
    })).rejects.toThrow(/Refresh objects/i)
    expect(writableHarness.deleteOne).not.toHaveBeenCalled()
  })

  it('reports optimistic concurrency conflicts for zero matched or deleted documents', async () => {
    const updateHarness = adapterHarness()
    const updateObjectId = await introspectedCollectionId(updateHarness.adapter, updateHarness.profile)
    updateHarness.updateOne.mockResolvedValueOnce({ matchedCount: 0, modifiedCount: 0 })
    await expect(updateHarness.adapter.applyDataChange(updateHarness.profile, updateObjectId, {
      action: 'update',
      original: { _id: objectIdWire, name: 'before' },
      current: { _id: objectIdWire, name: 'after' }
    })).rejects.toThrow(/changed or was deleted/i)

    const deleteHarness = adapterHarness()
    const deleteObjectId = await introspectedCollectionId(deleteHarness.adapter, deleteHarness.profile)
    deleteHarness.deleteOne.mockResolvedValueOnce({ deletedCount: 0 })
    await expect(deleteHarness.adapter.applyDataChange(deleteHarness.profile, deleteObjectId, {
      action: 'delete',
      original: { _id: objectIdWire, name: 'before' }
    })).rejects.toThrow(/changed or was deleted/i)
  })

  it('requires _id, rejects _id edits, and requires current data for updates', async () => {
    const { adapter, profile, updateOne, deleteOne } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)

    await expect(adapter.applyDataChange(profile, objectId, {
      action: 'update',
      original: { _id: objectIdWire, name: 'before' }
    })).rejects.toThrow(/requires the current document/i)
    await expect(adapter.applyDataChange(profile, objectId, {
      action: 'update',
      original: { _id: objectIdWire, name: 'before' },
      current: { _id: { $oid: '507f191e810c19729de860ea' }, name: 'after' }
    })).rejects.toThrow(/_id cannot be edited/i)
    await expect(adapter.applyDataChange(profile, objectId, {
      action: 'delete',
      original: { name: 'before' }
    })).rejects.toThrow(/requires _id/i)
    expect(updateOne).not.toHaveBeenCalled()
    expect(deleteOne).not.toHaveBeenCalled()
  })

  it('rejects dangerous nested keys before deserialization or database access', async () => {
    const { adapter, profile, updateOne } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)
    const secret = 'DO_NOT_EXPOSE_THIS_VALUE'
    const dangerous = JSON.parse(
      `{"_id":{"$oid":"${objectIdWire.$oid}"},"nested":{"__proto__":{"value":"${secret}"}}}`
    )

    const failure = adapter.applyDataChange(profile, objectId, {
      action: 'update',
      original: { _id: objectIdWire, nested: { safe: true } },
      current: dangerous
    })
    await expect(failure).rejects.toThrow(/unsafe object key/i)
    await expect(failure).rejects.toSatisfy((error: Error) => !error.message.includes(secret))
    expect(updateOne).not.toHaveBeenCalled()
  })

  it('redacts database errors instead of exposing document values', async () => {
    const { adapter, profile, updateOne } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)
    const secret = 'PRIVATE_MONGO_VALUE'
    updateOne.mockRejectedValueOnce(new Error(`write failed for ${secret}`))

    const failure = adapter.applyDataChange(profile, objectId, {
      action: 'update',
      original: { _id: objectIdWire, name: 'before' },
      current: { _id: objectIdWire, name: 'after' }
    })
    await expect(failure).rejects.toThrow(/could not apply/i)
    await expect(failure).rejects.toSatisfy((error: Error) => !error.message.includes(secret))
  })
})

describe('MongoDB JSON Lines import', () => {
  it('streams ordered batches into an introspected collection', async () => {
    const { adapter, profile, insertMany } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)
    const controller = new AbortController()
    const jsonl = Array.from({ length: 501 }, (_, index) => JSON.stringify({ id: index })).join('\n')

    const source = `${jsonl}\n`
    const onProgress = vi.fn()
    const summary = await adapter.importData(
      profile,
      objectId,
      Readable.from([source]),
      { format: 'jsonl', hasHeader: false, signal: controller.signal, onProgress }
    )

    expect(summary).toEqual({ processed: 501, inserted: 501, failed: 0 })
    expect(onProgress).toHaveBeenLastCalledWith({
      processed: 501,
      inserted: 501,
      failed: 0,
      bytes: Buffer.byteLength(source)
    })
    expect(insertMany).toHaveBeenCalledTimes(2)
    expect(insertMany.mock.calls.map(([documents]) => documents.length)).toEqual([500, 1])
    for (const [, options] of insertMany.mock.calls) {
      expect(options).toEqual({ ordered: true, signal: controller.signal })
    }
  })

  it('passes the abort signal into insertMany so a running batch is cancelled', async () => {
    const { adapter, profile, insertMany } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)
    const controller = new AbortController()
    let markBatchStarted: (() => void) | undefined
    const batchStarted = new Promise<void>((resolve) => {
      markBatchStarted = resolve
    })
    insertMany.mockImplementationOnce(async (_documents, options) => {
      markBatchStarted?.()
      return new Promise<{ insertedCount: number }>((_resolve, reject) => {
        options?.signal?.addEventListener(
          'abort',
          () => reject(options.signal?.reason),
          { once: true }
        )
      })
    })
    const jsonl = Array.from({ length: 501 }, (_, index) => JSON.stringify({ id: index })).join('\n')

    const running = adapter.importData(
      profile,
      objectId,
      Readable.from([`${jsonl}\n`]),
      { format: 'jsonl', hasHeader: false, signal: controller.signal }
    )
    await batchStarted
    controller.abort()

    await expect(running).rejects.toMatchObject({ name: 'AbortError' })
    expect(insertMany).toHaveBeenCalledTimes(1)
    expect(insertMany.mock.calls[0]?.[1]?.signal?.aborted).toBe(true)
  })

  it('reports how many documents were inserted when cancellation lands after a batch', async () => {
    const { adapter, profile, insertMany } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)
    const controller = new AbortController()
    insertMany.mockImplementationOnce(async (documents) => {
      controller.abort()
      return { insertedCount: documents.length }
    })
    const jsonl = Array.from({ length: 501 }, (_, index) => JSON.stringify({ id: index })).join('\n')

    const failure = adapter.importData(
      profile,
      objectId,
      Readable.from([`${jsonl}\n`]),
      { format: 'jsonl', hasHeader: false, signal: controller.signal }
    )

    await expect(failure).rejects.toMatchObject({ name: 'AbortError', insertedCount: 500 })
    expect(insertMany).toHaveBeenCalledTimes(1)
  })

  it('rejects read-only, unsupported-format, and non-introspected targets before writing', async () => {
    const readonlyHarness = adapterHarness(true)
    await expect(readonlyHarness.adapter.importData(
      readonlyHarness.profile,
      'unknown',
      Readable.from(['{}\n']),
      { format: 'jsonl', hasHeader: false }
    )).rejects.toThrow(/read-only/i)
    expect(readonlyHarness.insertMany).not.toHaveBeenCalled()

    const writableHarness = adapterHarness()
    await expect(writableHarness.adapter.importData(
      writableHarness.profile,
      'unknown',
      Readable.from(['{}\n']),
      { format: 'csv', hasHeader: true }
    )).rejects.toThrow(/JSON Lines/i)
    await expect(writableHarness.adapter.importData(
      writableHarness.profile,
      'unknown',
      Readable.from(['{}\n']),
      { format: 'jsonl', hasHeader: false }
    )).rejects.toThrow(/Refresh objects/i)
    expect(writableHarness.insertMany).not.toHaveBeenCalled()
  })

  it('rejects unsafe document keys without passing their contents to MongoDB', async () => {
    const { adapter, profile, insertMany } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)
    const secret = 'NEVER_INSERT_THIS_VALUE'
    const failure = adapter.importData(
      profile,
      objectId,
      Readable.from([`{"nested":{"__proto__":{"value":"${secret}"}}}\n`]),
      { format: 'jsonl', hasHeader: false }
    )

    await expect(failure).rejects.toThrow(/not transactional/i)
    await expect(failure).rejects.toSatisfy((error: Error) => !error.message.includes(secret))
    expect(insertMany).not.toHaveBeenCalled()
  })

  it('redacts a batch failure and warns that earlier ordered batches may remain', async () => {
    const { adapter, profile, insertMany } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)
    const secret = 'PRIVATE_DUPLICATE_KEY_VALUE'
    insertMany.mockRejectedValueOnce(Object.assign(new Error(`duplicate ${secret}`), { code: 11000 }))

    const failure = adapter.importData(
      profile,
      objectId,
      Readable.from(['{"id":1}\n']),
      { format: 'jsonl', hasHeader: false }
    )

    await expect(failure).rejects.toThrow(/unique index/i)
    await expect(failure).rejects.toThrow(/earlier batches may already have been inserted/i)
    await expect(failure).rejects.toSatisfy((error: Error) => !error.message.includes(secret))
  })

  it('carries the real inserted count when an ordered batch fails partway', async () => {
    const { adapter, profile, insertMany } = adapterHarness()
    const objectId = await introspectedCollectionId(adapter, profile)
    insertMany.mockRejectedValueOnce(Object.assign(new Error('duplicate key'), {
      code: 11000,
      result: { insertedCount: 2 }
    }))

    const failure = adapter.importData(
      profile,
      objectId,
      Readable.from(['{"id":1}\n{"id":2}\n{"id":3}\n']),
      { format: 'jsonl', hasHeader: false }
    )

    await expect(failure).rejects.toThrow(/unique index/i)
    await expect(failure).rejects.toMatchObject({ insertedCount: 2 })
  })
})
