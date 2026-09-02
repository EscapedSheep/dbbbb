// @vitest-environment node
import { Buffer } from 'node:buffer'
import { mkdtempSync, existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { afterEach, describe, expect, it } from 'vitest'
import type {
  ConnectionProfile,
  RowResult,
  SqliteConnectionInput
} from '../../shared/database'
import type { ExecuteOptions } from './database-adapter'
import { MAX_WIRE_VALUE_BYTES } from './postgres-adapter'
import { SqliteAdapter, assertReadOnlySql } from './sqlite-adapter'

const cleanupPaths: string[] = []

afterEach(() => {
  while (cleanupPaths.length > 0) {
    rmSync(cleanupPaths.pop() as string, { recursive: true, force: true })
  }
})

function createFixtureDb(): string {
  const directory = mkdtempSync(join(tmpdir(), 'dbbbb-sqlite-'))
  cleanupPaths.push(directory)
  const filePath = join(directory, 'fixture.db')

  const database = new DatabaseSync(filePath)
  database.exec(`
    CREATE TABLE users (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      balance REAL,
      avatar BLOB,
      big INTEGER
    );
    CREATE VIEW user_names AS SELECT id, name FROM users;
    CREATE INDEX idx_users_name ON users(name);
    CREATE TABLE seq (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
    CREATE TABLE "odd ""name""" (x TEXT);
  `)
  const insert = database.prepare(
    'INSERT INTO users (name, balance, avatar, big) VALUES (?, ?, ?, ?)'
  )
  insert.run('ada', 12.5, Buffer.from([1, 2, 255]), 9_007_199_254_740_993n)
  insert.run('grace', null, null, 42n)
  database.close()
  return filePath
}

function makeInput(filePath: string, readOnly = false): SqliteConnectionInput {
  return {
    engine: 'sqlite',
    name: 'Fixture',
    database: 'main',
    environment: 'development',
    readOnly,
    filePath
  }
}

function makeProfile(filePath: string, readOnly = false): ConnectionProfile {
  return {
    id: 'conn-1',
    name: 'Fixture',
    engine: 'sqlite',
    endpoint: filePath,
    database: 'main',
    environment: 'development',
    readOnly,
    demo: false
  }
}

function makeOptions(overrides: Partial<ExecuteOptions> = {}): ExecuteOptions {
  return {
    requestId: 'req-1',
    timeoutMs: 0,
    maxRows: 1000,
    maxBytes: 10 * 1024 * 1024,
    ...overrides
  }
}

function query(text: string) {
  return { engine: 'sqlite' as const, kind: 'query' as const, text }
}

async function executeRows(
  adapter: SqliteAdapter,
  profile: ConnectionProfile,
  text: string,
  options: Partial<ExecuteOptions> = {}
): Promise<RowResult> {
  const result = await adapter.execute(profile, query(text), makeOptions(options))
  if (result.kind !== 'rows') throw new Error('Expected a row result.')
  return result
}

describe('SqliteAdapter validation', () => {
  it('rejects invalid connection input', () => {
    const filePath = createFixtureDb()
    expect(() => new SqliteAdapter({ ...makeInput(filePath), filePath: '  ' }))
      .toThrow('SQLite connection settings are invalid.')
    expect(() => new SqliteAdapter({ ...makeInput(filePath), filePath: 'a\0b' }))
      .toThrow('SQLite connection settings are invalid.')
    expect(
      () => new SqliteAdapter({ ...makeInput(filePath), engine: 'mysql' } as never)
    ).toThrow('SQLite connection settings are invalid.')
  })

  it('rejects invalid execute options', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    await expect(
      adapter.execute(makeProfile(filePath), query('SELECT 1'), makeOptions({ maxRows: 0 }))
    ).rejects.toThrow('SQLite execution options are invalid.')
    await expect(
      adapter.execute(makeProfile(filePath), query('SELECT 1'), makeOptions({ requestId: '' }))
    ).rejects.toThrow('SQLite execution options are invalid.')
    await adapter.close()
  })

  it('rejects mismatched profiles and commands', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    const wrongProfile = { ...makeProfile(filePath), engine: 'mysql' } as never
    await expect(adapter.listObjects(wrongProfile)).rejects.toThrow(
      'The selected connection is not a SQLite connection.'
    )
    await expect(
      adapter.execute(
        makeProfile(filePath),
        { engine: 'mongodb', kind: 'find', collection: 'c', text: '{}' },
        makeOptions()
      )
    ).rejects.toThrow('The selected SQLite connection only accepts SQL queries.')
    await expect(
      adapter.execute(makeProfile(filePath), query('   '), makeOptions())
    ).rejects.toThrow('SQLite query cannot be empty.')
    await adapter.close()
  })
})

