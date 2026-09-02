import { randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import {
  mkdir,
  open,
  rename,
  unlink
} from 'node:fs/promises'
import type { FileHandle } from 'node:fs/promises'
import {
  basename,
  dirname,
  join,
  resolve
} from 'node:path'
import { Buffer } from 'node:buffer'
import type {
  ConnectionInput,
  MongoConnectionInput,
  MySqlConnectionInput,
  PostgresConnectionInput,
  SqliteConnectionInput
} from '../../shared/database'

export interface Protector {
  readonly backend: string
  isAvailable(): boolean
  encrypt(plaintext: string): Uint8Array
  decrypt(ciphertext: Uint8Array): string
}

export type ConnectionVaultErrorCode =
  | 'PROTECTOR_UNAVAILABLE'
  | 'INVALID_ID'
  | 'INVALID_INPUT'
  | 'INVALID_FILE'
  | 'LIMIT_EXCEEDED'
  | 'ENCRYPTION_FAILED'
  | 'IO_ERROR'

export class ConnectionVaultError extends Error {
  readonly code: ConnectionVaultErrorCode

  constructor(code: ConnectionVaultErrorCode, message: string) {
    super(message)
    this.name = 'ConnectionVaultError'
    this.code = code
  }
}

export type ConnectionVaultWarningCode =
  | 'INVALID_RECORD'
  | 'DUPLICATE_ID'
  | 'DECRYPTION_FAILED'
  | 'INVALID_PAYLOAD'

export interface ConnectionVaultWarning {
  code: ConnectionVaultWarningCode
  recordNumber: number
  message: string
}

export interface ConnectionVaultEntry {
  id: string
  input: ConnectionInput
}

export interface ConnectionVaultLoadResult {
  entries: ConnectionVaultEntry[]
  warnings: ConnectionVaultWarning[]
}

interface StoredRecord {
  id: string
  ciphertext: string
}

interface StoredFile {
  version: 1
  records: StoredRecord[]
}

interface ParsedStoredRecord extends StoredRecord {
  recordNumber: number
}

interface ParsedStoredFile {
  records: ParsedStoredRecord[]
  warnings: ConnectionVaultWarning[]
}

const FILE_VERSION = 1
const FILE_MODE = 0o600
const DIRECTORY_MODE = 0o700
const MAX_FILE_BYTES = 8 * 1024 * 1024
const MAX_RECORDS = 1_000
const MAX_PLAINTEXT_BYTES = 16 * 1024
const MAX_CIPHERTEXT_BYTES = 64 * 1024
const MAX_BASE64_LENGTH = Math.ceil(MAX_CIPHERTEXT_BYTES / 3) * 4
const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/
const ENVIRONMENTS = new Set(['development', 'staging', 'production'])
const POSTGRES_SSL_MODES = new Set(['disable', 'require', 'verify-full'])
const MYSQL_SSL_MODES = new Set(['disable', 'require', 'verify-full'])
const pathQueues = new Map<string, Promise<void>>()

function vaultError(
  code: ConnectionVaultErrorCode,
  message: string
): ConnectionVaultError {
  return new ConnectionVaultError(code, message)
}

function isNodeError(error: unknown, code: string): boolean {
  return error instanceof Error && (error as NodeJS.ErrnoException).code === code
}

function validId(id: unknown): id is string {
  return typeof id === 'string' && ID_PATTERN.test(id)
}

function assertId(id: unknown): asserts id is string {
  if (!validId(id)) {
    throw vaultError('INVALID_ID', 'Connection vault id is invalid.')
  }
}

function dataProperties(value: unknown): Map<string, unknown> | undefined {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined
  const prototype = Object.getPrototypeOf(value)
  if (prototype !== Object.prototype && prototype !== null) return undefined

  const properties = new Map<string, unknown>()
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== 'string') return undefined
    const descriptor = Object.getOwnPropertyDescriptor(value, key)
    if (!descriptor?.enumerable || !('value' in descriptor)) return undefined
    properties.set(key, descriptor.value)
  }
  return properties
}

