// @vitest-environment node
import { describe, expect, it, vi } from 'vitest'
import type {
  ApplyDataChangeResult,
  ConnectionInput,
  ConnectionProfile,
  DataRecord,
  MongoConnectionInput,
  MySqlConnectionInput,
  PostgresConnectionInput,
  SqliteConnectionInput
} from '../shared/database'
import type { DatabaseAdapter } from './adapters/database-adapter'
import { DatabaseService } from './database-service'
import type {
  ConnectionVaultStore,
  LiveAdapterFactory,
  LiveDatabaseAdapter
} from './database-service'
import type { ByteSource } from './transfers/delimited'

const adapterMocks = vi.hoisted(() => ({
  mysqlConstructor: vi.fn(),
  sqliteConstructor: vi.fn(),
  connect: vi.fn(async () => undefined),
  close: vi.fn(async () => undefined)
}))

vi.mock('./adapters/mysql-adapter', () => ({
  MySqlAdapter: class {
    readonly engine = 'mysql'
    connect = adapterMocks.connect
    close = adapterMocks.close
    constructor(input: unknown) {
      adapterMocks.mysqlConstructor(input)
    }
  }
}))

vi.mock('./adapters/sqlite-adapter', () => ({
  SqliteAdapter: class {
    readonly engine = 'sqlite'
    connect = adapterMocks.connect
    close = adapterMocks.close
    constructor(input: unknown) {
      adapterMocks.sqliteConstructor(input)
    }
  }
}))

interface InjectedSession {
  profile: ConnectionProfile
  adapter: DatabaseAdapter
}

function editableProfile(overrides: Partial<ConnectionProfile> = {}): ConnectionProfile {
  return {
    id: 'editable-postgres',
    name: 'Editable PostgreSQL',
    engine: 'postgresql',
    endpoint: 'localhost:5432',
    database: 'app',
    environment: 'development',
    readOnly: false,
    demo: false,
    ...overrides
  }
}

function adapterWithApply(
  applyDataChange = vi.fn(async (): Promise<ApplyDataChangeResult> => ({
    action: 'update',
    affected: 1
  }))
): DatabaseAdapter {
  return {
    engine: 'postgresql',
    listObjects: vi.fn(async () => []),
    previewObject: vi.fn(async () => ({
      engine: 'postgresql' as const,
      kind: 'query' as const,
      text: 'SELECT 1'
    })),
    execute: vi.fn(async () => ({
      kind: 'rows' as const,
      columns: [],
      rows: [],
      meta: { elapsedMs: 0, count: 0, truncated: false, source: 'database' as const }
    })),
    cancel: vi.fn(async () => undefined),
    applyDataChange,
    close: vi.fn(async () => undefined)
  }
}

function injectSession(
  service: DatabaseService,
  profile: ConnectionProfile,
  adapter: DatabaseAdapter
): void {
  const internals = service as unknown as { sessions: Map<string, InjectedSession> }
  internals.sessions.set(profile.id, { profile, adapter })
}

function adapterWithImport(
  importData = vi.fn(async () => ({ processed: 2, inserted: 2, failed: 0 }))
): DatabaseAdapter {
  return { ...adapterWithApply(), importData }
}

function emptySource(): ByteSource {
  return (async function* () {})()
}

const savedPostgresInput: PostgresConnectionInput = {
  engine: 'postgresql',
  name: 'Saved PostgreSQL',
  database: 'app',
  environment: 'development',
  readOnly: false,
  host: 'db.internal',
  port: 5432,
  username: 'app_user',
  password: 'SAVED_SECRET',
  sslMode: 'require'
}

const savedMysqlInput: MySqlConnectionInput = {
  engine: 'mysql',
  name: 'Saved MySQL',
  database: 'shop',
  environment: 'staging',
  readOnly: true,
  host: 'mysql.internal',
  port: 3306,
  username: 'shop_user',
  password: 'MYSQL_SAVED_SECRET',
  sslMode: 'require'
}

const savedSqliteInput: SqliteConnectionInput = {
  engine: 'sqlite',
  name: 'Saved SQLite',
  database: 'main',
  environment: 'development',
  readOnly: false,
  filePath: '/Users/tester/data/local.db'
}

