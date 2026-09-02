import type { BrowserWindow, IpcMainInvokeEvent } from 'electron'
import { ipcMain } from 'electron'
import type {
  ApplyDataChangeRequest,
  CancelRequest,
  ChooseImportFileRequest,
  ConnectionDraft,
  ConnectionEnvironment,
  ConnectionInput,
  DataRecord,
  DatabaseEngine,
  ExecuteRequest,
  ImportProgressUpdate,
  MongoCommand,
  MySqlSslMode,
  PostgresSslMode,
  PreviewRequest,
  SqlCommand,
  StartImportRequest,
  WireValue
} from '../shared/database'
import { IPC_CHANNELS } from '../shared/database'
import type { DatabaseService } from './database-service'
import {
  parseExportResultRequest,
  showResultExportDialog
} from './transfers/result-export-service'
import { ImportCoordinator } from './transfers/import-coordinator'

const engines = new Set<DatabaseEngine>(['postgresql', 'mongodb', 'mysql', 'sqlite'])
const demoEngines = new Set<DatabaseEngine>(['postgresql', 'mongodb'])
const environments = new Set<ConnectionEnvironment>(['development', 'staging', 'production'])
const postgresSslModes = new Set<PostgresSslMode>(['disable', 'require', 'verify-full'])
const mySqlSslModes = new Set<MySqlSslMode>(['disable', 'require', 'verify-full'])
const dangerousRecordKeys = new Set(['__proto__', 'constructor', 'prototype'])
const MAX_CHANGE_DEPTH = 32
const MAX_CHANGE_NODES = 100_000
const MAX_CHANGE_TEXT = 5 * 1024 * 1024

interface ChangePayloadBudget {
  nodes: number
  text: number
}

function assertTrustedSender(event: IpcMainInvokeEvent, getWindow: () => BrowserWindow | null): void {
  let trusted = false
  try {
    const window = getWindow()
    trusted = Boolean(
      window &&
      !window.isDestroyed() &&
      !window.webContents.isDestroyed() &&
      event.sender === window.webContents &&
      event.senderFrame === window.webContents.mainFrame
    )
  } catch {
    trusted = false
  }
  if (!trusted) {
    throw new Error('Rejected IPC request from an unknown renderer.')
  }
}

function importProgressPublisher(
  event: IpcMainInvokeEvent,
  getWindow: () => BrowserWindow | null
): (update: ImportProgressUpdate) => void {
  const sender = event.sender
  const senderFrame = event.senderFrame
  return (update) => {
    try {
      const window = getWindow()
      if (
        !window ||
        window.isDestroyed() ||
        window.webContents !== sender ||
        window.webContents.mainFrame !== senderFrame ||
        sender.isDestroyed()
      ) {
        return
      }
      sender.send(IPC_CHANNELS.importProgress, update)
    } catch {
      // Renderer progress is best-effort; a closed window must not fail an import batch.
    }
  }
}

function objectPayload(value: unknown, message: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(message)
  }
  return value as Record<string, unknown>
}

function boundedString(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > maxLength) {
    throw new Error(`${field} is invalid.`)
  }
  return value.trim()
}

function boundedSecret(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.length > 4096) {
    throw new Error(`${field} is invalid.`)
  }
  return value
}

function optionalBoundedString(value: unknown, field: string, maxLength: number): string | undefined {
  if (value === undefined || value === '') return undefined
  return boundedString(value, field, maxLength)
}

function parseEnvironment(value: unknown): ConnectionEnvironment {
  if (!environments.has(value as ConnectionEnvironment)) {
    throw new Error('Connection environment is invalid.')
  }
  return value as ConnectionEnvironment
}

function parseReadOnly(value: unknown): boolean {
  if (typeof value !== 'boolean') {
    throw new Error('Read-only state is invalid.')
  }
  return value
}

function parseRemember(value: unknown): boolean | undefined {
  if (value === undefined) return undefined
  if (typeof value !== 'boolean') {
    throw new Error('Remember connection setting is invalid.')
  }
  return value
}

function parseConnectionDraft(value: unknown): ConnectionDraft {
  const candidate = objectPayload(value, 'Connection payload is invalid.')
  if (!demoEngines.has(candidate.engine as DatabaseEngine)) {
    throw new Error('Database engine is invalid.')
  }

  return {
    name: boundedString(candidate.name, 'Connection name', 80),
    engine: candidate.engine as DatabaseEngine,
    endpoint: boundedString(candidate.endpoint, 'Endpoint', 240),
    database: boundedString(candidate.database, 'Database', 120),
    environment: parseEnvironment(candidate.environment),
    readOnly: parseReadOnly(candidate.readOnly)
  }
}