function hasExactKeys(
  properties: Map<string, unknown>,
  required: readonly string[],
  optional: readonly string[] = []
): boolean {
  const allowed = new Set([...required, ...optional])
  return required.every((key) => properties.has(key)) &&
    [...properties.keys()].every((key) => allowed.has(key))
}

function boundedText(
  properties: Map<string, unknown>,
  key: string,
  maximum: number,
  allowEmpty = false
): string {
  const value = properties.get(key)
  if (
    typeof value !== 'string' ||
    value.length > maximum ||
    (!allowEmpty && value.trim().length === 0)
  ) {
    throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
  }
  return value
}

function optionalBoundedText(
  properties: Map<string, unknown>,
  key: string,
  maximum: number,
  allowEmpty: boolean
): string | undefined {
  const value = properties.get(key)
  if (value === undefined) return undefined
  if (
    typeof value !== 'string' ||
    value.length > maximum ||
    (!allowEmpty && value.trim().length === 0)
  ) {
    throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
  }
  return value
}

function connectionBase(properties: Map<string, unknown>): {
  name: string
  database: string
  environment: 'development' | 'staging' | 'production'
  readOnly: boolean
} {
  const environment = properties.get('environment')
  const readOnly = properties.get('readOnly')
  if (!ENVIRONMENTS.has(environment as string) || typeof readOnly !== 'boolean') {
    throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
  }
  return {
    name: boundedText(properties, 'name', 80),
    database: boundedText(properties, 'database', 120),
    environment: environment as 'development' | 'staging' | 'production',
    readOnly
  }
}

function validateConnectionInput(value: unknown): ConnectionInput {
  const properties = dataProperties(value)
  if (!properties) throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
  const engine = properties.get('engine')
  const remember = properties.get('remember')
  if (remember !== undefined && typeof remember !== 'boolean') {
    throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
  }

  if (engine === 'postgresql') {
    const required = [
      'engine',
      'name',
      'database',
      'environment',
      'readOnly',
      'host',
      'port',
      'username',
      'password',
      'sslMode'
    ] as const
    if (!hasExactKeys(properties, required, ['remember'])) {
      throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
    }
    const port = properties.get('port')
    const sslMode = properties.get('sslMode')
    if (
      !Number.isInteger(port) ||
      Number(port) < 1 ||
      Number(port) > 65_535 ||
      !POSTGRES_SSL_MODES.has(sslMode as string)
    ) {
      throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
    }
    const input: PostgresConnectionInput = {
      ...connectionBase(properties),
      engine,
      host: boundedText(properties, 'host', 255),
      port: Number(port),
      username: boundedText(properties, 'username', 128),
      password: boundedText(properties, 'password', 4096, true),
      sslMode: sslMode as PostgresConnectionInput['sslMode']
    }
    return input
  }

  if (engine === 'mongodb') {
    const required = [
      'engine',
      'name',
      'database',
      'environment',
      'readOnly',
      'uri',
      'tls'
    ] as const
    if (!hasExactKeys(properties, required, ['username', 'password', 'remember'])) {
      throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
    }
    const uri = boundedText(properties, 'uri', 4096)
    const tls = properties.get('tls')
    if (
      (!uri.startsWith('mongodb://') && !uri.startsWith('mongodb+srv://')) ||
      typeof tls !== 'boolean'
    ) {
      throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
    }
    const username = optionalBoundedText(properties, 'username', 128, false)
    const password = optionalBoundedText(properties, 'password', 4096, true)
    const input: MongoConnectionInput = {
      ...connectionBase(properties),
      engine,
      uri,
      tls,
      ...(username === undefined ? {} : { username }),
      ...(password === undefined ? {} : { password })
    }
    return input
  }

  if (engine === 'mysql') {
    return validateMySqlInput(engine, properties)
  }

  if (engine === 'sqlite') {
    return validateSqliteInput(engine, properties)
  }

  throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
}

