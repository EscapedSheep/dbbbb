export type DatabaseEngine = 'postgresql' | 'mongodb' | 'mysql' | 'sqlite'
/** Engines whose commands are SQL text returning column/row results. */
export type SqlDatabaseEngine = 'postgresql' | 'mysql' | 'sqlite'
export type ConnectionEnvironment = 'development' | 'staging' | 'production'

export interface ConnectionProfile {
  id: string
  name: string
  engine: DatabaseEngine
  endpoint: string
  database: string
  environment: ConnectionEnvironment
  readOnly: boolean
  demo: boolean
  saved?: boolean
  connected?: boolean
  storageWarning?: string
}

export type ConnectionDraft = Omit<
  ConnectionProfile,
  'id' | 'demo' | 'saved' | 'connected' | 'storageWarning'
>

export type PostgresSslMode = 'disable' | 'require' | 'verify-full'
export type MySqlSslMode = 'disable' | 'require' | 'verify-full'

interface BaseConnectionInput {
  name: string
  database: string
  environment: ConnectionEnvironment
  readOnly: boolean
  remember?: boolean
}

export interface PostgresConnectionInput extends BaseConnectionInput {
  engine: 'postgresql'
  host: string
  port: number
  username: string
  password: string
  sslMode: PostgresSslMode
}

export interface MongoConnectionInput extends BaseConnectionInput {
  engine: 'mongodb'
  uri: string
  username?: string
  password?: string
  tls: boolean
}

export interface MySqlConnectionInput extends BaseConnectionInput {
  engine: 'mysql'
  host: string
  port: number
  username: string
  password: string
  sslMode: MySqlSslMode
}

export interface SqliteConnectionInput extends BaseConnectionInput {
  engine: 'sqlite'
  filePath: string
}

export type ConnectionInput =
  | PostgresConnectionInput
  | MongoConnectionInput
  | MySqlConnectionInput
  | SqliteConnectionInput

export type DatabaseObjectKind =
  | 'database'
  | 'schema'
  | 'table'
  | 'view'
  | 'collection'

export interface DatabaseObjectNode {
  id: string
  name: string
  kind: DatabaseObjectKind
  parentId?: string
  detail?: string
}

export interface SqlCommand {
  engine: SqlDatabaseEngine
  kind: 'query'
  text: string
}

export interface MongoCommand {
  engine: 'mongodb'
  kind: 'find' | 'aggregate'
  collection: string
  text: string
}

export type DatabaseCommand = SqlCommand | MongoCommand

export interface ExecuteRequest {
  connectionId: string
  requestId: string
  command: DatabaseCommand
}

export interface CancelRequest {
  connectionId: string
  requestId: string
}

export interface PreviewRequest {
  connectionId: string
  objectId: string
}

/**
 * Wire contract for values crossing the IPC boundary between main and the
 * sandboxed renderer.
 *
 * Tagged objects: adapters mark values that need a type marker with a single
 * `$`-prefixed key. Two binary shapes are currently in use and consumers must
 * accept both: PostgreSQL emits the compact `{ $binary: '<base64>' }`, while
 * MongoDB emits canonical EJSON `{ $binary: { base64: '<base64>', subType: '<hex>' } }`.
 * SQLite `Uint8Array`/`Buffer` blobs cross as the compact `{ $binary: '<base64>' }`.
 *
 * Stringification rules: bigint, non-safe integers, non-finite numbers
 * (Infinity/NaN), and date/timestamp values cross the wire as strings.
 * PostgreSQL keeps the driver's raw text for date/timestamp/timestamptz so
 * edited values round-trip without host-timezone drift or microsecond loss.
 * MySQL is read with mysql2's `dateStrings: true` so DATE/DATETIME/TIMESTAMP
 * keep the server's raw text for the same round-trip reason, and DECIMAL and
 * BIGINT values are stringified to avoid precision loss. SQLite integers
 * returned as bigint are stringified; REAL and TEXT cross unchanged.
 */
export type WireScalar = string | number | boolean | null
export type WireValue = WireScalar | WireValue[] | { [key: string]: WireValue }

export interface ResultColumn {
  key: string
  label: string
  dataType: string
  align?: 'start' | 'center' | 'end'
}

export interface ResultMeta {
  elapsedMs: number
  /** Rows/documents returned in this result page, not the total match count. */
  count: number
  truncated: boolean
  source: 'demo' | 'database'
}