function vaultStore(overrides: Partial<ConnectionVaultStore> = {}): ConnectionVaultStore {
  return {
    load: vi.fn(async () => ({ entries: [], warnings: [] })),
    save: vi.fn(async () => undefined),
    remove: vi.fn(async () => true),
    ...overrides
  }
}

function liveAdapter(
  connect = vi.fn(async () => undefined),
  close = vi.fn(async () => undefined)
): LiveDatabaseAdapter {
  return {
    ...adapterWithApply(),
    connect,
    close
  }
}

function adapterFactory(
  make: (input: ConnectionInput, index: number) => LiveDatabaseAdapter = () => liveAdapter()
): { factory: LiveAdapterFactory; adapters: LiveDatabaseAdapter[] } {
  const adapters: LiveDatabaseAdapter[] = []
  const factory: LiveAdapterFactory = vi.fn((input) => {
    const adapter = make(input, adapters.length)
    adapters.push(adapter)
    return adapter
  })
  return { factory, adapters }
}

describe('DatabaseService session lifecycle', () => {
  it('routes demo object previews and execution through one owned session', async () => {
    const service = new DatabaseService()
    const profile = service.listConnections().find((candidate) => candidate.engine === 'postgresql')
    expect(profile).toBeDefined()

    const objects = await service.listObjects(profile!.id)
    const table = objects.find((object) => object.kind === 'table')
    expect(table).toBeDefined()

    const preview = await service.previewObject(profile!.id, table!.id)
    expect(preview).toMatchObject({ engine: 'postgresql', kind: 'query' })
    expect(preview.text).toContain('LIMIT 100')

    const result = await service.execute(profile!.id, 'service-test', preview)
    expect(result.kind).toBe('rows')
    expect(result.meta.source).toBe('demo')

    await service.disconnect(profile!.id)
    await expect(service.listObjects(profile!.id)).rejects.toThrow(/disconnected/i)
    await service.closeAll()
  })

  it('removes every session during shutdown', async () => {
    const service = new DatabaseService()
    expect(service.listConnections().length).toBeGreaterThan(0)
    await service.closeAll()
    expect(service.listConnections()).toEqual([])
  })

  it('closes an in-flight connection that finishes after shutdown starts', async () => {
    let markStarted: (() => void) | undefined
    const started = new Promise<void>((resolve) => {
      markStarted = resolve
    })
    let releaseConnection: (() => void) | undefined
    const release = new Promise<void>((resolve) => {
      releaseConnection = resolve
    })
    const close = vi.fn(async () => undefined)
    const save = vi.fn(async () => undefined)
    const { factory } = adapterFactory(() => liveAdapter(
      vi.fn(async () => {
        markStarted?.()
        await release
      }),
      close
    ))
    const service = new DatabaseService(vaultStore({ save }), factory)

    const connecting = service.connect({ ...savedPostgresInput, remember: true })
    await started
    const closing = service.closeAll()
    releaseConnection?.()

    await expect(connecting).rejects.toThrow(/shutting down/i)
    await closing
    expect(close).toHaveBeenCalledOnce()
    expect(save).not.toHaveBeenCalled()
    expect(service.listConnections()).toEqual([])
    expect(() => service.connect(savedPostgresInput)).toThrow(/shutting down/i)
    expect(() => service.createDemoConnection({
      name: 'Late demo',
      engine: 'postgresql',
      endpoint: 'localhost:5432',
      database: 'late',
      environment: 'development',
      readOnly: true
    })).toThrow(/shutting down/i)
  })

  it('keeps a session registered when disconnect close fails so it can be retried', async () => {
    const close = vi.fn()
      .mockRejectedValueOnce(new Error('driver close failed with SECRET'))
      .mockResolvedValueOnce(undefined)
    const { factory } = adapterFactory(() => liveAdapter(vi.fn(async () => undefined), close))
    const service = new DatabaseService(undefined, factory)
    const profile = await service.connect(savedPostgresInput)

    await expect(service.disconnect(profile.id)).rejects.toThrow(/retry disconnecting/i)
    expect(service.listConnections()).toContainEqual(profile)

    await service.disconnect(profile.id)
    expect(close).toHaveBeenCalledTimes(2)
    expect(service.listConnections()).not.toContainEqual(expect.objectContaining({ id: profile.id }))
  })

  it('rejects new connections beyond the session limit without creating an adapter', async () => {
    const { factory } = adapterFactory()
    const service = new DatabaseService(undefined, factory)
    for (let index = service.listConnections().length; index < 50; index += 1) {
      injectSession(service, editableProfile({ id: `filler-${index}` }), adapterWithApply())
    }

    await expect(service.connect(savedPostgresInput)).rejects.toThrow(/too many open connections/i)
    expect(factory).not.toHaveBeenCalled()

    await service.disconnect('filler-2')
    const profile = await service.connect(savedPostgresInput)
    expect(factory).toHaveBeenCalledOnce()
    expect(service.listConnections()).toContainEqual(profile)
    expect(service.listConnections()).toHaveLength(50)
    await service.closeAll()
  })
})