function validateMySqlInput(
  engine: 'mysql',
  properties: Map<string, unknown>
): MySqlConnectionInput {
  const required = [
    'engine',
    'name',
    'database',
    'environment',
    'readOnly',
    'host',
    'port',
    'username',
    'password',
    'sslMode'
  ] as const
  if (!hasExactKeys(properties, required, ['remember'])) {
    throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
  }
  const port = properties.get('port')
  const sslMode = properties.get('sslMode')
  if (
    !Number.isInteger(port) ||
    Number(port) < 1 ||
    Number(port) > 65_535 ||
    !MYSQL_SSL_MODES.has(sslMode as string)
  ) {
    throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
  }
  return {
    ...connectionBase(properties),
    engine,
    host: boundedText(properties, 'host', 255),
    port: Number(port),
    username: boundedText(properties, 'username', 128),
    password: boundedText(properties, 'password', 4096, true),
    sslMode: sslMode as MySqlConnectionInput['sslMode']
  }
}

function validateSqliteInput(
  engine: 'sqlite',
  properties: Map<string, unknown>
): SqliteConnectionInput {
  const required = [
    'engine',
    'name',
    'database',
    'environment',
    'readOnly',
    'filePath'
  ] as const
  if (!hasExactKeys(properties, required, ['remember'])) {
    throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
  }
  const filePath = boundedText(properties, 'filePath', 1024)
  if (filePath.includes('\0')) {
    throw vaultError('INVALID_INPUT', 'Connection data is invalid.')
  }
  return {
    ...connectionBase(properties),
    engine,
    filePath
  }
}

function strictBase64(value: unknown): Buffer | undefined {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    value.length > MAX_BASE64_LENGTH ||
    value.length % 4 !== 0 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)
  ) {
    return undefined
  }
  const decoded = Buffer.from(value, 'base64')
  if (
    decoded.length === 0 ||
    decoded.length > MAX_CIPHERTEXT_BYTES ||
    decoded.toString('base64') !== value
  ) {
    return undefined
  }
  return decoded
}

function warning(
  code: ConnectionVaultWarningCode,
  recordNumber: number,
  message: string
): ConnectionVaultWarning {
  return { code, recordNumber, message }
}

function parseStoredFile(contents: Buffer): ParsedStoredFile {
  if (contents.length > MAX_FILE_BYTES) {
    throw vaultError('LIMIT_EXCEEDED', 'Connection vault exceeds its size limit.')
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(contents.toString('utf8'))
  } catch {
    throw vaultError('INVALID_FILE', 'Connection vault file is invalid.')
  }
  const top = dataProperties(parsed)
  if (
    !top ||
    !hasExactKeys(top, ['version', 'records']) ||
    top.get('version') !== FILE_VERSION ||
    !Array.isArray(top.get('records'))
  ) {
    throw vaultError('INVALID_FILE', 'Connection vault file is invalid.')
  }
  const rawRecords = top.get('records') as unknown[]
  if (rawRecords.length > MAX_RECORDS) {
    throw vaultError('LIMIT_EXCEEDED', 'Connection vault contains too many records.')
  }

  const records: ParsedStoredRecord[] = []
  const warnings: ConnectionVaultWarning[] = []
  const ids = new Set<string>()
  for (let index = 0; index < rawRecords.length; index += 1) {
    const recordNumber = index + 1
    const properties = dataProperties(rawRecords[index])
    if (!properties || !hasExactKeys(properties, ['id', 'ciphertext'])) {
      warnings.push(warning('INVALID_RECORD', recordNumber, 'A vault record has an invalid shape.'))
      continue
    }
    const id = properties.get('id')
    const ciphertext = properties.get('ciphertext')
    if (!validId(id) || typeof ciphertext !== 'string' || !strictBase64(ciphertext)) {
      warnings.push(warning('INVALID_RECORD', recordNumber, 'A vault record is invalid.'))
      continue
    }
    if (ids.has(id)) {
      warnings.push(warning('DUPLICATE_ID', recordNumber, 'A duplicate vault record was ignored.'))
      continue
    }
    ids.add(id)
    records.push({ id, ciphertext, recordNumber })
  }
  return { records, warnings }
}

