import { BSON, MongoClient, MongoServerError } from 'mongodb'
import type { Abortable, BulkWriteOptions, Document, MongoClientOptions } from 'mongodb'
import type {
  ApplyDataChangeResult,
  ConnectionProfile,
  DataRecord,
  DatabaseCommand,
  DatabaseObjectNode,
  DatabaseResult,
  DocumentResult,
  MongoConnectionInput,
  WireValue
} from '../../shared/database'
import { planMongoUpdate } from '../editing/change-planner'
import { ImportRunnerError, runJsonLinesImport } from '../transfers/import-runner'
import type { ByteSource } from '../transfers/delimited'
import type {
  AdapterDataChange,
  DatabaseAdapter,
  ExecuteOptions,
  ImportDataOptions,
  ImportDataSummary
} from './database-adapter'

const WRITE_AGGREGATION_STAGES = new Set(['$merge', '$out'])
const DANGEROUS_PROPERTY_NAMES = new Set(['__proto__', 'constructor', 'prototype'])
const MAX_DOCUMENT_DEPTH = 100
const MAX_DOCUMENT_VALUES = 100_000
const DATA_CHANGE_MAX_TIME_MS = 30_000
const MONGO_SRV_SCHEME = /^mongodb\+srv:\/\//i

function asObject(value: unknown, message: string): Document {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(message)
  }
  return value as Document
}

export function parseMongoInput(kind: 'find' | 'aggregate', text: string): Document | Document[] {
  let parsed: unknown
  try {
    parsed = BSON.EJSON.parse(text, { relaxed: false })
  } catch {
    throw new Error('Invalid MongoDB Extended JSON. Check quotes, commas, and BSON tags.')
  }

  if (kind === 'find') {
    return asObject(parsed, 'A find filter must be one JSON object.')
  }
  if (!Array.isArray(parsed)) {
    throw new Error('An aggregation pipeline must be a JSON array of stage objects.')
  }
  return parsed.map((stage) => asObject(stage, 'Every aggregation stage must be one JSON object.'))
}

export function assertReadOnlyPipeline(pipeline: Document[]): void {
  for (const stage of pipeline) {
    for (const stageName of Object.keys(stage)) {
      if (WRITE_AGGREGATION_STAGES.has(stageName)) {
        throw new Error(`${stageName} is disabled because it writes data.`)
      }
    }
  }
}

export function documentToWire(document: Document): Record<string, WireValue> {
  return JSON.parse(BSON.EJSON.stringify(document, { relaxed: false })) as Record<string, WireValue>
}

interface WireCloneState {
  values: number
  seen: WeakSet<object>
}

function cloneSafeWireValue(
  value: unknown,
  label: string,
  depth: number,
  state: WireCloneState
): unknown {
  state.values += 1
  if (state.values > MAX_DOCUMENT_VALUES) {
    throw new Error(`${label} contains too many values.`)
  }
  if (depth > MAX_DOCUMENT_DEPTH) {
    throw new Error(`${label} exceeds MongoDB's supported nesting depth.`)
  }
  if (
    value === null ||
    typeof value === 'string' ||
    typeof value === 'boolean'
  ) {
    return value
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`${label} contains a non-finite number.`)
    return value
  }
  if (typeof value !== 'object') {
    throw new Error(`${label} contains an unsupported value.`)
  }
  if (state.seen.has(value)) throw new Error(`${label} cannot contain circular references.`)
  state.seen.add(value)

  if (Array.isArray(value)) {
    const clone: unknown[] = []
    for (let index = 0; index < value.length; index += 1) {
      const descriptor = Object.getOwnPropertyDescriptor(value, String(index))
      if (!descriptor || !descriptor.enumerable || !('value' in descriptor)) {
        throw new Error(`${label} arrays must contain only data values.`)
      }
      clone.push(cloneSafeWireValue(descriptor.value, label, depth + 1, state))
    }
    const allowedKeys = new Set(['length', ...clone.map((_, index) => String(index))])
    if (Reflect.ownKeys(value).some((key) => typeof key !== 'string' || !allowedKeys.has(key))) {
      throw new Error(`${label} arrays cannot contain custom properties.`)
    }
    return clone
  }

  const prototype = Object.getPrototypeOf(value)
  if (prototype !== Object.prototype && prototype !== null) {
    throw new Error(`${label} must contain only plain objects.`)
  }
  const clone = Object.create(null) as Record<string, unknown>
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== 'string') throw new Error(`${label} cannot contain symbol keys.`)
    if (DANGEROUS_PROPERTY_NAMES.has(key)) {
      throw new Error(`${label} contains an unsafe object key.`)
    }
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    if (!descriptor?.enumerable || !('value' in descriptor)) {
      throw new Error(`${label} must contain only enumerable data properties.`)
    }
    Object.defineProperty(clone, key, {
      configurable: true,
      enumerable: true,
      writable: true,
      value: cloneSafeWireValue(descriptor.value, label, depth + 1, state)
    })
  }
  return clone
}