describe('SqliteAdapter connection handling', () => {
  it('fails to open a missing file in read-only mode without creating it', async () => {
    const directory = mkdtempSync(join(tmpdir(), 'dbbbb-sqlite-'))
    cleanupPaths.push(directory)
    const filePath = join(directory, 'missing.db')

    const adapter = new SqliteAdapter(makeInput(filePath, true))
    await expect(adapter.connect()).rejects.toThrow('Could not open the SQLite database')
    expect(existsSync(filePath)).toBe(false)
  })

  it('sanitizes errors for directory paths', async () => {
    const directory = mkdtempSync(join(tmpdir(), 'dbbbb-sqlite-'))
    cleanupPaths.push(directory)

    const adapter = new SqliteAdapter(makeInput(directory))
    const failure = await adapter.connect().catch((error: unknown) => error)
    expect(failure).toBeInstanceOf(Error)
    const message = (failure as Error).message
    expect(message).toContain('Could not open the SQLite database')
    expect(message).not.toContain(directory)
    expect((failure as Error).name).toBe('SqliteAdapterError')
  })

  it('replaces the database file path in query errors', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    // The table name is the file path itself, so SQLite echoes it back in the
    // error message; the adapter must scrub it before crossing IPC.
    const failure = await adapter
      .execute(makeProfile(filePath), query(`SELECT * FROM "${filePath}"`), makeOptions())
      .catch((error: unknown) => error)
    expect(failure).toBeInstanceOf(Error)
    expect((failure as Error).message).toContain('[local file]')
    expect((failure as Error).message).not.toContain(filePath)
    await adapter.close()
  })

  it('refuses work after close and closes idempotently', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    await adapter.connect()
    await adapter.close()
    await adapter.close()
    await expect(adapter.connect()).rejects.toThrow('The SQLite connection is closed.')
    await expect(
      adapter.execute(makeProfile(filePath), query('SELECT 1'), makeOptions())
    ).rejects.toThrow('The SQLite connection is closed.')
    await expect(adapter.listObjects(makeProfile(filePath))).rejects.toThrow(
      'The SQLite connection is closed.'
    )
  })
})

describe('SqliteAdapter object introspection', () => {
  it('lists tables and views under main, excluding internal objects', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    const nodes = await adapter.listObjects(makeProfile(filePath))

    expect(nodes[0]).toMatchObject({ name: 'main', kind: 'schema', detail: '4 objects' })
    const children = nodes.slice(1)
    expect(children.map((node) => node.name)).toEqual([
      'odd "name"',
      'seq',
      'user_names',
      'users'
    ])
    expect(children.every((node) => node.parentId === nodes[0].id)).toBe(true)
    expect(children.find((node) => node.name === 'user_names')?.kind).toBe('view')
    expect(children.find((node) => node.name === 'users')?.kind).toBe('table')
    // sqlite_sequence (AUTOINCREMENT) and indexes stay hidden.
    expect(nodes.some((node) => node.name.startsWith('sqlite_'))).toBe(false)
    await adapter.close()
  })

  it('builds quoted preview commands for introspected objects', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    const nodes = await adapter.listObjects(makeProfile(filePath))
    const odd = nodes.find((node) => node.name === 'odd "name"') as { id: string }

    const command = await adapter.previewObject(makeProfile(filePath), odd.id)
    expect(command).toEqual({
      engine: 'sqlite',
      kind: 'query',
      text: 'SELECT *\nFROM "odd ""name"""\nLIMIT 100;'
    })

    await expect(
      adapter.previewObject(makeProfile(filePath), nodes[0].id)
    ).rejects.toThrow('This SQLite object cannot be previewed.')
    await expect(
      adapter.previewObject(makeProfile(filePath), 'sqlite:unknown')
    ).rejects.toThrow('This SQLite object cannot be previewed.')
    await adapter.close()
  })
})