async function runExclusive<T>(path: string, operation: () => Promise<T>): Promise<T> {
  const previous = pathQueues.get(path) ?? Promise.resolve()
  const running = previous.catch(() => undefined).then(operation)
  const tail = running.then(() => undefined, () => undefined)
  pathQueues.set(path, tail)
  try {
    return await running
  } finally {
    if (pathQueues.get(path) === tail) pathQueues.delete(path)
  }
}

export class ConnectionVault {
  private readonly filePath: string

  constructor(
    filePath: string,
    private readonly protector: Protector
  ) {
    if (typeof filePath !== 'string' || filePath.length === 0) {
      throw vaultError('INVALID_FILE', 'Connection vault location is invalid.')
    }
    this.filePath = resolve(filePath)
  }

  get backend(): string {
    return this.protector.backend
  }

  async save(id: string, input: ConnectionInput): Promise<void> {
    assertId(id)
    const normalized = validateConnectionInput(input)
    await runExclusive(this.filePath, async () => {
      if (!this.protectorAvailable()) {
        throw vaultError(
          'PROTECTOR_UNAVAILABLE',
          'Secure connection storage is unavailable; credentials were not saved.'
        )
      }

      const plaintext = JSON.stringify(normalized)
      if (Buffer.byteLength(plaintext, 'utf8') > MAX_PLAINTEXT_BYTES) {
        throw vaultError('LIMIT_EXCEEDED', 'Connection data exceeds the vault record size limit.')
      }
      let encrypted: Uint8Array
      try {
        encrypted = this.protector.encrypt(plaintext)
      } catch {
        throw vaultError('ENCRYPTION_FAILED', 'Connection data could not be encrypted.')
      }
      if (!(encrypted instanceof Uint8Array) || encrypted.byteLength < 1) {
        throw vaultError('ENCRYPTION_FAILED', 'Connection data could not be encrypted.')
      }
      if (encrypted.byteLength > MAX_CIPHERTEXT_BYTES) {
        throw vaultError('LIMIT_EXCEEDED', 'Encrypted connection data exceeds the record size limit.')
      }

      const stored = await this.readStoredFile()
      const next: StoredRecord[] = stored.records.map(({ id: storedId, ciphertext }) => ({
        id: storedId,
        ciphertext
      }))
      const replacement = { id, ciphertext: Buffer.from(encrypted).toString('base64') }
      const existingIndex = next.findIndex((record) => record.id === id)
      if (existingIndex === -1) next.push(replacement)
      else next[existingIndex] = replacement
      await this.writeStoredFile(next)
    })
  }

  async load(): Promise<ConnectionVaultLoadResult> {
    return runExclusive(this.filePath, async () => {
      const stored = await this.readStoredFile()
      if (stored.records.length === 0) {
        return { entries: [], warnings: stored.warnings }
      }
      if (!this.protectorAvailable()) {
        throw vaultError(
          'PROTECTOR_UNAVAILABLE',
          'Secure connection storage is unavailable; saved credentials could not be loaded.'
        )
      }

      const entries: ConnectionVaultEntry[] = []
      const warnings = [...stored.warnings]
      for (let index = 0; index < stored.records.length; index += 1) {
        const record = stored.records[index]
        const decoded = strictBase64(record.ciphertext)
        if (!decoded) {
          warnings.push(warning('INVALID_RECORD', record.recordNumber, 'A vault record is invalid.'))
          continue
        }
        let plaintext: string
        try {
          plaintext = this.protector.decrypt(decoded)
        } catch {
          warnings.push(warning(
            'DECRYPTION_FAILED',
            record.recordNumber,
            'A saved connection could not be decrypted and was skipped.'
          ))
          continue
        }
        if (
          typeof plaintext !== 'string' ||
          Buffer.byteLength(plaintext, 'utf8') > MAX_PLAINTEXT_BYTES
        ) {
          warnings.push(warning(
            'INVALID_PAYLOAD',
            record.recordNumber,
            'A decrypted connection record is invalid and was skipped.'
          ))
          continue
        }
        try {
          entries.push({ id: record.id, input: validateConnectionInput(JSON.parse(plaintext)) })
        } catch {
          warnings.push(warning(
            'INVALID_PAYLOAD',
            record.recordNumber,
            'A decrypted connection record is invalid and was skipped.'
          ))
        }
      }
      warnings.sort((left, right) => left.recordNumber - right.recordNumber)
      return { entries, warnings }
    })
  }