function parseConnectionInput(value: unknown): ConnectionInput {
  const candidate = objectPayload(value, 'Connection payload is invalid.')
  const engine = candidate.engine
  const base = {
    name: boundedString(candidate.name, 'Connection name', 80),
    database: boundedString(candidate.database, 'Database', 120),
    environment: parseEnvironment(candidate.environment),
    readOnly: parseReadOnly(candidate.readOnly),
    ...(candidate.remember === undefined ? {} : { remember: parseRemember(candidate.remember) })
  }

  if (engine === 'postgresql') {
    const port = candidate.port
    if (!Number.isInteger(port) || Number(port) < 1 || Number(port) > 65_535) {
      throw new Error('PostgreSQL port is invalid.')
    }
    if (!postgresSslModes.has(candidate.sslMode as PostgresSslMode)) {
      throw new Error('PostgreSQL SSL mode is invalid.')
    }
    return {
      ...base,
      engine,
      host: boundedString(candidate.host, 'PostgreSQL host', 255),
      port: Number(port),
      username: boundedString(candidate.username, 'PostgreSQL username', 128),
      password: boundedSecret(candidate.password, 'PostgreSQL password'),
      sslMode: candidate.sslMode as PostgresSslMode
    }
  }

  if (engine === 'mongodb') {
    const uri = boundedString(candidate.uri, 'MongoDB URI', 4096)
    if (!uri.startsWith('mongodb://') && !uri.startsWith('mongodb+srv://')) {
      throw new Error('MongoDB URI must start with mongodb:// or mongodb+srv://.')
    }
    if (typeof candidate.tls !== 'boolean') {
      throw new Error('MongoDB TLS state is invalid.')
    }
    return {
      ...base,
      engine,
      uri,
      username: optionalBoundedString(candidate.username, 'MongoDB username', 128),
      password:
        candidate.password === undefined ? undefined : boundedSecret(candidate.password, 'MongoDB password'),
      tls: candidate.tls
    }
  }

  if (engine === 'mysql') {
    const port = candidate.port
    if (!Number.isInteger(port) || Number(port) < 1 || Number(port) > 65_535) {
      throw new Error('MySQL port is invalid.')
    }
    if (!mySqlSslModes.has(candidate.sslMode as MySqlSslMode)) {
      throw new Error('MySQL SSL mode is invalid.')
    }
    return {
      ...base,
      engine,
      host: boundedString(candidate.host, 'MySQL host', 255),
      port: Number(port),
      username: boundedString(candidate.username, 'MySQL username', 128),
      password: boundedSecret(candidate.password, 'MySQL password'),
      sslMode: candidate.sslMode as MySqlSslMode
    }
  }

  if (engine === 'sqlite') {
    const filePath = boundedString(candidate.filePath, 'SQLite file path', 1024)
    if (filePath.includes('\0')) {
      throw new Error('SQLite file path is invalid.')
    }
    return {
      ...base,
      engine,
      filePath
    }
  }

  throw new Error('Database engine is invalid.')
}

function parseConnectionId(value: unknown): string {
  const id = boundedString(value, 'Connection id', 128)
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(id)) {
    throw new Error('Connection id is invalid.')
  }
  return id
}

function parseRequestId(value: unknown): string {
  return boundedString(value, 'Request id', 128)
}

function parseExecuteRequest(value: unknown): ExecuteRequest {
  const candidate = objectPayload(value, 'Query payload is invalid.')
  const connectionId = parseConnectionId(candidate.connectionId)
  const requestId = parseRequestId(candidate.requestId)
  const rawCommand = objectPayload(candidate.command, 'Query command is invalid.')
  const text = rawCommand.text
  if (typeof text !== 'string' || text.trim().length === 0 || text.length > 100_000) {
    throw new Error('Query command is invalid.')
  }

  let command: SqlCommand | MongoCommand
  if (
    (rawCommand.engine === 'postgresql' ||
      rawCommand.engine === 'mysql' ||
      rawCommand.engine === 'sqlite') &&
    rawCommand.kind === 'query'
  ) {
    command = { engine: rawCommand.engine, kind: 'query', text }
  } else if (
    rawCommand.engine === 'mongodb' &&
    (rawCommand.kind === 'find' || rawCommand.kind === 'aggregate')
  ) {
    command = {
      engine: 'mongodb',
      kind: rawCommand.kind,
      collection: boundedString(rawCommand.collection, 'MongoDB collection', 255),
      text
    }
  } else {
    throw new Error('Query command is invalid.')
  }
  return { connectionId, requestId, command }
}