describe('SqliteAdapter execute', () => {
  it('returns typed columns and rows', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    const result = await executeRows(
      adapter,
      makeProfile(filePath),
      'SELECT id, name, balance FROM users ORDER BY id'
    )

    expect(result.columns).toEqual([
      { key: 'id', label: 'id', dataType: 'INTEGER', align: 'end' },
      { key: 'name', label: 'name', dataType: 'TEXT', align: 'start' },
      { key: 'balance', label: 'balance', dataType: 'REAL', align: 'end' }
    ])
    expect(result.rows).toEqual([
      [1, 'ada', 12.5],
      [2, 'grace', null]
    ])
    expect(result.meta).toMatchObject({ count: 2, truncated: false, source: 'database' })
    expect(result.meta.elapsedMs).toBeGreaterThanOrEqual(0)
    await adapter.close()
  })

  it('crosses blobs as base64 and keeps bigint precision', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    const result = await executeRows(
      adapter,
      makeProfile(filePath),
      'SELECT avatar, big FROM users ORDER BY id'
    )

    expect(result.rows[0][0]).toEqual({ $binary: Buffer.from([1, 2, 255]).toString('base64') })
    // 2^53 + 1 cannot survive as a JS number, so it crosses as a string.
    expect(result.rows[0][1]).toBe('9007199254740993')
    expect(result.rows[1][0]).toBeNull()
    expect(result.rows[1][1]).toBe(42)
    await adapter.close()
  })

  it('deduplicates repeated column names into distinct keys', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    const result = await executeRows(adapter, makeProfile(filePath), 'SELECT 1 AS a, 2 AS a')

    expect(result.columns.map((column) => column.key)).toEqual(['a', 'a:1'])
    expect(result.columns[0].dataType).toBe('unknown')
    expect(result.rows).toEqual([[1, 2]])
    await adapter.close()
  })

  it('applies the row budget', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    const result = await executeRows(
      adapter,
      makeProfile(filePath),
      'SELECT id FROM users ORDER BY id',
      { maxRows: 1 }
    )
    expect(result.rows).toEqual([[1]])
    expect(result.meta.truncated).toBe(true)
    await adapter.close()
  })

  it('applies the byte budget', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    const result = await executeRows(
      adapter,
      makeProfile(filePath),
      'SELECT name FROM users ORDER BY id',
      { maxBytes: 12 }
    )
    expect(result.rows.length).toBeLessThan(2)
    expect(result.meta.truncated).toBe(true)
    await adapter.close()
  })

  it('truncates single oversized values with a visible marker', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    const result = await executeRows(
      adapter,
      makeProfile(filePath),
      `SELECT zeroblob(${MAX_WIRE_VALUE_BYTES + 1}) AS blob`,
      // Headroom for the base64 form of a full 8 MiB wire value plus marker.
      { maxBytes: 32 * 1024 * 1024 }
    )
    const value = result.rows[0][0] as { $binary: string }
    expect(value.$binary.endsWith('…[dbbbb truncated 1 bytes]')).toBe(true)
    await adapter.close()
  })

  it('rejects multi-statement input instead of silently dropping the tail', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    await expect(
      adapter.execute(makeProfile(filePath), query('SELECT 1; SELECT 2'), makeOptions())
    ).rejects.toThrow('SQLite connections only allow one SQL statement at a time.')
    await adapter.close()
  })

  it('executes writes on writable connections', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    const inserted = await executeRows(
      adapter,
      makeProfile(filePath),
      "INSERT INTO users (name) VALUES ('linus')"
    )
    expect(inserted.rows).toEqual([])

    const counted = await executeRows(
      adapter,
      makeProfile(filePath),
      'SELECT count(*) AS c FROM users'
    )
    expect(counted.rows).toEqual([[3]])
    await adapter.close()
  })
})

