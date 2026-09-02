// @vitest-environment node
import { describe, expect, it } from 'vitest'
import {
  planMongoUpdate,
  planPostgresDelete,
  planPostgresUpdate,
  quotePostgresIdentifier
} from './change-planner'

describe('PostgreSQL change planner', () => {
  it('plans a composite-key update with parameterized values and optimistic predicates', () => {
    const plan = planPostgresUpdate({
      schema: 'sales.ops',
      table: 'order"line',
      primaryKey: { tenant_id: 7, id: 'order-1' },
      original: { status: 'draft', note: null, unchanged: 4 },
      current: { status: 'paid', note: 'ready', unchanged: 4 }
    })

    expect(plan).toEqual({
      text: [
        'UPDATE "sales.ops"."order""line"',
        'SET "status" = $1,',
        '    "note" = $2',
        'WHERE "tenant_id" IS NOT DISTINCT FROM $3',
        '  AND "id" IS NOT DISTINCT FROM $4',
        '  AND "status" IS NOT DISTINCT FROM $5',
        '  AND "note" IS NOT DISTINCT FROM $6',
        '  AND "unchanged" IS NOT DISTINCT FROM $7',
        'RETURNING *;'
      ].join('\n'),
      values: ['paid', 'ready', 7, 'order-1', 'draft', null, 4]
    })
  })

  it('plans a delete with both identity and original-value conditions', () => {
    expect(planPostgresDelete({
      schema: 'public',
      table: 'users',
      primaryKey: { id: 42 },
      original: { id: 42, email: 'before@example.test', active: true }
    })).toEqual({
      text: [
        'DELETE FROM "public"."users"',
        'WHERE "id" IS NOT DISTINCT FROM $1',
        '  AND "email" IS NOT DISTINCT FROM $2',
        '  AND "active" IS NOT DISTINCT FROM $3',
        'RETURNING *;'
      ].join('\n'),
      values: [42, 'before@example.test', true]
    })
  })

  it('quotes identifiers independently and never interpolates values', () => {
    const hostileValue = "x'); DROP TABLE audit; --"
    const plan = planPostgresUpdate({
      schema: 'public',
      table: 'users"; DROP TABLE audit; --',
      primaryKey: { id: 1 },
      original: { display_name: 'before' },
      current: { display_name: hostileValue }
    })

    expect(quotePostgresIdentifier('a.b"c')).toBe('"a.b""c"')
    expect(plan.text).toContain('UPDATE "public"."users""; DROP TABLE audit; --"')
    expect(plan.text).not.toContain(hostileValue)
    expect(plan.values[0]).toBe(hostileValue)
  })

  it('rejects missing identity, empty/no-op patches, and primary-key edits', () => {
    expect(() => planPostgresUpdate({
      schema: 'public',
      table: 'users',
      primaryKey: {},
      original: { name: 'before' },
      current: { name: 'after' }
    })).toThrow(/primary-key/i)

    expect(() => planPostgresUpdate({
      schema: 'public',
      table: 'users',
      primaryKey: { id: 1 },
      original: {},
      current: {}
    })).toThrow(/original values/i)

    expect(() => planPostgresUpdate({
      schema: 'public',
      table: 'users',
      primaryKey: { id: 1 },
      original: { name: 'same' },
      current: { name: 'same' }
    })).toThrow(/changed value/i)

    expect(() => planPostgresUpdate({
      schema: 'public',
      table: 'users',
      primaryKey: { id: 1 },
      original: { id: 1, name: 'before' },
      current: { id: 2, name: 'before' }
    })).toThrow(/cannot be edited/i)
  })

  it('rejects ambiguous patches and dangerous record keys', () => {
    expect(() => planPostgresUpdate({
      schema: 'public',
      table: 'users',
      primaryKey: { id: 1 },
      original: { first_name: 'before' },
      current: { display_name: 'after' }
    })).toThrow(/same columns/i)

    const dangerous = JSON.parse('{"__proto__":"value"}') as Record<string, unknown>
    expect(() => planPostgresUpdate({
      schema: 'public',
      table: 'users',
      primaryKey: { id: 1 },
      original: dangerous,
      current: dangerous
    })).toThrow(/dangerous key/i)

    const accessor: Record<string, unknown> = {}
    Object.defineProperty(accessor, 'name', { enumerable: true, get: () => 'secret' })
    expect(() => planPostgresDelete({
      schema: 'public',
      table: 'users',
      primaryKey: { id: 1 },
      original: accessor
    })).toThrow(/data properties/i)
  })
})

describe('MongoDB change planner', () => {
  it('builds $set/$unset and whole-document optimistic concurrency conditions', () => {
    const plan = planMongoUpdate({
      original: {
        _id: 'document-1',
        name: 'before',
        count: 3,
        obsolete: true
      },
      current: {
        _id: 'document-1',
        name: 'after',
        count: 3,
        added: { safe: true }
      }
    })

    expect(plan).toEqual({
      filter: {
        _id: { $eq: 'document-1' },
        name: { $eq: 'before' },
        count: { $eq: 3 },
        obsolete: { $eq: true },
        added: { $exists: false }
      },
      update: {
        $set: {
          name: 'after',
          added: { safe: true }
        },
        $unset: { obsolete: '' }
      }
    })
  })

  it('wraps original objects in $eq so document content cannot become an operator', () => {
    expect(planMongoUpdate({
      original: { _id: 'document-1', criteria: { $ne: 0 } },
      current: { _id: 'document-1', criteria: { safe: true } }
    }).filter).toEqual({
      _id: { $eq: 'document-1' },
      criteria: { $eq: { $ne: 0 } }
    })
  })

  it('distinguishes an original null value from an absent field', () => {
    expect(planMongoUpdate({
      original: { _id: 'document-1', nullable: null },
      current: { _id: 'document-1', nullable: 'now set' }
    }).filter).toEqual({
      _id: { $eq: 'document-1' },
      nullable: { $eq: null, $exists: true }
    })
  })

  it('requires an unchanged _id and at least one effective change', () => {
    expect(() => planMongoUpdate({
      original: { name: 'before' },
      current: { name: 'after' }
    })).toThrow(/requires _id/i)

    expect(() => planMongoUpdate({
      original: { _id: 1, name: 'before' },
      current: { _id: 2, name: 'after' }
    })).toThrow(/cannot be edited/i)

    expect(() => planMongoUpdate({
      original: { _id: 1, name: 'same' },
      current: { _id: 1, name: 'same' }
    })).toThrow(/changed or removed/i)
  })

  it('rejects update-path injection', () => {
    expect(() => planMongoUpdate({
      original: { _id: 1, name: 'before' },
      current: { _id: 1, name: 'before', 'profile.name': 'injected' }
    })).toThrow(/unsafe MongoDB update path/i)

    expect(() => planMongoUpdate({
      original: { _id: 1, name: 'before' },
      current: { _id: 1, name: 'before', $where: 'injected' }
    })).toThrow(/unsafe MongoDB update path/i)
  })
})