function dataRecordToBson(record: DataRecord, label: string): Document {
  const safeRecord = cloneSafeWireValue(record, label, 0, {
    values: 0,
    seen: new WeakSet<object>()
  })
  try {
    const document = BSON.EJSON.deserialize(safeRecord as Document, { relaxed: false })
    if (!document || typeof document !== 'object' || Array.isArray(document)) {
      throw new Error('not a document')
    }
    return document
  } catch {
    throw new Error(`${label} contains invalid canonical Extended JSON.`)
  }
}

function assertSafeMongoField(field: string, label: string): void {
  if (
    field.length === 0 ||
    field.includes('\0') ||
    field.includes('.') ||
    field.includes('$') ||
    DANGEROUS_PROPERTY_NAMES.has(field)
  ) {
    throw new Error(`${label} contains an unsafe MongoDB field name.`)
  }
}

function mongoDeleteFilter(original: Document): Document {
  if (!Object.prototype.hasOwnProperty.call(original, '_id')) {
    throw new Error('A MongoDB single-document delete requires _id in the original document.')
  }
  const filter = Object.create(null) as Document
  for (const [field, value] of Object.entries(original)) {
    assertSafeMongoField(field, 'MongoDB original document')
    Object.defineProperty(filter, field, {
      configurable: true,
      enumerable: true,
      writable: true,
      value: value === null ? { $eq: null, $exists: true } : { $eq: value }
    })
  }
  return filter
}

function safeMongoError(error: unknown, timeoutMs?: number): Error {
  if (error instanceof Error) {
    if (error.name === 'AbortError' || /aborted/i.test(error.message)) {
      return new Error('MongoDB query cancelled.')
    }
    if (error instanceof MongoServerError) {
      if (error.code === 18) return new Error('MongoDB authentication failed. Check the username and password.')
      if (error.code === 50) {
        return new Error(
          timeoutMs === undefined
            ? 'MongoDB query timed out.'
            : `MongoDB query timed out after ${timeoutMs} ms.`
        )
      }
      const code = error.codeName || String(error.code)
      return new Error(`MongoDB ${code}: ${redactMongoMessage(error.message)}`)
    }
    if (/server selection|ECONNREFUSED|ENOTFOUND|timed out/i.test(error.message)) {
      return new Error('Could not reach MongoDB. Check the URI, TLS setting, and network access.')
    }
    return new Error(redactMongoMessage(error.message))
  }
  return new Error('MongoDB operation failed.')
}

function redactMongoMessage(message: string): string {
  return message
    .replace(/mongodb(?:\+srv)?:\/\/[^\s@/]+@/gi, 'mongodb://[credentials]@')
    .replace(/(password|pwd)=([^&\s]+)/gi, '$1=[redacted]')
    .slice(0, 600)
}

function bulkInsertedCount(error: unknown): number {
  const result = (error as { result?: { insertedCount?: unknown } } | null)?.result
  return typeof result?.insertedCount === 'number' ? result.insertedCount : 0
}

/**
 * Ordered batches can commit partially before failing or being cancelled, so
 * the real inserted count travels on the error for the transfer layer. When
 * the batch was aborted the count is attached to the signal's abort reason,
 * which the import runner rethrows instead of the driver's error.
 */
function withInsertedCount(
  error: unknown,
  signal: AbortSignal | undefined,
  insertedCount: number
): unknown {
  const reason = signal?.aborted && signal.reason instanceof Error ? signal.reason : error
  if (reason instanceof Error) {
    ;(reason as Error & { insertedCount?: number }).insertedCount =
      insertedCount > 0 ? insertedCount : bulkInsertedCount(error)
  }
  return reason
}