describe('DatabaseService MySQL and SQLite groundwork', () => {
  it('routes live MySQL and SQLite connections to their real adapters', async () => {
    const service = new DatabaseService()

    const mysql = await service.connect(savedMysqlInput)
    const sqlite = await service.connect(savedSqliteInput)

    expect(adapterMocks.mysqlConstructor).toHaveBeenCalledOnce()
    expect(adapterMocks.mysqlConstructor).toHaveBeenCalledWith(savedMysqlInput)
    expect(adapterMocks.sqliteConstructor).toHaveBeenCalledOnce()
    expect(adapterMocks.sqliteConstructor).toHaveBeenCalledWith(savedSqliteInput)
    expect(adapterMocks.connect).toHaveBeenCalledTimes(2)
    expect(mysql).toMatchObject({ engine: 'mysql', endpoint: 'mysql.internal:3306', demo: false })
    expect(sqlite).toMatchObject({
      engine: 'sqlite',
      endpoint: '/Users/tester/data/local.db',
      demo: false
    })

    await service.closeAll()
    expect(adapterMocks.close).toHaveBeenCalledTimes(2)
  })

  it('wraps live adapter construction failures in a generic, credential-safe error', async () => {
    adapterMocks.mysqlConstructor.mockImplementationOnce(() => {
      throw new Error(`driver rejected the options for ${savedMysqlInput.password}`)
    })
    const service = new DatabaseService()

    const failure = service.connect(savedMysqlInput)
    await expect(failure).rejects.toThrow(/adapter could not be created/i)
    await expect(failure).rejects.toSatisfy((error: Error) =>
      !error.message.includes(savedMysqlInput.password)
    )
    expect(service.listConnections()).toEqual(
      expect.not.arrayContaining([expect.objectContaining({ engine: 'mysql' })])
    )
    await service.closeAll()
  })

  it('derives host:port and file-path endpoints for MySQL and SQLite sessions', async () => {
    const { factory } = adapterFactory()
    const service = new DatabaseService(undefined, factory)

    const mysql = await service.connect(savedMysqlInput)
    const sqlite = await service.connect(savedSqliteInput)

    expect(mysql).toMatchObject({ engine: 'mysql', endpoint: 'mysql.internal:3306', demo: false })
    expect(sqlite).toMatchObject({
      engine: 'sqlite',
      endpoint: '/Users/tester/data/local.db',
      demo: false
    })
    expect(JSON.stringify([mysql, sqlite])).not.toContain(savedMysqlInput.password)
    expect(mysql).not.toHaveProperty('password')
    expect(mysql).not.toHaveProperty('username')
    await service.closeAll()
  })

  it('redacts MySQL credentials from an unavailable saved profile', async () => {
    const failedClose = vi.fn(async () => undefined)
    const { factory } = adapterFactory(() => liveAdapter(
      vi.fn(async () => {
        throw new Error(`could not reach mysql.internal with ${savedMysqlInput.password}`)
      }),
      failedClose
    ))
    const service = new DatabaseService(vaultStore({
      load: vi.fn(async () => ({
        entries: [{ id: 'unavailable-mysql-id', input: savedMysqlInput }],
        warnings: []
      }))
    }), factory)

    await service.initialize()

    const profile = service.listConnections().find(({ id }) => id === 'unavailable-mysql-id')
    expect(profile).toMatchObject({
      engine: 'mysql',
      endpoint: 'mysql.internal:3306',
      saved: true,
      connected: false
    })
    expect(profile).not.toHaveProperty('password')
    expect(profile).not.toHaveProperty('username')
    expect(JSON.stringify(profile)).not.toContain(savedMysqlInput.password)
    expect(JSON.stringify(profile)).not.toContain(savedMysqlInput.username)
    expect(failedClose).toHaveBeenCalledOnce()
    await service.closeAll()
  })
})