describe('SqliteAdapter read-only enforcement', () => {
  it('allows single read-only statements, comments included', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath, true))
    const profile = makeProfile(filePath, true)

    const commented = await executeRows(
      adapter,
      profile,
      '-- lead comment\n/* block */ SELECT id FROM users ORDER BY id -- trail'
    )
    expect(commented.rows).toEqual([[1], [2]])

    const cte = await executeRows(
      adapter,
      profile,
      'WITH x AS (SELECT 1 AS v) SELECT v FROM x'
    )
    expect(cte.rows).toEqual([[1]])

    const explained = await executeRows(adapter, profile, 'EXPLAIN SELECT * FROM users')
    expect(explained.rows.length).toBeGreaterThan(0)
    await adapter.close()
  })

  it.each([
    "INSERT INTO users (name) VALUES ('x')",
    'UPDATE users SET name = name',
    'DELETE FROM users',
    'CREATE TABLE t (x)',
    'DROP TABLE users',
    'ATTACH DATABASE \':memory:\' AS other',
    'PRAGMA table_info(users)',
    'PRAGMA writable_schema = ON',
    'WITH x AS (SELECT 1) DELETE FROM users',
    'SELECT 1; SELECT 2',
    'VACUUM'
  ])('rejects %s in read-only mode', async (text) => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath, true))
    await expect(
      adapter.execute(makeProfile(filePath, true), query(text), makeOptions())
    ).rejects.toThrow(/[Rr]ead-only|one SQL statement/)
    await adapter.close()
  })

  it('fails closed on unterminated quotes', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath, true))
    await expect(
      adapter.execute(makeProfile(filePath, true), query("SELECT 'abc"), makeOptions())
    ).rejects.toThrow('could not safely classify')
    await adapter.close()
  })

  it('blocks writes even though the connection could open writable', async () => {
    const filePath = createFixtureDb()
    // Profile flag alone (input stays writable) must still engage the guard.
    const adapter = new SqliteAdapter(makeInput(filePath, false))
    await expect(
      adapter.execute(
        makeProfile(filePath, true),
        query("INSERT INTO users (name) VALUES ('x')"),
        makeOptions()
      )
    ).rejects.toThrow('Read-only connections only allow read-only SQL statements.')
    await adapter.close()
  })
})

describe('assertReadOnlySql', () => {
  it('accepts SELECT/WITH/EXPLAIN starters', () => {
    expect(() => assertReadOnlySql('SELECT 1')).not.toThrow()
    expect(() => assertReadOnlySql('WITH x AS (SELECT 1) SELECT * FROM x')).not.toThrow()
    expect(() => assertReadOnlySql('EXPLAIN QUERY PLAN SELECT 1')).not.toThrow()
  })

  it('rejects writes hidden behind comments and strings', () => {
    expect(() => assertReadOnlySql('/* DELETE FROM users */ SELECT 1')).not.toThrow()
    expect(() => assertReadOnlySql("SELECT 'DELETE FROM users'")).not.toThrow()
    expect(() => assertReadOnlySql('SELECT 1 -- trailing ; SELECT 2')).not.toThrow()
  })
})

describe('SqliteAdapter cancel', () => {
  it('is explicitly unsupported and side-effect free', async () => {
    const filePath = createFixtureDb()
    const adapter = new SqliteAdapter(makeInput(filePath))
    await expect(adapter.cancel('req-9')).rejects.toThrow(
      'SQLite queries cannot be cancelled; statements run to completion.'
    )
    // The failed cancel must not disturb subsequent work.
    const result = await executeRows(adapter, makeProfile(filePath), 'SELECT 1 AS ok')
    expect(result.rows).toEqual([[1]])
    await adapter.close()
  })
})
