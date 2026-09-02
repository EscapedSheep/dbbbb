import { describe, expect, it } from 'vitest'
import type { ConnectionProfile } from '../../shared/database'
import { DemoMongoAdapter, DemoPostgresAdapter } from './demo-adapters'

const postgresProfile: ConnectionProfile = {
  id: 'pg-test',
  name: 'Postgres test',
  engine: 'postgresql',
  endpoint: 'localhost:5432',
  database: 'test',
  environment: 'development',
  readOnly: true,
  demo: true
}

const mongoProfile: ConnectionProfile = {
  ...postgresProfile,
  id: 'mongo-test',
  name: 'Mongo test',
  engine: 'mongodb',
  endpoint: 'localhost:27017'
}

describe('demo database adapters', () => {
  it('keeps PostgreSQL results relational', async () => {
    const adapter = new DemoPostgresAdapter()
    const result = await adapter.execute(postgresProfile, {
      engine: 'postgresql',
      kind: 'query',
      text: 'select 1'
    })

    expect(result.kind).toBe('rows')
    if (result.kind === 'rows') {
      expect(result.columns.map((column) => column.key)).toContain('email')
      expect(result.rows).toHaveLength(5)
    }
  })

  it('keeps MongoDB results document-shaped', async () => {
    const adapter = new DemoMongoAdapter()
    const result = await adapter.execute(mongoProfile, {
      engine: 'mongodb',
      kind: 'find',
      collection: 'customers',
      text: '{}'
    })

    expect(result.kind).toBe('documents')
    if (result.kind === 'documents') {
      expect(result.documents[0]).toHaveProperty('_id.$oid')
      expect(result.documents[0]).toHaveProperty('preferences.theme')
    }
  })

  it('rejects commands for the wrong engine', async () => {
    const adapter = new DemoPostgresAdapter()
    await expect(
      adapter.execute(postgresProfile, {
        engine: 'mongodb',
        kind: 'find',
        collection: 'customers',
        text: '{}'
      })
    ).rejects.toThrow(/only accepts SQL/i)
  })

  it('rejects MongoDB commands for the wrong engine', async () => {
    const adapter = new DemoMongoAdapter()
    await expect(
      adapter.execute(mongoProfile, {
        engine: 'postgresql',
        kind: 'query',
        text: 'select 1'
      })
    ).rejects.toThrow(/only accepts document queries/i)
  })

  it('lists PostgreSQL objects as a consistent schema tree', async () => {
    const adapter = new DemoPostgresAdapter()
    const objects = await adapter.listObjects()
    const byId = new Map(objects.map((object) => [object.id, object]))

    expect(byId.size).toBe(objects.length)
    for (const object of objects) {
      expect(['schema', 'table', 'view']).toContain(object.kind)
      if (object.parentId) expect(byId.has(object.parentId)).toBe(true)
    }
    expect(byId.get('table-users')).toMatchObject({ parentId: 'schema-app', kind: 'table' })
  })

  it('lists MongoDB objects as one database with collections', async () => {
    const adapter = new DemoMongoAdapter()
    const objects = await adapter.listObjects()
    const byId = new Map(objects.map((object) => [object.id, object]))

    expect(byId.size).toBe(objects.length)
    const database = objects.find((object) => object.kind === 'database')
    expect(database).toBeDefined()
    for (const object of objects) {
      expect(['database', 'collection']).toContain(object.kind)
      if (object.kind === 'collection') expect(object.parentId).toBe(database!.id)
    }
  })

  it('returns defensive copies from listObjects', async () => {
    const adapter = new DemoPostgresAdapter()
    const first = await adapter.listObjects()
    first.pop()
    first[0]!.name = 'mutated'

    const second = await adapter.listObjects()
    expect(second.length).toBeGreaterThan(first.length)
    expect(second[0]?.name).not.toBe('mutated')
  })

  it('previews a PostgreSQL table or view as a schema-qualified limited query', async () => {
    const adapter = new DemoPostgresAdapter()

    await expect(adapter.previewObject(postgresProfile, 'table-users')).resolves.toEqual({
      engine: 'postgresql',
      kind: 'query',
      text: 'SELECT *\nFROM "app"."users"\nLIMIT 100;'
    })
    await expect(adapter.previewObject(postgresProfile, 'view-revenue')).resolves.toEqual({
      engine: 'postgresql',
      kind: 'query',
      text: 'SELECT *\nFROM "app"."monthly_revenue"\nLIMIT 100;'
    })
  })

  it.each(['schema-app', 'missing-object'])(
    'rejects previewing the PostgreSQL object %j',
    async (objectId) => {
      const adapter = new DemoPostgresAdapter()
      await expect(adapter.previewObject(postgresProfile, objectId)).rejects.toThrow(
        /cannot be previewed/i
      )
    }
  )

  it('previews a MongoDB collection as an empty find', async () => {
    const adapter = new DemoMongoAdapter()

    await expect(adapter.previewObject(mongoProfile, 'collection-customers')).resolves.toEqual({
      engine: 'mongodb',
      kind: 'find',
      collection: 'customers',
      text: '{}'
    })
  })

  it.each(['database-product', 'missing-collection'])(
    'rejects previewing the MongoDB object %j',
    async (objectId) => {
      const adapter = new DemoMongoAdapter()
      await expect(adapter.previewObject(mongoProfile, objectId)).rejects.toThrow(
        /cannot be previewed/i
      )
    }
  )

  it('rejects an aggregation pipeline containing write stages', async () => {
    const adapter = new DemoMongoAdapter()

    await expect(
      adapter.execute(mongoProfile, {
        engine: 'mongodb',
        kind: 'aggregate',
        collection: 'customers',
        text: '[{"$out":"archive"}]'
      })
    ).rejects.toThrow(/writes data/i)

    await expect(
      adapter.execute(mongoProfile, {
        engine: 'mongodb',
        kind: 'aggregate',
        collection: 'customers',
        text: '[{"$match":{}},{"$merge":{"into":"archive"}}]'
      })
    ).rejects.toThrow(/writes data/i)
  })

  it('returns demo documents for a read-only aggregation pipeline', async () => {
    const adapter = new DemoMongoAdapter()
    const result = await adapter.execute(mongoProfile, {
      engine: 'mongodb',
      kind: 'aggregate',
      collection: 'customers',
      text: '[{"$match":{"status":"active"}}]'
    })

    expect(result.kind).toBe('documents')
    if (result.kind === 'documents') {
      expect(result.documents[0]).toHaveProperty('_id.$oid')
    }
    expect(result.meta).toMatchObject({ source: 'demo', truncated: false })
  })

  it('cancels and closes both demo adapters cleanly', async () => {
    for (const adapter of [new DemoPostgresAdapter(), new DemoMongoAdapter()]) {
      await expect(adapter.cancel()).resolves.toBeUndefined()
      await expect(adapter.close()).resolves.toBeUndefined()
    }
  })
})