describe('DatabaseService encrypted saved connections', () => {
  it('restores saved ids concurrently, isolates failures, and exposes only safe startup warnings', async () => {
    let releaseConnections: (() => void) | undefined
    const release = new Promise<void>((resolve) => {
      releaseConnections = resolve
    })
    let started = 0
    let bothStarted: (() => void) | undefined
    const bothConnectionsStarted = new Promise<void>((resolve) => {
      bothStarted = resolve
    })
    const closeFailed = vi.fn(async () => undefined)
    const { factory } = adapterFactory((input) => liveAdapter(
      vi.fn(async () => {
        started += 1
        if (started === 2) bothStarted?.()
        await release
        if (input.name === 'Offline') {
          if (input.engine !== 'postgresql') throw new Error('Expected PostgreSQL test input.')
          throw new Error(`could not reach ${input.host} with ${input.password}`)
        }
      }),
      input.name === 'Offline' ? closeFailed : vi.fn(async () => undefined)
    ))
    const load = vi.fn(async () => ({
      entries: [
        {
          id: 'stable-online-id',
          input: { ...savedPostgresInput, remember: true }
        },
        {
          id: 'stable-offline-id',
          input: { ...savedPostgresInput, name: 'Offline', password: 'FAILED_SECRET' }
        }
      ],
      warnings: [{
        code: 'INVALID_RECORD' as const,
        recordNumber: 4,
        message: 'A vault record is invalid.'
      }]
    }))
    const remove = vi.fn(async () => false)
    const service = new DatabaseService(vaultStore({ load, remove }), factory)

    const initializing = service.initialize()
    await bothConnectionsStarted
    expect(started).toBe(2)
    releaseConnections?.()
    await initializing
    await service.initialize()

    expect(load).toHaveBeenCalledOnce()
    expect(closeFailed).toHaveBeenCalledOnce()
    expect(service.listConnections()).toContainEqual(expect.objectContaining({
      id: 'stable-online-id',
      name: 'Saved PostgreSQL',
      saved: true,
      demo: false
    }))
    const offline = service.listConnections().find(({ id }) => id === 'stable-offline-id')
    expect(offline).toEqual({
      id: 'stable-offline-id',
      name: 'Offline',
      engine: 'postgresql',
      endpoint: 'db.internal:5432',
      database: 'app',
      environment: 'development',
      readOnly: false,
      demo: false,
      saved: true,
      connected: false,
      storageWarning: 'A saved connection could not be restored. Check its server access and credentials.'
    })
    expect(JSON.stringify(offline)).not.toContain('FAILED_SECRET')
    expect(JSON.stringify(offline)).not.toContain('app_user')
    expect(offline).not.toHaveProperty('input')
    expect(offline).not.toHaveProperty('username')
    expect(offline).not.toHaveProperty('password')
    expect(offline).not.toHaveProperty('uri')
    const internals = service as unknown as {
      offlineProfiles: Map<string, ConnectionProfile>
    }
    expect(JSON.stringify([...internals.offlineProfiles.values()])).not.toContain('FAILED_SECRET')
    await expect(service.listObjects('stable-offline-id')).rejects.toThrow(/unavailable/i)
    await expect(service.disconnect('stable-offline-id')).rejects.toThrow(/unavailable/i)
    expect(service.getStartupWarnings()).toEqual([
      'A vault record is invalid.',
      'A saved connection could not be restored. Check its server access and credentials.'
    ])
    expect(JSON.stringify(service.getStartupWarnings())).not.toContain('FAILED_SECRET')
    expect(JSON.stringify(service.getStartupWarnings())).not.toContain('db.internal')
    expect(factory).toHaveBeenCalledWith(expect.not.objectContaining({ remember: expect.anything() }))

    await service.forgetConnection('stable-offline-id')
    expect(remove).toHaveBeenCalledWith('stable-offline-id')
    expect(service.listConnections()).not.toContainEqual(expect.objectContaining({
      id: 'stable-offline-id'
    }))
  })

  it('keeps an unavailable saved profile when deleting its vault entry fails', async () => {
    const remove = vi.fn(async () => {
      throw new Error(`/private/vault ${savedPostgresInput.password}`)
    })
    const failedClose = vi.fn(async () => undefined)
    const { factory } = adapterFactory(() => liveAdapter(
      vi.fn(async () => {
        throw new Error(`offline ${savedPostgresInput.password}`)
      }),
      failedClose
    ))
    const service = new DatabaseService(vaultStore({
      load: vi.fn(async () => ({
        entries: [{ id: 'offline-retry-id', input: savedPostgresInput }],
        warnings: []
      })),
      remove
    }), factory)

    await service.initialize()
    await expect(service.forgetConnection('offline-retry-id')).rejects.toThrow(
      /saved profile remains available/i
    )

    expect(remove).toHaveBeenCalledWith('offline-retry-id')
    expect(failedClose).toHaveBeenCalledOnce()
    expect(service.listConnections()).toContainEqual(expect.objectContaining({
      id: 'offline-retry-id',
      saved: true,
      connected: false
    }))
    expect(JSON.stringify(service.listConnections())).not.toContain(savedPostgresInput.password)
  })

  it('turns a vault-level startup failure into one generic warning', async () => {
    const load = vi.fn(async () => {
      throw new Error('/private/path/connections.vault contains TOP_SECRET')
    })
    const { factory } = adapterFactory()
    const service = new DatabaseService(vaultStore({ load }), factory)

    await service.initialize()

    expect(factory).not.toHaveBeenCalled()
    expect(service.getStartupWarnings()).toEqual([
      'Saved connections could not be loaded securely. No plaintext credentials were used.'
    ])
  })

  it('redacts MongoDB credentials and URI details from an unavailable saved profile', async () => {
    const mongoInput: MongoConnectionInput = {
      engine: 'mongodb',
      name: 'Unavailable MongoDB',
      database: 'app',
      environment: 'staging',
      readOnly: true,
      uri: 'mongodb://uri-user:URI_SECRET@mongo.example:27017/?proxyPassword=QUERY_SECRET',
      username: 'field-user',
      password: 'FIELD_SECRET',
      tls: true
    }
    const failedClose = vi.fn(async () => undefined)
    const { factory } = adapterFactory(() => ({
      ...liveAdapter(
        vi.fn(async () => {
          throw new Error(`failed ${mongoInput.uri} ${mongoInput.password}`)
        }),
        failedClose
      ),
      engine: 'mongodb' as const
    }))
    const service = new DatabaseService(vaultStore({
      load: vi.fn(async () => ({
        entries: [{ id: 'unavailable-mongo-id', input: mongoInput }],
        warnings: []
      }))
    }), factory)

    await service.initialize()

    const profile = service.listConnections().find(({ id }) => id === 'unavailable-mongo-id')
    expect(profile).toMatchObject({
      endpoint: 'mongo.example:27017',
      saved: true,
      connected: false
    })
    expect(profile).not.toHaveProperty('input')
    expect(profile).not.toHaveProperty('username')
    expect(profile).not.toHaveProperty('password')
    expect(profile).not.toHaveProperty('uri')
    expect(JSON.stringify(profile)).not.toContain('URI_SECRET')
    expect(JSON.stringify(profile)).not.toContain('QUERY_SECRET')
    expect(JSON.stringify(profile)).not.toContain('FIELD_SECRET')
    expect(JSON.stringify(profile)).not.toContain('field-user')
    expect(failedClose).toHaveBeenCalledOnce()
  })

  it('saves a remembered connection only after connect and strips the remember intent', async () => {
    const save = vi.fn(async () => undefined)
    const store = vaultStore({ save })
    const connect = vi.fn(async () => undefined)
    const { factory, adapters } = adapterFactory(() => liveAdapter(connect))
    const service = new DatabaseService(store, factory)

    const profile = await service.connect({ ...savedPostgresInput, remember: true })

    expect(connect).toHaveBeenCalledOnce()
    expect(profile).toMatchObject({ saved: true, demo: false })
    expect(profile.storageWarning).toBeUndefined()
    expect(save).toHaveBeenCalledWith(
      profile.id,
      expect.not.objectContaining({ remember: expect.anything() })
    )
    expect(factory).toHaveBeenCalledWith(expect.not.objectContaining({ remember: expect.anything() }))
    expect(adapters[0].close).not.toHaveBeenCalled()
  })

  it('keeps a connected session when secure saving fails and returns a safe profile warning', async () => {
    const save = vi.fn(async () => {
      throw new Error(`/private/vault leaked ${savedPostgresInput.password}`)
    })
    const close = vi.fn(async () => undefined)
    const { factory } = adapterFactory(() => liveAdapter(vi.fn(async () => undefined), close))
    const service = new DatabaseService(vaultStore({ save }), factory)

    const profile = await service.connect({ ...savedPostgresInput, remember: true })

    expect(profile.saved).toBe(false)
    expect(profile.storageWarning).toMatch(/only for this session/i)
    expect(profile.storageWarning).not.toContain(savedPostgresInput.password)
    expect(service.listConnections()).toContainEqual(profile)
    expect(close).not.toHaveBeenCalled()
  })

  it('does not touch the vault unless remember is explicitly true', async () => {
    const save = vi.fn(async () => undefined)
    const { factory } = adapterFactory()
    const service = new DatabaseService(vaultStore({ save }), factory)

    const omitted = await service.connect(savedPostgresInput)
    const disabled = await service.connect({ ...savedPostgresInput, name: 'Temporary', remember: false })

    expect(save).not.toHaveBeenCalled()
    expect(omitted).toMatchObject({ saved: false })
    expect(disabled).toMatchObject({ saved: false })
    expect(omitted.storageWarning).toBeUndefined()
    expect(disabled.storageWarning).toBeUndefined()
  })

  it('keeps saved credentials on disconnect but removes them on explicit forget', async () => {
    const remove = vi.fn(async () => true)
    const store = vaultStore({ remove })
    const firstClose = vi.fn(async () => undefined)
    const secondClose = vi.fn(async () => undefined)
    const { factory } = adapterFactory((_input, index) =>
      liveAdapter(vi.fn(async () => undefined), index === 0 ? firstClose : secondClose)
    )
    const service = new DatabaseService(store, factory)
    const disconnected = await service.connect({ ...savedPostgresInput, remember: true })
    const forgotten = await service.connect({
      ...savedPostgresInput,
      name: 'Forget me',
      remember: true
    })

    await service.disconnect(disconnected.id)
    expect(firstClose).toHaveBeenCalledOnce()
    expect(remove).not.toHaveBeenCalled()

    await service.forgetConnection(forgotten.id)
    expect(secondClose).toHaveBeenCalledOnce()
    expect(remove).toHaveBeenCalledWith(forgotten.id)
    expect(service.listConnections()).not.toContainEqual(expect.objectContaining({ id: forgotten.id }))
  })

  it('keeps a saved session usable when vault removal fails so forget can be retried', async () => {
    const remove = vi.fn()
      .mockRejectedValueOnce(new Error('/private/vault permission denied'))
      .mockResolvedValueOnce(true)
    const close = vi.fn(async () => undefined)
    const { factory } = adapterFactory(() => liveAdapter(vi.fn(async () => undefined), close))
    const service = new DatabaseService(vaultStore({ remove }), factory)
    const profile = await service.connect({ ...savedPostgresInput, remember: true })

    await expect(service.forgetConnection(profile.id)).rejects.toThrow(/remains open/i)
    expect(service.listConnections()).toContainEqual(profile)
    expect(close).not.toHaveBeenCalled()

    await service.forgetConnection(profile.id)
    expect(remove).toHaveBeenCalledTimes(2)
    expect(close).toHaveBeenCalledOnce()
    expect(service.listConnections()).not.toContainEqual(expect.objectContaining({ id: profile.id }))
  })

  it('keeps a session registered when close fails after credentials are removed', async () => {
    const remove = vi.fn()
      .mockResolvedValueOnce(true)
      .mockResolvedValueOnce(false)
    const close = vi.fn()
      .mockRejectedValueOnce(new Error('driver close failed with SECRET'))
      .mockResolvedValueOnce(undefined)
    const { factory } = adapterFactory(() => liveAdapter(vi.fn(async () => undefined), close))
    const service = new DatabaseService(vaultStore({ remove }), factory)
    const profile = await service.connect({ ...savedPostgresInput, remember: true })

    await expect(service.forgetConnection(profile.id)).rejects.toThrow(
      /credentials were removed.*session remains open/i
    )
    expect(service.listConnections()).toContainEqual(profile)

    await service.forgetConnection(profile.id)
    expect(remove).toHaveBeenCalledTimes(2)
    expect(close).toHaveBeenCalledTimes(2)
    expect(service.listConnections()).not.toContainEqual(expect.objectContaining({ id: profile.id }))
  })
})

