import { randomUUID } from 'node:crypto'
import type {
  ApplyDataChangeResult,
  ConnectionDraft,
  ConnectionInput,
  ConnectionProfile,
  DataChangeAction,
  DataRecord,
  DatabaseCommand,
  DatabaseObjectNode,
  DatabaseResult
} from '../shared/database'
import type {
  DatabaseAdapter,
  ExecuteOptions,
  ImportDataOptions,
  ImportDataSummary
} from './adapters/database-adapter'
import { DemoMongoAdapter, DemoPostgresAdapter } from './adapters/demo-adapters'
import { MongoAdapter } from './adapters/mongo-adapter'
import { MySqlAdapter } from './adapters/mysql-adapter'
import { PostgresAdapter } from './adapters/postgres-adapter'
import { SqliteAdapter } from './adapters/sqlite-adapter'
import type {
  ConnectionVaultLoadResult,
  ConnectionVaultWarning
} from './profiles/connection-vault'
import type { ByteSource } from './transfers/delimited'

interface DatabaseSession {
  profile: ConnectionProfile
  adapter: DatabaseAdapter
}

export interface ConnectionVaultStore {
  load(): Promise<ConnectionVaultLoadResult>
  save(id: string, input: ConnectionInput): Promise<void>
  remove(id: string): Promise<boolean>
}

export interface LiveDatabaseAdapter extends DatabaseAdapter {
  connect(): Promise<void>
}

export type LiveAdapterFactory = (input: ConnectionInput) => LiveDatabaseAdapter

const defaultExecuteOptions: Omit<ExecuteOptions, 'requestId'> = {
  timeoutMs: 30_000,
  maxRows: 500,
  maxBytes: 5 * 1024 * 1024
}

const initialProfiles: ConnectionProfile[] = [
  {
    id: 'local-postgres',
    name: 'Local product',
    engine: 'postgresql',
    endpoint: 'localhost:5432',
    database: 'dbbbb_dev',
    environment: 'development',
    readOnly: false,
    demo: true
  },
  {
    id: 'mongo-sandbox',
    name: 'Mongo sandbox',
    engine: 'mongodb',
    endpoint: 'localhost:27017',
    database: 'product',
    environment: 'staging',
    readOnly: true,
    demo: true
  }
]

function createDemoAdapter(profile: ConnectionProfile): DatabaseAdapter {
  if (profile.engine === 'postgresql') return new DemoPostgresAdapter()
  if (profile.engine === 'mongodb') return new DemoMongoAdapter()
  throw new Error('Demo connections are only available for PostgreSQL and MongoDB.')
}