export interface RowResult {
  kind: 'rows'
  columns: ResultColumn[]
  rows: WireValue[][]
  meta: ResultMeta
}

export interface DocumentResult {
  kind: 'documents'
  documents: Array<Record<string, WireValue>>
  meta: ResultMeta
}

export type DatabaseResult = RowResult | DocumentResult

export type DataRecord = Record<string, WireValue>
export type DataChangeAction = 'update' | 'delete'

export interface ApplyDataChangeRequest {
  connectionId: string
  objectId: string
  engine: DatabaseEngine
  action: DataChangeAction
  original: DataRecord
  current?: DataRecord
}

export interface ApplyDataChangeResult {
  action: DataChangeAction
  affected: 1
}

export interface ExportResultRequest {
  result: DatabaseResult
  suggestedBaseName: string
}

export interface ExportResultResponse {
  canceled: boolean
  rows?: number
  bytes?: number
}

export type ImportFormat = 'csv' | 'jsonl'

export interface ChooseImportFileRequest {
  connectionId: string
  objectId: string
  format: ImportFormat
}

export interface ImportFileSelection {
  token: string
  name: string
  size: number
}

export interface StartImportRequest {
  token: string
  hasHeader: boolean
}

export interface ImportResult {
  processed: number
  inserted: number
  failed: number
}

export interface ImportProgressUpdate {
  token: string
  processed: number
  inserted: number
  failed: number
  bytes: number
  totalBytes: number
}

export interface DbbbbApi {
  listConnections: () => Promise<ConnectionProfile[]>
  getStartupWarnings: () => Promise<string[]>
  connect: (input: ConnectionInput) => Promise<ConnectionProfile>
  createDemoConnection: (draft: ConnectionDraft) => Promise<ConnectionProfile>
  disconnect: (connectionId: string) => Promise<void>
  forgetConnection: (connectionId: string) => Promise<void>
  listObjects: (connectionId: string) => Promise<DatabaseObjectNode[]>
  previewObject: (request: PreviewRequest) => Promise<DatabaseCommand>
  execute: (request: ExecuteRequest) => Promise<DatabaseResult>
  cancel: (request: CancelRequest) => Promise<void>
  applyDataChange: (request: ApplyDataChangeRequest) => Promise<ApplyDataChangeResult>
  exportResult: (request: ExportResultRequest) => Promise<ExportResultResponse>
  chooseImportFile: (request: ChooseImportFileRequest) => Promise<ImportFileSelection | undefined>
  startImport: (request: StartImportRequest) => Promise<ImportResult>
  cancelImport: (token: string) => Promise<void>
  onImportProgress: (listener: (update: ImportProgressUpdate) => void) => () => void
}

export const IPC_CHANNELS = {
  listConnections: 'database:list-connections',
  getStartupWarnings: 'database:get-startup-warnings',
  connect: 'database:connect',
  createDemoConnection: 'database:create-demo-connection',
  disconnect: 'database:disconnect',
  forgetConnection: 'database:forget-connection',
  listObjects: 'database:list-objects',
  previewObject: 'database:preview-object',
  execute: 'database:execute',
  cancel: 'database:cancel',
  applyDataChange: 'database:apply-data-change',
  exportResult: 'database:export-result',
  chooseImportFile: 'database:choose-import-file',
  startImport: 'database:start-import',
  cancelImport: 'database:cancel-import',
  importProgress: 'database:import-progress'
} as const

export const DEFAULT_QUERY: Record<DatabaseEngine, DatabaseCommand> = {
  postgresql: {
    engine: 'postgresql',
    kind: 'query',
    text: 'SELECT current_database() AS database,\n       current_user AS user,\n       now() AS connected_at;'
  },
  mongodb: {
    engine: 'mongodb',
    kind: 'find',
    collection: 'customers',
    text: '{}'
  },
  mysql: {
    engine: 'mysql',
    kind: 'query',
    text: 'SELECT DATABASE() AS `database`,\n       CURRENT_USER() AS `user`,\n       NOW() AS connected_at;'
  },
  sqlite: {
    engine: 'sqlite',
    kind: 'query',
    text: "SELECT sqlite_version() AS version,\n       datetime('now') AS connected_at;"
  }
}