describe('DatabaseService safe data changes', () => {
  it('rejects a record engine mismatch before reaching the adapter', async () => {
    const service = new DatabaseService()
    const profile = editableProfile()
    const adapter = adapterWithApply()
    injectSession(service, profile, adapter)

    await expect(service.applyDataChange(
      profile.id,
      'table-users',
      'mongodb',
      { action: 'update', original: { id: 1 }, current: { id: 1, active: true } }
    )).rejects.toThrow(/record type does not match/i)
    expect(adapter.applyDataChange).not.toHaveBeenCalled()
  })

  it.each([
    ['demo', { demo: true, readOnly: false }, /real database connection/i],
    ['read-only', { demo: false, readOnly: true }, /disabled for read-only/i]
  ])('rejects editing on a %s profile', async (_label, overrides, expected) => {
    const service = new DatabaseService()
    const profile = editableProfile(overrides)
    const adapter = adapterWithApply()
    injectSession(service, profile, adapter)

    await expect(service.applyDataChange(
      profile.id,
      'table-users',
      'postgresql',
      { action: 'delete', original: { id: 1 } }
    )).rejects.toThrow(expected)
    expect(adapter.applyDataChange).not.toHaveBeenCalled()
  })

  it('rejects an adapter without safe editing support', async () => {
    const service = new DatabaseService()
    const profile = editableProfile()
    const adapter = adapterWithApply()
    delete adapter.applyDataChange
    injectSession(service, profile, adapter)

    await expect(service.applyDataChange(
      profile.id,
      'table-users',
      'postgresql',
      { action: 'delete', original: { id: 1 } }
    )).rejects.toThrow(/does not support safe editing/i)
  })

  it.each([
    [
      'update',
      { action: 'update' as const, original: { id: 7, name: 'Before' }, current: { id: 7, name: 'After' } },
      { action: 'update' as const, affected: 1 as const }
    ],
    [
      'delete',
      { action: 'delete' as const, original: { id: 7, name: 'Before' } },
      { action: 'delete' as const, affected: 1 as const }
    ]
  ])('forwards a valid %s exactly once', async (_label, change, result) => {
    const service = new DatabaseService()
    const profile = editableProfile()
    const applyDataChange = vi.fn(async () => result)
    const adapter = adapterWithApply(applyDataChange)
    injectSession(service, profile, adapter)

    await expect(service.applyDataChange(
      profile.id,
      'table-users',
      'postgresql',
      change as { action: 'update' | 'delete'; original: DataRecord; current?: DataRecord }
    )).resolves.toEqual(result)
    expect(applyDataChange).toHaveBeenCalledOnce()
    expect(applyDataChange).toHaveBeenCalledWith(profile, 'table-users', change)
  })
})

