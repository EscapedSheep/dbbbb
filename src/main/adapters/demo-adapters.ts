import type {
  ConnectionProfile,
  DatabaseCommand,
  DatabaseObjectNode,
  DatabaseResult,
  DocumentResult,
  RowResult
} from '../../shared/database'
import type { DatabaseAdapter } from './database-adapter'

const postgresObjects: DatabaseObjectNode[] = [
  { id: 'schema-app', name: 'app', kind: 'schema', detail: '3 objects' },
  { id: 'table-users', parentId: 'schema-app', name: 'users', kind: 'table', detail: '1.2k rows' },
  { id: 'table-orders', parentId: 'schema-app', name: 'orders', kind: 'table', detail: '8.4k rows' },
  { id: 'view-revenue', parentId: 'schema-app', name: 'monthly_revenue', kind: 'view' },
  { id: 'schema-audit', name: 'audit', kind: 'schema', detail: '1 object' },
  { id: 'table-events', parentId: 'schema-audit', name: 'events', kind: 'table', detail: '42k rows' }
]

const mongoObjects: DatabaseObjectNode[] = [
  { id: 'database-product', name: 'product', kind: 'database', detail: '3 collections' },
  { id: 'collection-customers', parentId: 'database-product', name: 'customers', kind: 'collection', detail: '1.2k docs' },
  { id: 'collection-events', parentId: 'database-product', name: 'events', kind: 'collection', detail: '18k docs' },
  { id: 'collection-sessions', parentId: 'database-product', name: 'sessions', kind: 'collection', detail: '3.6k docs' }
]

const postgresResult: Omit<RowResult, 'meta'> = {
  kind: 'rows',
  columns: [
    { key: 'id', label: 'id', dataType: 'uuid' },
    { key: 'email', label: 'email', dataType: 'text' },
    { key: 'plan', label: 'plan', dataType: 'text' },
    { key: 'status', label: 'status', dataType: 'text' },
    { key: 'created_at', label: 'created_at', dataType: 'timestamptz' }
  ],
  rows: [
    ['8f6a…39b1', 'maya@northstar.dev', 'team', 'active', '2026-08-31 09:42:18+08'],
    ['1bc4…7a20', 'noah@paperplane.io', 'pro', 'active', '2026-08-30 18:06:41+08'],
    ['96d1…0ee7', 'lin@terrace.run', 'free', 'invited', '2026-08-30 14:19:05+08'],
    ['70a8…416c', 'sora@lumen.studio', 'team', 'active', '2026-08-29 22:51:33+08'],
    ['45fb…a908', 'eli@subplot.tools', 'pro', 'paused', '2026-08-29 11:03:27+08']
  ]
}

const mongoResult: Omit<DocumentResult, 'meta'> = {
  kind: 'documents',
  documents: [
    {
      _id: { $oid: '68b3a111ac30231f0a91b112' },
      name: 'Maya Chen',
      status: 'active',
      plan: 'team',
      preferences: { theme: 'system', digest: true },
      tags: ['founder', 'beta'],
      lastSeenAt: { $date: '2026-08-31T01:42:18.000Z' }
    },
    {
      _id: { $oid: '68b3a08dac30231f0a91b10a' },
      name: 'Noah Park',
      status: 'active',
      plan: 'pro',
      preferences: { theme: 'dark', digest: false },
      tags: ['developer'],
      lastSeenAt: { $date: '2026-08-30T10:06:41.000Z' }
    },
    {
      _id: { $oid: '68b39fefac30231f0a91b0d4' },
      name: 'Lin Zhou',
      status: 'active',
      plan: 'free',
      preferences: { theme: 'light', digest: true },
      tags: ['invited', 'docs'],
      lastSeenAt: { $date: '2026-08-30T06:19:05.000Z' }
    }
  ]
}

export class DemoPostgresAdapter implements DatabaseAdapter {
  readonly engine = 'postgresql' as const

  async listObjects(): Promise<DatabaseObjectNode[]> {
    return structuredClone(postgresObjects)
  }

  async previewObject(
    _profile: ConnectionProfile,
    objectId: string
  ): Promise<DatabaseCommand> {
    const object = postgresObjects.find((candidate) => candidate.id === objectId)
    const parent = postgresObjects.find((candidate) => candidate.id === object?.parentId)
    if (!object || !parent || !['table', 'view'].includes(object.kind)) {
      throw new Error('This PostgreSQL object cannot be previewed.')
    }
    return {
      engine: 'postgresql',
      kind: 'query',
      text: `SELECT *\nFROM "${parent.name}"."${object.name}"\nLIMIT 100;`
    }
  }

  async execute(
    _profile: ConnectionProfile,
    command: DatabaseCommand
  ): Promise<DatabaseResult> {
    if (command.engine !== this.engine || command.kind !== 'query') {
      throw new Error('The selected PostgreSQL connection only accepts SQL queries.')
    }

    return {
      ...structuredClone(postgresResult),
      meta: { elapsedMs: 28, count: postgresResult.rows.length, truncated: false, source: 'demo' }
    }
  }

  async cancel(): Promise<void> {}

  async close(): Promise<void> {}
}

export class DemoMongoAdapter implements DatabaseAdapter {
  readonly engine = 'mongodb' as const

  async listObjects(): Promise<DatabaseObjectNode[]> {
    return structuredClone(mongoObjects)
  }

  async previewObject(
    _profile: ConnectionProfile,
    objectId: string
  ): Promise<DatabaseCommand> {
    const object = mongoObjects.find((candidate) => candidate.id === objectId)
    if (!object || object.kind !== 'collection') {
      throw new Error('This MongoDB object cannot be previewed.')
    }
    return { engine: 'mongodb', kind: 'find', collection: object.name, text: '{}' }
  }

  async execute(
    _profile: ConnectionProfile,
    command: DatabaseCommand
  ): Promise<DatabaseResult> {
    if (command.engine !== this.engine) {
      throw new Error('The selected MongoDB connection only accepts document queries.')
    }

    // Mirror the real MongoAdapter write-stage blocklist so demo mode cannot
    // silently accept pipelines the real connection would refuse.
    if (command.kind === 'aggregate' && /"\s*\$(out|merge)\s*"/.test(command.text)) {
      throw new Error('$out/$merge is disabled because it writes data.')
    }

    return {
      ...structuredClone(mongoResult),
      meta: { elapsedMs: 34, count: mongoResult.documents.length, truncated: false, source: 'demo' }
    }
  }

  async cancel(): Promise<void> {}

  async close(): Promise<void> {}
}