function mongoEndpoint(uri: string): string {
  const authority = uri.replace(/^mongodb(?:\+srv)?:\/\//i, '').split(/[/?#]/)[0]
  const credentialSeparator = authority.lastIndexOf('@')
  return (credentialSeparator >= 0 ? authority.slice(credentialSeparator + 1) : authority).slice(0, 240)
}

function connectionEndpoint(input: ConnectionInput): string {
  if (input.engine === 'postgresql' || input.engine === 'mysql') {
    return `${input.host}:${input.port}`
  }
  if (input.engine === 'sqlite') return input.filePath
  return mongoEndpoint(input.uri)
}

function createLiveAdapter(input: ConnectionInput): LiveDatabaseAdapter {
  if (input.engine === 'postgresql') return new PostgresAdapter(input)
  if (input.engine === 'mongodb') return new MongoAdapter(input)
  if (input.engine === 'mysql') return new MySqlAdapter(input)
  return new SqliteAdapter(input)
}

function normalizedConnectionInput(input: ConnectionInput): ConnectionInput {
  if (input.remember !== undefined && typeof input.remember !== 'boolean') {
    throw new Error('Remember connection setting is invalid.')
  }
  const normalized = { ...input }
  delete normalized.remember
  return normalized
}

function startupWarningForRecord(warning: ConnectionVaultWarning): string {
  return warning.message
}

function offlineProfile(id: string, input: ConnectionInput): ConnectionProfile {
  return {
    id,
    name: input.name,
    engine: input.engine,
    endpoint: connectionEndpoint(input),
    database: input.database,
    environment: input.environment,
    readOnly: input.readOnly,
    demo: false,
    saved: true,
    connected: false,
    storageWarning: CONNECTION_RESTORE_WARNING
  }
}

const STORAGE_SAVE_WARNING =
  'Secure storage is unavailable; this connection will remain available only for this session.'
const STORAGE_LOAD_WARNING =
  'Saved connections could not be loaded securely. No plaintext credentials were used.'
const CONNECTION_RESTORE_WARNING =
  'A saved connection could not be restored. Check its server access and credentials.'
const SERVICE_SHUTTING_DOWN_ERROR = 'The database service is shutting down.'
const MAX_SESSIONS = 50

export class DatabaseService {
  private readonly sessions = new Map<string, DatabaseSession>(
    initialProfiles.map((profile) => [profile.id, { profile, adapter: createDemoAdapter(profile) }])
  )
  private readonly offlineProfiles = new Map<string, ConnectionProfile>()
  private readonly startupWarnings: string[] = []
  private readonly pendingConnections = new Set<Promise<ConnectionProfile>>()
  private initialization: Promise<void> | undefined
  private shutdown: Promise<void> | undefined
  private shuttingDown = false

  constructor(
    private readonly vault?: ConnectionVaultStore,
    private readonly liveAdapterFactory: LiveAdapterFactory = createLiveAdapter
  ) {}

  initialize(): Promise<void> {
    this.assertRunning()
    this.initialization ??= this.restoreSavedConnections()
    return this.initialization
  }

  getStartupWarnings(): string[] {
    return [...this.startupWarnings]
  }

  listConnections(): ConnectionProfile[] {
    return structuredClone([
      ...[...this.sessions.values()].map(({ profile }) => profile),
      ...this.offlineProfiles.values()
    ])
  }

  connect(input: ConnectionInput): Promise<ConnectionProfile> {
    this.assertRunning()
    const operation = this.connectAndMaybeSave(input)
    this.pendingConnections.add(operation)
    void operation.then(
      () => this.pendingConnections.delete(operation),
      () => this.pendingConnections.delete(operation)
    )
    return operation
  }

  private async connectAndMaybeSave(input: ConnectionInput): Promise<ConnectionProfile> {
    const remember = input.remember === true
    const normalized = normalizedConnectionInput(input)
    const profile = await this.openLiveSession(randomUUID(), normalized, false)
    const session = this.sessions.get(profile.id)!

    if (remember) {
      if (!this.vault) {
        session.profile.saved = false
        session.profile.storageWarning = STORAGE_SAVE_WARNING
      } else {
        try {
          await this.vault.save(profile.id, normalized)
          session.profile.saved = true
          delete session.profile.storageWarning
        } catch {
          session.profile.saved = false
          session.profile.storageWarning = STORAGE_SAVE_WARNING
        }
      }
    }
    return structuredClone(session.profile)
  }

  createDemoConnection(draft: ConnectionDraft): ConnectionProfile {
    this.assertRunning()
    const profile: ConnectionProfile = {
      ...draft,
      id: randomUUID(),
      demo: true
    }
    this.sessions.set(profile.id, { profile, adapter: createDemoAdapter(profile) })
    return structuredClone(profile)
  }

  async disconnect(connectionId: string): Promise<void> {
    const session = this.requireSession(connectionId)
    try {
      await session.adapter.close()
    } catch {
      throw new Error('The database session did not close cleanly; retry disconnecting it.')
    }
    this.sessions.delete(connectionId)
  }

  async forgetConnection(connectionId: string): Promise<void> {
    this.assertRunning()
    const session = this.sessions.get(connectionId)
    if (!session) {
      const offline = this.offlineProfiles.get(connectionId)
      if (!offline) throw new Error('Connection not found or already disconnected.')
      if (!this.vault) {
        throw new Error('Saved credentials could not be removed securely; the saved profile remains available.')
      }
      try {
        await this.vault.remove(connectionId)
      } catch {
        throw new Error('Saved credentials could not be removed securely; the saved profile remains available.')
      }
      this.offlineProfiles.delete(connectionId)
      return
    }
    if (session.profile.saved && this.vault) {
      try {
        await this.vault.remove(connectionId)
      } catch {
        throw new Error('Saved credentials could not be removed securely; the connection remains open.')
      }
    }
    try {
      await session.adapter.close()
    } catch {
      throw new Error(
        session.profile.saved
          ? 'Saved credentials were removed, but the database session remains open; retry forgetting it.'
          : 'The database session remains open; retry closing it.'
      )
    }
    this.sessions.delete(connectionId)
  }

  async listObjects(connectionId: string): Promise<DatabaseObjectNode[]> {
    const session = this.requireSession(connectionId)
    return session.adapter.listObjects(session.profile)
  }

  async previewObject(connectionId: string, objectId: string): Promise<DatabaseCommand> {
    const session = this.requireSession(connectionId)
    return session.adapter.previewObject(session.profile, objectId)
  }

  async execute(
    connectionId: string,
    requestId: string,
    command: DatabaseCommand
  ): Promise<DatabaseResult> {
    const session = this.requireSession(connectionId)
    if (session.profile.engine !== command.engine) {
      throw new Error('The query type does not match the selected connection.')
    }
    return session.adapter.execute(session.profile, command, {
      ...defaultExecuteOptions,
      requestId
    })
  }

  async cancel(connectionId: string, requestId: string): Promise<void> {
    const session = this.requireSession(connectionId)
    await session.adapter.cancel(requestId)
  }

  async applyDataChange(
    connectionId: string,
    objectId: string,
    engine: ConnectionProfile['engine'],
    change: { action: DataChangeAction; original: DataRecord; current?: DataRecord }
  ): Promise<ApplyDataChangeResult> {
    const session = this.requireSession(connectionId)
    if (session.profile.engine !== engine) {
      throw new Error('The record type does not match the selected connection.')
    }
    if (session.profile.demo) {
      throw new Error('Editing requires a real database connection.')
    }
    if (session.profile.readOnly) {
      throw new Error('Editing is disabled for read-only connections.')
    }
    if (!session.adapter.applyDataChange) {
      throw new Error('This database connection does not support safe editing yet.')
    }
    return session.adapter.applyDataChange(session.profile, objectId, change)
  }

  async inspectImportTarget(
    connectionId: string,
    objectId: string
  ): Promise<{ profile: ConnectionProfile; object: DatabaseObjectNode }> {
    const session = this.requireSession(connectionId)
    if (session.profile.readOnly) {
      throw new Error('Import is disabled for read-only connections.')
    }
    if (session.profile.demo) {
      throw new Error('Import requires a real database connection.')
    }
    const objects = await session.adapter.listObjects(session.profile)
    const object = objects.find((candidate) => candidate.id === objectId)
    if (!object) throw new Error('Import target was not found. Refresh objects and try again.')
    return { profile: structuredClone(session.profile), object: structuredClone(object) }
  }

  async importData(
    connectionId: string,
    objectId: string,
    source: ByteSource,
    options: ImportDataOptions
  ): Promise<ImportDataSummary> {
    const session = this.requireSession(connectionId)
    if (session.profile.readOnly) {
      throw new Error('Import is disabled for read-only connections.')
    }
    if (session.profile.demo) {
      throw new Error('Import requires a real database connection.')
    }
    if (!session.adapter.importData) {
      throw new Error('This database connection does not support import yet.')
    }
    return session.adapter.importData(session.profile, objectId, source, options)
  }

  closeAll(): Promise<void> {
    this.shuttingDown = true
    this.shutdown ??= this.finishShutdown()
    return this.shutdown
  }

  private async finishShutdown(): Promise<void> {
    await this.initialization?.catch(() => undefined)

    const sessions = [...this.sessions.values()]
    this.sessions.clear()
    this.offlineProfiles.clear()
    await Promise.allSettled(sessions.map(({ adapter }) => adapter.close()))

    // A renderer can request a connection immediately before before-quit runs.
    // Wait for those operations: openLiveSession will close an adapter that
    // finishes connecting after shuttingDown was set instead of publishing it.
    await Promise.allSettled([...this.pendingConnections])

    // Defensive final sweep for a connection that was published immediately
    // before shuttingDown was set but after the first session snapshot.
    const lateSessions = [...this.sessions.values()]
    this.sessions.clear()
    this.offlineProfiles.clear()
    await Promise.allSettled(lateSessions.map(({ adapter }) => adapter.close()))
  }

  private async restoreSavedConnections(): Promise<void> {
    if (!this.vault) return
    let loaded: ConnectionVaultLoadResult
    try {
      loaded = await this.vault.load()
    } catch {
      this.startupWarnings.push(STORAGE_LOAD_WARNING)
      return
    }

    this.startupWarnings.push(...loaded.warnings.map(startupWarningForRecord))
    const candidates = loaded.entries.filter((entry) => {
      if (this.sessions.has(entry.id)) {
        this.startupWarnings.push(CONNECTION_RESTORE_WARNING)
        return false
      }
      return true
    })
    const restorations = await Promise.allSettled(candidates.map(async (entry) =>
      this.createLiveSession(entry.id, normalizedConnectionInput(entry.input), true)
    ))
    for (let index = 0; index < restorations.length; index += 1) {
      const restoration = restorations[index]
      if (restoration.status === 'fulfilled') {
        const session = restoration.value
        this.sessions.set(session.profile.id, session)
      } else {
        this.startupWarnings.push(CONNECTION_RESTORE_WARNING)
        const candidate = candidates[index]
        this.offlineProfiles.set(candidate.id, offlineProfile(candidate.id, candidate.input))
      }
    }
  }

  private async openLiveSession(
    id: string,
    input: ConnectionInput,
    saved: boolean
  ): Promise<ConnectionProfile> {
    if (this.sessions.size >= MAX_SESSIONS) {
      throw new Error('Too many open connections. Disconnect one before connecting again.')
    }
    const session = await this.createLiveSession(id, input, saved)
    if (this.shuttingDown) {
      await session.adapter.close().catch(() => undefined)
      throw new Error(SERVICE_SHUTTING_DOWN_ERROR)
    }
    this.sessions.set(session.profile.id, session)
    return session.profile
  }

  private async createLiveSession(
    id: string,
    input: ConnectionInput,
    saved: boolean
  ): Promise<DatabaseSession> {
    let adapter: LiveDatabaseAdapter
    try {
      adapter = this.liveAdapterFactory(input)
    } catch {
      throw new Error('Database adapter could not be created.')
    }
    try {
      await adapter.connect()
    } catch (error) {
      await adapter.close().catch(() => undefined)
      throw error
    }

    const profile: ConnectionProfile = {
      id,
      name: input.name,
      engine: input.engine,
      endpoint: connectionEndpoint(input),
      database: input.database,
      environment: input.environment,
      readOnly: input.readOnly,
      demo: false,
      saved
    }
    return { profile, adapter }
  }

  private requireSession(connectionId: string): DatabaseSession {
    this.assertRunning()
    const session = this.sessions.get(connectionId)
    if (!session) {
      if (this.offlineProfiles.has(connectionId)) {
        throw new Error('Saved connection is unavailable. Reconnect it before using database operations.')
      }
      throw new Error('Connection not found or already disconnected.')
    }
    return session
  }

  private assertRunning(): void {
    if (this.shuttingDown) throw new Error(SERVICE_SHUTTING_DOWN_ERROR)
  }
}