describe('DatabaseService import safeguards', () => {
  it.each([
    ['demo', { demo: true, readOnly: false }, /real database connection/i],
    ['read-only', { demo: false, readOnly: true }, /disabled for read-only/i]
  ])('rejects import on a %s profile before reaching the adapter', async (_label, overrides, expected) => {
    const service = new DatabaseService()
    const profile = editableProfile(overrides)
    const adapter = adapterWithImport()
    injectSession(service, profile, adapter)

    await expect(service.importData(
      profile.id,
      'table-users',
      emptySource(),
      { format: 'csv', hasHeader: true }
    )).rejects.toThrow(expected)
    expect(adapter.importData).not.toHaveBeenCalled()
  })

  it('forwards a valid import to the adapter exactly once', async () => {
    const service = new DatabaseService()
    const profile = editableProfile()
    const importData = vi.fn(async () => ({ processed: 2, inserted: 2, failed: 0 }))
    const adapter = adapterWithImport(importData)
    injectSession(service, profile, adapter)
    const source = emptySource()
    const options = { format: 'csv' as const, hasHeader: true }

    await expect(service.importData(profile.id, 'table-users', source, options)).resolves.toEqual({
      processed: 2,
      inserted: 2,
      failed: 0
    })
    expect(importData).toHaveBeenCalledOnce()
    expect(importData).toHaveBeenCalledWith(profile, 'table-users', source, options)
  })
})