function importErrorInsertedCount(error: unknown): number | undefined {
  const cause = error instanceof ImportRunnerError ? error.cause : error
  if (!cause || typeof cause !== 'object') return undefined
  const insertedCount = (cause as { insertedCount?: unknown }).insertedCount
  return typeof insertedCount === 'number' && Number.isSafeInteger(insertedCount)
    ? insertedCount
    : undefined
}

function safeMongoImportCause(error: unknown): string {
  if (error instanceof Error) {
    if (error.name === 'AbortError' || /aborted|cancelled/i.test(error.message)) {
      return 'MongoDB import cancelled.'
    }
    const code = (error as Error & { code?: unknown }).code
    if (code === 18) return 'MongoDB authentication failed.'
    if (code === 50) return 'MongoDB import timed out.'
    if (code === 11000) {
      return 'MongoDB rejected a document because it violates a unique index.'
    }
    if (/server selection|ECONNREFUSED|ENOTFOUND|timed out/i.test(error.message)) {
      return 'The MongoDB server became unavailable during import.'
    }
  }
  return 'MongoDB rejected an import batch.'
}

function safeMongoImportError(error: unknown): Error {
  const message = error instanceof ImportRunnerError
    ? error.code === 'INSERT_FAILED'
      ? safeMongoImportCause(error.cause)
      : error.message
    : safeMongoImportCause(error)
  const result = new Error(
    `${message} MongoDB imports are not transactional; earlier batches may already have been inserted.`
  )
  if (
    (error instanceof Error && error.name === 'AbortError') ||
    (error instanceof ImportRunnerError && error.cause instanceof Error && error.cause.name === 'AbortError')
  ) {
    result.name = 'AbortError'
  }
  const insertedCount = importErrorInsertedCount(error)
  if (insertedCount !== undefined) {
    ;(result as Error & { insertedCount?: number }).insertedCount = insertedCount
  }
  return result
}

function safeMongoDataChangeError(error: unknown): Error {
  if (error instanceof Error) {
    const code = (error as Error & { code?: unknown }).code
    if (code === 18) return new Error('MongoDB authentication failed.')
    if (code === 13) return new Error('MongoDB did not authorize this document change.')
    if (code === 50) return new Error('MongoDB document change timed out.')
    if (code === 11000) {
      return new Error('MongoDB rejected this change because it violates a unique index.')
    }
    if (code === 121) {
      return new Error('MongoDB rejected this change because it violates collection validation.')
    }
    if (/server selection|ECONNREFUSED|ENOTFOUND|timed out/i.test(error.message)) {
      return new Error('The MongoDB server became unavailable while applying the document change.')
    }
  }
  return new Error('MongoDB could not apply the document change.')
}

class MongoConcurrencyConflictError extends Error {
  constructor() {
    super('MongoDB document changed or was deleted after it was loaded. Refresh it and try again.')
    this.name = 'MongoConcurrencyConflictError'
  }
}

function concurrencyConflict(): MongoConcurrencyConflictError {
  return new MongoConcurrencyConflictError()
}

function makeCollectionId(database: string, collection: string): string {
  return `mongo:collection:${Buffer.from(`${database}\0${collection}`).toString('base64url')}`
}

function assertProfile(profile: ConnectionProfile): void {
  if (profile.engine !== 'mongodb') {
    throw new Error('The selected connection is not a MongoDB connection.')
  }
}

function validateExecuteOptions(options: ExecuteOptions): void {
  if (
    options.requestId.trim().length === 0 ||
    options.requestId.length > 128 ||
    !Number.isInteger(options.timeoutMs) ||
    options.timeoutMs < 1 ||
    !Number.isInteger(options.maxRows) ||
    options.maxRows < 1 ||
    !Number.isInteger(options.maxBytes) ||
    options.maxBytes < 1
  ) {
    throw new Error('MongoDB execution options are invalid.')
  }
}

export function mongoClientOptions(input: MongoConnectionInput): MongoClientOptions {
  if (MONGO_SRV_SCHEME.test(input.uri) && !input.tls) {
    throw new Error(
      'MongoDB SRV URIs (mongodb+srv://) require TLS. Enable TLS or use a standard mongodb:// URI.'
    )
  }
  const options: MongoClientOptions = {
    appName: 'dbbbb',
    connectTimeoutMS: 10_000,
    serverSelectionTimeoutMS: 10_000,
    tls: input.tls
  }
  if (input.username) {
    options.auth = { username: input.username, password: input.password ?? '' }
  }
  return options
}

