// @vitest-environment node
import { Buffer } from 'node:buffer'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  mkdtemp,
  readFile,
  readdir,
  rm,
  stat,
  writeFile
} from 'node:fs/promises'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  MongoConnectionInput,
  MySqlConnectionInput,
  PostgresConnectionInput,
  SqliteConnectionInput
} from '../../shared/database'
import {
  ConnectionVault,
  ConnectionVaultError
} from './connection-vault'
import type { Protector } from './connection-vault'

const PROTECTOR_HEADER = Buffer.from('dbbbb-test-v1\0', 'utf8')

class XorProtector implements Protector {
  readonly backend = 'test-xor'

  isAvailable(): boolean {
    return true
  }

  encrypt(plaintext: string): Uint8Array {
    const input = Buffer.from(plaintext, 'utf8')
    const output = Buffer.alloc(PROTECTOR_HEADER.length + input.length)
    PROTECTOR_HEADER.copy(output)
    for (let index = 0; index < input.length; index += 1) {
      output[PROTECTOR_HEADER.length + index] = input[index] ^ 0xa5
    }
    return output
  }

  decrypt(ciphertext: Uint8Array): string {
    const input = Buffer.from(ciphertext)
    if (
      input.length <= PROTECTOR_HEADER.length ||
      !input.subarray(0, PROTECTOR_HEADER.length).equals(PROTECTOR_HEADER)
    ) {
      throw new Error('test ciphertext is invalid')
    }
    const output = Buffer.alloc(input.length - PROTECTOR_HEADER.length)
    for (let index = 0; index < output.length; index += 1) {
      output[index] = input[PROTECTOR_HEADER.length + index] ^ 0xa5
    }
    return output.toString('utf8')
  }
}

const postgresInput: PostgresConnectionInput = {
  engine: 'postgresql',
  name: 'Local PostgreSQL',
  database: 'dbbbb',
  environment: 'development',
  readOnly: false,
  host: '127.0.0.1',
  port: 5432,
  username: 'dbbbb_user',
  password: 'POSTGRES_TOP_SECRET',
  sslMode: 'require'
}

const mongoInput: MongoConnectionInput = {
  engine: 'mongodb',
  name: 'Mongo production',
  database: 'app',
  environment: 'production',
  readOnly: true,
  uri: 'mongodb://uri_user:URI_TOP_SECRET@mongo.internal:27017/app?authSource=admin',
  username: 'separate_user',
  password: 'MONGO_TOP_SECRET',
  tls: true
}

const mysqlInput: MySqlConnectionInput = {
  engine: 'mysql',
  name: 'MySQL staging',
  database: 'shop',
  environment: 'staging',
  readOnly: true,
  host: 'mysql.internal',
  port: 3306,
  username: 'shop_user',
  password: 'MYSQL_TOP_SECRET',
  sslMode: 'verify-full'
}

const sqliteInput: SqliteConnectionInput = {
  engine: 'sqlite',
  name: 'Local SQLite',
  database: 'main',
  environment: 'development',
  readOnly: false,
  filePath: '/Users/tester/data/local.db'
}