  async remove(id: string): Promise<boolean> {
    assertId(id)
    return runExclusive(this.filePath, async () => {
      const stored = await this.readStoredFile()
      const next: StoredRecord[] = stored.records
        .filter((record) => record.id !== id)
        .map(({ id: storedId, ciphertext }) => ({ id: storedId, ciphertext }))
      if (next.length === stored.records.length) return false
      await this.writeStoredFile(next)
      return true
    })
  }

  async clear(): Promise<void> {
    await runExclusive(this.filePath, () => this.writeStoredFile([]))
  }

  private protectorAvailable(): boolean {
    try {
      return this.protector.isAvailable() === true
    } catch {
      return false
    }
  }

  private async readStoredFile(): Promise<ParsedStoredFile> {
    let handle: FileHandle | undefined
    try {
      const noFollow = 'O_NOFOLLOW' in constants ? constants.O_NOFOLLOW : 0
      handle = await open(this.filePath, constants.O_RDONLY | noFollow)
      const stats = await handle.stat()
      if (!stats.isFile()) {
        throw vaultError('INVALID_FILE', 'Connection vault file is invalid.')
      }
      if (stats.size > MAX_FILE_BYTES) {
        throw vaultError('LIMIT_EXCEEDED', 'Connection vault exceeds its size limit.')
      }
      const contents = await handle.readFile()
      return parseStoredFile(contents)
    } catch (error) {
      if (isNodeError(error, 'ENOENT')) return { records: [], warnings: [] }
      if (error instanceof ConnectionVaultError) throw error
      throw vaultError('IO_ERROR', 'Connection vault could not be read.')
    } finally {
      await handle?.close().catch(() => undefined)
    }
  }

  private async writeStoredFile(records: StoredRecord[]): Promise<void> {
    if (records.length > MAX_RECORDS) {
      throw vaultError('LIMIT_EXCEEDED', 'Connection vault contains too many records.')
    }
    const stored: StoredFile = { version: FILE_VERSION, records }
    const contents = Buffer.from(JSON.stringify(stored), 'utf8')
    if (contents.length > MAX_FILE_BYTES) {
      throw vaultError('LIMIT_EXCEEDED', 'Connection vault exceeds its size limit.')
    }

    const directory = dirname(this.filePath)
    const temporaryPath = join(
      directory,
      `.${basename(this.filePath)}.${process.pid}.${randomUUID()}.tmp`
    )
    let handle: FileHandle | undefined
    try {
      await mkdir(directory, { recursive: true, mode: DIRECTORY_MODE })
      handle = await open(
        temporaryPath,
        constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL,
        FILE_MODE
      )
      await handle.writeFile(contents)
      await handle.sync()
      await handle.chmod(FILE_MODE)
      await handle.close()
      handle = undefined
      await rename(temporaryPath, this.filePath)
    } catch (error) {
      await handle?.close().catch(() => undefined)
      await unlink(temporaryPath).catch(() => undefined)
      if (error instanceof ConnectionVaultError) throw error
      throw vaultError('IO_ERROR', 'Connection vault could not be written.')
    }
  }
}