export class MongoAdapter implements DatabaseAdapter {
  readonly engine = 'mongodb' as const
  private readonly client: MongoClient
  private readonly databaseName: string
  private readonly readOnly: boolean
  private readonly collectionNames = new Map<string, string>()
  private readonly activeRequests = new Map<string, AbortController>()
  private readonly cancelledRequestIds = new Set<string>()
  private closed = false

  constructor(input: MongoConnectionInput) {
    this.databaseName = input.database
    this.readOnly = input.readOnly
    this.client = new MongoClient(input.uri, mongoClientOptions(input))
  }

  async connect(): Promise<void> {
    this.assertOpen()
    try {
      await this.client.connect()
      await this.client.db(this.databaseName).command({ ping: 1 })
    } catch (error) {
      throw safeMongoError(error)
    }
  }

  async listObjects(profile: ConnectionProfile): Promise<DatabaseObjectNode[]> {
    assertProfile(profile)
    this.assertOpen()
    try {
      const collections = await this.client
        .db(this.databaseName)
        .listCollections({}, { nameOnly: true, authorizedCollections: true })
        .toArray()
      const databaseId = `mongo:database:${Buffer.from(this.databaseName).toString('base64url')}`
      this.collectionNames.clear()
      const nodes: DatabaseObjectNode[] = [
        {
          id: databaseId,
          name: this.databaseName,
          kind: 'database',
          detail: `${collections.length} ${collections.length === 1 ? 'collection' : 'collections'}`
        }
      ]
      for (const collection of collections.sort((left, right) => left.name.localeCompare(right.name))) {
        const id = makeCollectionId(this.databaseName, collection.name)
        this.collectionNames.set(id, collection.name)
        nodes.push({ id, parentId: databaseId, name: collection.name, kind: 'collection' })
      }
      return nodes
    } catch (error) {
      throw safeMongoError(error)
    }
  }

  async previewObject(
    profile: ConnectionProfile,
    objectId: string
  ): Promise<DatabaseCommand> {
    assertProfile(profile)
    this.assertOpen()
    const collection = this.collectionNames.get(objectId)
    if (!collection) {
      throw new Error('Refresh objects before previewing this MongoDB collection.')
    }
    return { engine: 'mongodb', kind: 'find', collection, text: '{}' }
  }

  async execute(
    profile: ConnectionProfile,
    command: DatabaseCommand,
    options: ExecuteOptions
  ): Promise<DatabaseResult> {
    assertProfile(profile)
    this.assertOpen()
    validateExecuteOptions(options)
    if (command.engine !== 'mongodb') {
      throw new Error('The selected MongoDB connection only accepts document queries.')
    }
    if (this.activeRequests.has(options.requestId)) {
      throw new Error('A MongoDB query with this request id is already running.')
    }
    if (this.cancelledRequestIds.delete(options.requestId)) {
      throw new Error('MongoDB query cancelled.')
    }

    const parsed = parseMongoInput(command.kind, command.text)
    if (command.kind === 'aggregate') assertReadOnlyPipeline(parsed as Document[])

    const controller = new AbortController()
    this.activeRequests.set(options.requestId, controller)
    let timedOut = false
    const timeout = setTimeout(() => {
      timedOut = true
      controller.abort()
    }, options.timeoutMs)
    timeout.unref?.()
    const startedAt = performance.now()
    try {
      const collection = this.client.db(this.databaseName).collection(command.collection)
      const cursor =
        command.kind === 'find'
          ? collection.find(parsed as Document, {
              limit: options.maxRows + 1,
              maxTimeMS: options.timeoutMs,
              signal: controller.signal
            })
          : collection.aggregate(parsed as Document[], {
              maxTimeMS: options.timeoutMs,
              signal: controller.signal
            })
      const rawDocuments = await cursor.limit(options.maxRows + 1).toArray()
      const documents: DocumentResult['documents'] = []
      let bytes = 0
      let truncated = rawDocuments.length > options.maxRows
      for (const document of rawDocuments.slice(0, options.maxRows)) {
        const wireDocument = documentToWire(document)
        const documentBytes = Buffer.byteLength(JSON.stringify(wireDocument), 'utf8')
        if (bytes + documentBytes > options.maxBytes) {
          truncated = true
          break
        }
        bytes += documentBytes
        documents.push(wireDocument)
      }
      return {
        kind: 'documents',
        documents,
        meta: {
          elapsedMs: Math.max(0, Math.round(performance.now() - startedAt)),
          count: documents.length,
          truncated,
          source: 'database'
        }
      }
    } catch (error) {
      if (timedOut) throw new Error('MongoDB query timed out.')
      throw safeMongoError(error, options.timeoutMs)
    } finally {
      clearTimeout(timeout)
      this.activeRequests.delete(options.requestId)
      this.cancelledRequestIds.delete(options.requestId)
    }
  }