describe('ConnectionVault', () => {
  let directory: string
  let filePath: string
  let protector: XorProtector

  beforeEach(async () => {
    directory = await mkdtemp(join(tmpdir(), 'dbbbb-vault-test-'))
    filePath = join(directory, 'connections.vault.json')
    protector = new XorProtector()
  })

  afterEach(async () => {
    await rm(directory, { recursive: true, force: true })
  })

  it('roundtrips both engines while storing only versioned base64 ciphertext with 0600 mode', async () => {
    const vault = new ConnectionVault(filePath, protector)
    expect(vault.backend).toBe('test-xor')

    await vault.save('postgres-main', postgresInput)
    await vault.save('mongo-prod', mongoInput)

    const disk = await readFile(filePath, 'utf8')
    expect(disk).not.toContain(postgresInput.password)
    expect(disk).not.toContain(mongoInput.password)
    expect(disk).not.toContain(mongoInput.uri)
    expect(disk).not.toContain('URI_TOP_SECRET')
    expect(disk).not.toContain('uri_user')
    expect(disk).not.toContain('separate_user')
    expect(JSON.parse(disk)).toEqual({
      version: 1,
      records: [
        { id: 'postgres-main', ciphertext: expect.stringMatching(/^[A-Za-z0-9+/]+={0,2}$/) },
        { id: 'mongo-prod', ciphertext: expect.stringMatching(/^[A-Za-z0-9+/]+={0,2}$/) }
      ]
    })
    if (process.platform !== 'win32') {
      expect((await stat(filePath)).mode & 0o777).toBe(0o600)
    }

    await expect(vault.load()).resolves.toEqual({
      entries: [
        { id: 'postgres-main', input: postgresInput },
        { id: 'mongo-prod', input: mongoInput }
      ],
      warnings: []
    })
  })

  it('roundtrips MySQL and SQLite records with the same at-rest encryption semantics', async () => {
    const vault = new ConnectionVault(filePath, protector)

    await vault.save('mysql-staging', mysqlInput)
    await vault.save('sqlite-local', sqliteInput)

    const disk = await readFile(filePath, 'utf8')
    expect(disk).not.toContain(mysqlInput.password)
    expect(disk).not.toContain(mysqlInput.username)
    expect(disk).not.toContain(sqliteInput.filePath)
    await expect(vault.load()).resolves.toEqual({
      entries: [
        { id: 'mysql-staging', input: mysqlInput },
        { id: 'sqlite-local', input: sqliteInput }
      ],
      warnings: []
    })
  })

  it('rejects strict-schema violations for MySQL and SQLite without leaking values', async () => {
    const vault = new ConnectionVault(filePath, protector)

    await expect(vault.save('mysql-bad-ssl', {
      ...mysqlInput,
      sslMode: 'prefer'
    } as unknown as MySqlConnectionInput)).rejects.toMatchObject({ code: 'INVALID_INPUT' })
    await expect(vault.save('mysql-bad-port', {
      ...mysqlInput,
      port: 0
    })).rejects.toMatchObject({ code: 'INVALID_INPUT' })
    await expect(vault.save('mysql-extra-key', {
      ...mysqlInput,
      uri: 'PRIVATE_EXTRA'
    } as unknown as MySqlConnectionInput)).rejects.toMatchObject({ code: 'INVALID_INPUT' })
    await expect(vault.save('sqlite-empty-path', {
      ...sqliteInput,
      filePath: '   '
    })).rejects.toMatchObject({ code: 'INVALID_INPUT' })
    await expect(vault.save('sqlite-nul-path', {
      ...sqliteInput,
      filePath: 'data/local\0.db'
    })).rejects.toMatchObject({ code: 'INVALID_INPUT' })

    await expect(readFile(filePath)).rejects.toMatchObject({ code: 'ENOENT' })
  })

  it('serializes concurrent writes across vault instances and upserts duplicate ids', async () => {
    const firstVault = new ConnectionVault(filePath, protector)
    const secondVault = new ConnectionVault(filePath, protector)
    const first = { ...postgresInput, password: 'first-value' }
    const last = { ...postgresInput, password: 'last-value' }

    await Promise.all([
      firstVault.save('same-id', first),
      secondVault.save('mongo-id', mongoInput),
      firstVault.save('same-id', last)
    ])

    const loaded = await secondVault.load()
    expect(loaded.entries).toHaveLength(2)
    expect(loaded.entries.find((entry) => entry.id === 'same-id')?.input).toEqual(last)
    expect(loaded.entries.find((entry) => entry.id === 'mongo-id')?.input).toEqual(mongoInput)
    expect((await readdir(directory)).filter((name) => name.includes('.tmp'))).toEqual([])
  })

  it('validates and strips the transient remember intent before encryption', async () => {
    const vault = new ConnectionVault(filePath, protector)
    await vault.save('remembered-id', { ...postgresInput, remember: true })

    const loaded = await vault.load()
    expect(loaded.entries).toEqual([{ id: 'remembered-id', input: postgresInput }])
    expect(loaded.entries[0].input).not.toHaveProperty('remember')

    await expect(vault.save('invalid-remember', {
      ...postgresInput,
      remember: 'yes'
    } as unknown as PostgresConnectionInput)).rejects.toMatchObject({ code: 'INVALID_INPUT' })
  })

  it('removes one idempotently and clears through the same atomic file format', async () => {
    const vault = new ConnectionVault(filePath, protector)
    await vault.save('postgres-main', postgresInput)
    await vault.save('mongo-prod', mongoInput)

    await expect(vault.remove('missing-id')).resolves.toBe(false)
    await expect(vault.remove('postgres-main')).resolves.toBe(true)
    await expect(vault.load()).resolves.toMatchObject({
      entries: [{ id: 'mongo-prod', input: mongoInput }],
      warnings: []
    })

    await vault.clear()
    await expect(vault.load()).resolves.toEqual({ entries: [], warnings: [] })
    expect(JSON.parse(await readFile(filePath, 'utf8'))).toEqual({ version: 1, records: [] })
  })

  it('never falls back to plaintext when the protector is unavailable', async () => {
    const encrypt = vi.fn(() => Buffer.from('should not run'))
    const unavailable: Protector = {
      backend: 'unavailable-test',
      isAvailable: () => false,
      encrypt,
      decrypt: () => {
        throw new Error('should not run')
      }
    }
    const vault = new ConnectionVault(filePath, unavailable)
    const failure = vault.save('postgres-main', postgresInput)

    await expect(failure).rejects.toMatchObject({
      code: 'PROTECTOR_UNAVAILABLE'
    })
    await expect(failure).rejects.toSatisfy((error: Error) =>
      !error.message.includes(postgresInput.password) &&
      !error.message.includes(directory)
    )
    expect(encrypt).not.toHaveBeenCalled()
    await expect(readFile(filePath)).rejects.toMatchObject({ code: 'ENOENT' })
  })

  it('isolates malformed, duplicate, undecryptable, and invalid-payload records', async () => {
    const encryptText = (text: string): string =>
      Buffer.from(protector.encrypt(text)).toString('base64')
    const goodCiphertext = encryptText(JSON.stringify(postgresInput))
    const otherInput = { ...postgresInput, name: 'Other', password: 'OTHER_SECRET' }
    const records = [
      { id: 'good-id', ciphertext: goodCiphertext },
      { id: '../escape', ciphertext: goodCiphertext },
      { id: 'bad-base64', ciphertext: 'not base64' },
      { id: 'good-id', ciphertext: goodCiphertext },
      { id: 'bad-cipher', ciphertext: Buffer.from('wrong-header').toString('base64') },
      { id: 'bad-payload', ciphertext: encryptText('{"engine":"mysql","password":"HIDDEN"}') },
      { id: 'other-id', ciphertext: encryptText(JSON.stringify(otherInput)) }
    ]
    await writeFile(filePath, JSON.stringify({ version: 1, records }), { mode: 0o600 })

    const loaded = await new ConnectionVault(filePath, protector).load()
    expect(loaded.entries).toEqual([
      { id: 'good-id', input: postgresInput },
      { id: 'other-id', input: otherInput }
    ])
    expect(loaded.warnings.map((item) => item.code)).toEqual([
      'INVALID_RECORD',
      'INVALID_RECORD',
      'DUPLICATE_ID',
      'DECRYPTION_FAILED',
      'INVALID_PAYLOAD'
    ])
    expect(loaded.warnings.map((item) => item.recordNumber)).toEqual([2, 3, 4, 5, 6])
    expect(JSON.stringify(loaded.warnings)).not.toContain('../escape')
    expect(JSON.stringify(loaded.warnings)).not.toContain('HIDDEN')
    expect(JSON.stringify(loaded.warnings)).not.toContain(directory)
  })

  it('rejects traversal-like ids and strict-schema violations without leaking values or paths', async () => {
    const vault = new ConnectionVault(filePath, protector)
    await expect(vault.save('../outside', postgresInput)).rejects.toMatchObject({
      code: 'INVALID_ID'
    })
    await expect(readFile(filePath)).rejects.toMatchObject({ code: 'ENOENT' })

    const invalid = { ...postgresInput, unexpected: 'PRIVATE_EXTRA' }
    const inputFailure = vault.save('valid-id', invalid)
    await expect(inputFailure).rejects.toMatchObject({ code: 'INVALID_INPUT' })
    await expect(inputFailure).rejects.toSatisfy((error: Error) =>
      !error.message.includes('PRIVATE_EXTRA') && !error.message.includes(directory)
    )

    await writeFile(filePath, JSON.stringify({ version: 2, records: [] }), { mode: 0o600 })
    const fileFailure = vault.load()
    await expect(fileFailure).rejects.toBeInstanceOf(ConnectionVaultError)
    await expect(fileFailure).rejects.toMatchObject({ code: 'INVALID_FILE' })
    await expect(fileFailure).rejects.toSatisfy((error: Error) => !error.message.includes(filePath))
  })

  it('enforces ciphertext and file size limits before decrypting', async () => {
    const oversizedProtector: Protector = {
      backend: 'oversized-test',
      isAvailable: () => true,
      encrypt: () => Buffer.alloc(64 * 1024 + 1, 7),
      decrypt: () => {
        throw new Error('should not run')
      }
    }
    await expect(
      new ConnectionVault(filePath, oversizedProtector).save('valid-id', postgresInput)
    ).rejects.toMatchObject({ code: 'LIMIT_EXCEEDED' })
    await expect(readFile(filePath)).rejects.toMatchObject({ code: 'ENOENT' })

    await writeFile(filePath, Buffer.alloc(8 * 1024 * 1024 + 1, 0x20), { mode: 0o600 })
    await expect(new ConnectionVault(filePath, protector).load()).rejects.toMatchObject({
      code: 'LIMIT_EXCEEDED'
    })
  })
})