function parsePreviewRequest(value: unknown): PreviewRequest {
  const candidate = objectPayload(value, 'Preview payload is invalid.')
  return {
    connectionId: parseConnectionId(candidate.connectionId),
    objectId: boundedString(candidate.objectId, 'Object id', 512)
  }
}

function parseCancelRequest(value: unknown): CancelRequest {
  const candidate = objectPayload(value, 'Cancel payload is invalid.')
  return {
    connectionId: parseConnectionId(candidate.connectionId),
    requestId: parseRequestId(candidate.requestId)
  }
}

function parseWireValue(
  value: unknown,
  budget: ChangePayloadBudget,
  depth = 0
): WireValue {
  budget.nodes += 1
  if (budget.nodes > MAX_CHANGE_NODES || depth > MAX_CHANGE_DEPTH) {
    throw new Error('Record change payload is too complex.')
  }
  if (value === null || typeof value === 'boolean') return value
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value))) {
      throw new Error('Record change contains an invalid number.')
    }
    return value
  }
  if (typeof value === 'string') {
    budget.text += value.length
    if (budget.text > MAX_CHANGE_TEXT) throw new Error('Record change payload is too large.')
    return value
  }
  if (Array.isArray(value)) {
    return value.map((item) => parseWireValue(item, budget, depth + 1))
  }
  if (!value || typeof value !== 'object') {
    throw new Error('Record change contains an unsupported value.')
  }

  const output = Object.create(null) as Record<string, WireValue>
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== 'string' || dangerousRecordKeys.has(key) || key.includes('\0')) {
      throw new Error('Record change contains an unsafe field name.')
    }
    budget.text += key.length
    if (budget.text > MAX_CHANGE_TEXT) throw new Error('Record change payload is too large.')
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    if (!descriptor?.enumerable || !('value' in descriptor)) {
      throw new Error('Record change must contain data properties only.')
    }
    Object.defineProperty(output, key, {
      configurable: true,
      enumerable: true,
      writable: true,
      value: parseWireValue(descriptor.value, budget, depth + 1)
    })
  }
  return output
}

function parseDataRecord(value: unknown, budget: ChangePayloadBudget): DataRecord {
  const parsed = parseWireValue(value, budget)
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Record change must contain one object.')
  }
  if (Object.keys(parsed).length === 0) {
    throw new Error('Record change cannot be empty.')
  }
  return parsed
}

export function parseApplyDataChangeRequest(value: unknown): ApplyDataChangeRequest {
  const candidate = objectPayload(value, 'Record change payload is invalid.')
  if (!engines.has(candidate.engine as DatabaseEngine)) {
    throw new Error('Record change engine is invalid.')
  }
  if (candidate.action !== 'update' && candidate.action !== 'delete') {
    throw new Error('Record change action is invalid.')
  }
  const budget: ChangePayloadBudget = { nodes: 0, text: 0 }
  const original = parseDataRecord(candidate.original, budget)
  const current = candidate.action === 'update'
    ? parseDataRecord(candidate.current, budget)
    : undefined
  if (candidate.action === 'delete' && candidate.current !== undefined) {
    throw new Error('Delete changes cannot include a current record.')
  }
  return {
    connectionId: parseConnectionId(candidate.connectionId),
    objectId: boundedString(candidate.objectId, 'Object id', 512),
    engine: candidate.engine as DatabaseEngine,
    action: candidate.action,
    original,
    current
  }
}

function parseChooseImportFileRequest(value: unknown): ChooseImportFileRequest {
  const candidate = objectPayload(value, 'Import file payload is invalid.')
  if (candidate.format !== 'csv' && candidate.format !== 'jsonl') {
    throw new Error('Import format is invalid.')
  }
  return {
    connectionId: parseConnectionId(candidate.connectionId),
    objectId: boundedString(candidate.objectId, 'Object id', 512),
    format: candidate.format
  }
}

function parseStartImportRequest(value: unknown): StartImportRequest {
  const candidate = objectPayload(value, 'Start import payload is invalid.')
  if (typeof candidate.hasHeader !== 'boolean') {
    throw new Error('CSV header setting is invalid.')
  }
  return {
    token: boundedString(candidate.token, 'Import token', 128),
    hasHeader: candidate.hasHeader
  }
}