  async applyDataChange(
    profile: ConnectionProfile,
    objectId: string,
    change: AdapterDataChange
  ): Promise<ApplyDataChangeResult> {
    assertProfile(profile)
    this.assertOpen()
    if (this.readOnly || profile.readOnly) {
      throw new Error('Document changes are disabled for read-only MongoDB connections.')
    }
    const collectionName = this.collectionNames.get(objectId)
    if (!collectionName) {
      throw new Error('Refresh objects before changing a document in this MongoDB collection.')
    }

    const original = dataRecordToBson(change.original, 'MongoDB original document')
    const collection = this.client.db(this.databaseName).collection(collectionName)
    if (change.action === 'update') {
      if (!change.current) {
        throw new Error('A MongoDB update requires the current document.')
      }
      const current = dataRecordToBson(change.current, 'MongoDB current document')
      const plan = planMongoUpdate({ original, current })
      try {
        const result = await collection.updateOne(plan.filter, plan.update, {
          upsert: false,
          maxTimeMS: DATA_CHANGE_MAX_TIME_MS
        })
        if (result.matchedCount === 0) throw concurrencyConflict()
        return { action: 'update', affected: 1 }
      } catch (error) {
        if (error instanceof MongoConcurrencyConflictError) throw error
        throw safeMongoDataChangeError(error)
      }
    }
    if (change.action === 'delete') {
      const filter = mongoDeleteFilter(original)
      try {
        const result = await collection.deleteOne(filter, {
          maxTimeMS: DATA_CHANGE_MAX_TIME_MS
        })
        if (result.deletedCount === 0) throw concurrencyConflict()
        return { action: 'delete', affected: 1 }
      } catch (error) {
        if (error instanceof MongoConcurrencyConflictError) throw error
        throw safeMongoDataChangeError(error)
      }
    }
    throw new Error('MongoDB document change action is invalid.')
  }

  async importData(
    profile: ConnectionProfile,
    objectId: string,
    source: ByteSource,
    options: ImportDataOptions
  ): Promise<ImportDataSummary> {
    assertProfile(profile)
    this.assertOpen()
    if (this.readOnly || profile.readOnly) {
      throw new Error('Import is disabled for read-only MongoDB connections.')
    }
    if (options.format !== 'jsonl') {
      throw new Error('MongoDB collection import supports JSON Lines files only.')
    }

    const collectionName = this.collectionNames.get(objectId)
    if (!collectionName) {
      throw new Error('Refresh objects before importing into this MongoDB collection.')
    }

    const collection = this.client.db(this.databaseName).collection(collectionName)
    try {
      const summary = await runJsonLinesImport(source, {
        signal: options.signal,
        onProgress: options.onProgress,
        errorMode: 'all-or-stop',
        async insertDocuments(documents, context) {
          context.signal?.throwIfAborted()
          let insertedCount = 0
          try {
            // The driver honors `signal` at runtime even though BulkWriteOptions
            // does not declare it, so a running batch can be cancelled.
            const insertOptions: BulkWriteOptions & Abortable = {
              ordered: true,
              signal: context.signal
            }
            const result = await collection.insertMany(documents as Document[], insertOptions)
            insertedCount = result.insertedCount
            context.signal?.throwIfAborted()
            return insertedCount
          } catch (error) {
            throw withInsertedCount(error, context.signal, insertedCount)
          }
        }
      })
      return {
        processed: summary.progress.processed,
        inserted: summary.progress.inserted,
        failed: summary.progress.failed
      }
    } catch (error) {
      throw safeMongoImportError(error)
    }
  }

  async cancel(requestId: string): Promise<void> {
    this.cancelledRequestIds.add(requestId)
    this.activeRequests.get(requestId)?.abort()
  }

  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    for (const controller of this.activeRequests.values()) controller.abort()
    this.activeRequests.clear()
    await this.client.close(true)
  }

  private assertOpen(): void {
    if (this.closed) throw new Error('MongoDB connection is closed.')
  }
}