export function registerDatabaseIpc(
  service: DatabaseService,
  getWindow: () => BrowserWindow | null
): () => void {
  const importCoordinator = new ImportCoordinator(service)
  ipcMain.handle(IPC_CHANNELS.listConnections, (event) => {
    assertTrustedSender(event, getWindow)
    return service.listConnections()
  })

  ipcMain.handle(IPC_CHANNELS.getStartupWarnings, (event, ...payload: unknown[]) => {
    assertTrustedSender(event, getWindow)
    if (payload.length !== 0) throw new Error('Startup warnings request is invalid.')
    return service.getStartupWarnings()
  })

  ipcMain.handle(IPC_CHANNELS.connect, (event, payload: unknown) => {
    assertTrustedSender(event, getWindow)
    return service.connect(parseConnectionInput(payload))
  })

  ipcMain.handle(IPC_CHANNELS.createDemoConnection, (event, payload: unknown) => {
    assertTrustedSender(event, getWindow)
    return service.createDemoConnection(parseConnectionDraft(payload))
  })

  ipcMain.handle(IPC_CHANNELS.disconnect, (event, connectionId: unknown) => {
    assertTrustedSender(event, getWindow)
    return service.disconnect(parseConnectionId(connectionId))
  })

  ipcMain.handle(
    IPC_CHANNELS.forgetConnection,
    (event, connectionId: unknown, ...extra: unknown[]) => {
      assertTrustedSender(event, getWindow)
      if (extra.length !== 0) throw new Error('Forget connection request is invalid.')
      return service.forgetConnection(parseConnectionId(connectionId))
    }
  )

  ipcMain.handle(IPC_CHANNELS.listObjects, (event, connectionId: unknown) => {
    assertTrustedSender(event, getWindow)
    return service.listObjects(parseConnectionId(connectionId))
  })

  ipcMain.handle(IPC_CHANNELS.previewObject, (event, payload: unknown) => {
    assertTrustedSender(event, getWindow)
    const request = parsePreviewRequest(payload)
    return service.previewObject(request.connectionId, request.objectId)
  })

  ipcMain.handle(IPC_CHANNELS.execute, (event, payload: unknown) => {
    assertTrustedSender(event, getWindow)
    const request = parseExecuteRequest(payload)
    return service.execute(request.connectionId, request.requestId, request.command)
  })

  ipcMain.handle(IPC_CHANNELS.cancel, (event, payload: unknown) => {
    assertTrustedSender(event, getWindow)
    const request = parseCancelRequest(payload)
    return service.cancel(request.connectionId, request.requestId)
  })

  ipcMain.handle(IPC_CHANNELS.applyDataChange, (event, payload: unknown) => {
    assertTrustedSender(event, getWindow)
    const request = parseApplyDataChangeRequest(payload)
    return service.applyDataChange(
      request.connectionId,
      request.objectId,
      request.engine,
      {
        action: request.action,
        original: request.original,
        current: request.current
      }
    )
  })

  ipcMain.handle(IPC_CHANNELS.exportResult, (event, payload: unknown) => {
    assertTrustedSender(event, getWindow)
    const window = getWindow()
    if (!window) throw new Error('The application window is no longer available.')
    return showResultExportDialog(window, parseExportResultRequest(payload))
  })

  ipcMain.handle(IPC_CHANNELS.chooseImportFile, (event, payload: unknown) => {
    assertTrustedSender(event, getWindow)
    const window = getWindow()
    if (!window) throw new Error('The application window is no longer available.')
    return importCoordinator.chooseFile(
      window,
      parseChooseImportFileRequest(payload),
      importProgressPublisher(event, getWindow)
    )
  })

  ipcMain.handle(IPC_CHANNELS.startImport, (event, payload: unknown) => {
    assertTrustedSender(event, getWindow)
    return importCoordinator.start(parseStartImportRequest(payload))
  })

  ipcMain.handle(IPC_CHANNELS.cancelImport, (event, token: unknown) => {
    assertTrustedSender(event, getWindow)
    importCoordinator.cancel(boundedString(token, 'Import token', 128))
  })

  let closed = false
  return () => {
    if (closed) return
    closed = true
    importCoordinator.close()
    for (const channel of Object.values(IPC_CHANNELS)) {
      if (channel !== IPC_CHANNELS.importProgress) ipcMain.removeHandler(channel)
    }
  }
}
