import { beforeEach, describe, expect, it } from 'vitest'
import type { AddQueryInput, QueryLibrary } from './query-library'
import {
  createQueryLibrary,
  MAX_QUERY_HISTORY,
  MAX_QUERY_LIBRARY_BYTES,
  MAX_QUERY_TEXT_LENGTH,
  QUERY_LIBRARY_STORAGE_KEY,
  QUERY_LIBRARY_VERSION
} from './query-library'

function testLibrary(): QueryLibrary {
  let id = 0
  let clock = Date.parse('2026-08-31T10:00:00.000Z')
  return createQueryLibrary({
    createId: () => `query-${++id}`,
    now: () => new Date(clock++)
  })
}

function sqlInput(text: string, overrides: Partial<AddQueryInput> = {}): AddQueryInput {
  return {
    connectionId: 'connection-a',
    title: text,
    engine: 'postgresql',
    command: { engine: 'postgresql', kind: 'query', text },
    ...overrides
  }
}

describe('query library', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('persists a versioned, whitelisted entry without connection secrets', () => {
    const library = testLibrary()
    const unsafe = {
      ...sqlInput('SELECT 1', { title: 'Health check' }),
      password: 'connection-password',
      uri: 'postgresql://user:connection-password@db.example.test/app',
      command: {
        engine: 'postgresql',
        kind: 'query',
        text: 'SELECT 1',
        password: 'nested-password',
        uri: 'postgresql://db.example.test/app'
      }
    } as AddQueryInput

    const entry = library.add(unsafe)
    const raw = window.localStorage.getItem(QUERY_LIBRARY_STORAGE_KEY)

    expect(entry).toMatchObject({
      id: 'query-1',
      connectionId: 'connection-a',
      title: 'Health check',
      engine: 'postgresql',
      favorite: false
    })
    expect(JSON.parse(raw!)).toMatchObject({ version: QUERY_LIBRARY_VERSION })
    expect(raw).not.toContain('connection-password')
    expect(raw).not.toContain('nested-password')
    expect(raw).not.toContain('db.example.test')

    const reloaded = createQueryLibrary()
    expect(reloaded.list()).toEqual([entry])
  })

  it('round-trips MySQL and SQLite history and favorites through storage', () => {
    const library = testLibrary()
    const mysqlEntry = library.add({
      connectionId: 'connection-a',
      title: 'MySQL health',
      engine: 'mysql',
      command: { engine: 'mysql', kind: 'query', text: 'SELECT VERSION();' }
    })
    library.toggleFavorite(mysqlEntry.id)
    const sqliteEntry = library.add({
      connectionId: 'connection-b',
      title: 'SQLite tables',
      engine: 'sqlite',
      command: { engine: 'sqlite', kind: 'query', text: 'SELECT name FROM sqlite_master;' }
    })

    const reloaded = createQueryLibrary()
    expect(reloaded.list()).toEqual([
      sqliteEntry,
      { ...mysqlEntry, favorite: true }
    ])
  })

  it('deduplicates only adjacent queries with the same connection and command identity', () => {
    const library = testLibrary()
    const first = library.add(sqlInput('SELECT * FROM users', { title: 'First title' }))
    library.toggleFavorite(first.id)
    const duplicate = library.add(sqlInput('SELECT * FROM users', { title: 'Updated title' }))

    expect(duplicate.id).toBe(first.id)
    expect(duplicate.favorite).toBe(true)
    expect(duplicate.title).toBe('Updated title')
    expect(library.list()).toHaveLength(1)

    library.add(sqlInput('SELECT * FROM users', { connectionId: 'connection-b' }))
    library.add({
      connectionId: 'connection-b',
      title: 'Mongo users',
      engine: 'mongodb',
      command: { engine: 'mongodb', kind: 'find', collection: 'users', text: 'SELECT * FROM users' }
    })
    library.add({
      connectionId: 'connection-b',
      title: 'Mongo admins',
      engine: 'mongodb',
      command: { engine: 'mongodb', kind: 'find', collection: 'admins', text: 'SELECT * FROM users' }
    })

    expect(library.list()).toHaveLength(4)
  })

  it('keeps at most 100 history items while preserving favorites during clearHistory', () => {
    const library = testLibrary()
    const favorite = library.add(sqlInput('SELECT favorite'))
    library.toggleFavorite(favorite.id)

    for (let index = 0; index < MAX_QUERY_HISTORY + 5; index += 1) {
      library.add(sqlInput(`SELECT ${index}`))
    }

    expect(library.list().filter((entry) => !entry.favorite)).toHaveLength(MAX_QUERY_HISTORY)
    expect(library.list()).toContainEqual(expect.objectContaining({ id: favorite.id, favorite: true }))

    library.clearHistory()
    expect(library.list()).toEqual([expect.objectContaining({ id: favorite.id, favorite: true })])
  })

  it('toggles and removes entries without exposing mutable internal values', () => {
    const library = testLibrary()
    const entry = library.add(sqlInput('SELECT 42'))
    const listed = library.list()
    listed[0].title = 'Mutated outside'
    listed[0].command.text = 'DELETE FROM users'

    expect(library.list()[0]).toMatchObject({ title: 'SELECT 42', command: { text: 'SELECT 42' } })
    expect(library.toggleFavorite(entry.id)?.favorite).toBe(true)
    expect(library.toggleFavorite('missing')).toBeUndefined()
    expect(library.remove('missing')).toBe(false)
    expect(library.remove(entry.id)).toBe(true)
    expect(library.list()).toEqual([])
  })

  it('sanitizes malformed and oversized storage without throwing', () => {
    window.localStorage.setItem(
      QUERY_LIBRARY_STORAGE_KEY,
      JSON.stringify({
        version: QUERY_LIBRARY_VERSION,
        entries: [
          {
            id: 'safe-id',
            connectionId: 'connection-a',
            title: 'Saved query',
            engine: 'postgresql',
            command: {
              engine: 'postgresql',
              kind: 'query',
              text: 'SELECT 1',
              password: 'nested-secret'
            },
            createdAt: '2026-08-31T10:00:00.000Z',
            favorite: true,
            password: 'entry-secret',
            uri: 'postgresql://user:entry-secret@db.example.test/app'
          },
          { id: 'invalid' }
        ]
      })
    )

    const sanitized = createQueryLibrary()
    expect(sanitized.list()).toHaveLength(1)
    expect(window.localStorage.getItem(QUERY_LIBRARY_STORAGE_KEY)).not.toMatch(
      /nested-secret|entry-secret|db\.example\.test/
    )

    window.localStorage.setItem(QUERY_LIBRARY_STORAGE_KEY, '{not json')
    expect(createQueryLibrary().list()).toEqual([])
    // Recognizably corrupt data is rewritten with a clean, empty library.
    expect(JSON.parse(window.localStorage.getItem(QUERY_LIBRARY_STORAGE_KEY)!)).toEqual({
      version: QUERY_LIBRARY_VERSION,
      entries: []
    })
  })

  it('keeps unrecognized or oversized stored data untouched and runs in-memory', () => {
    const futurePayload = JSON.stringify({
      version: QUERY_LIBRARY_VERSION + 1,
      entries: [{ id: 'future-entry' }]
    })
    window.localStorage.setItem(QUERY_LIBRARY_STORAGE_KEY, futurePayload)

    let id = 0
    const library = createQueryLibrary({
      createId: () => `query-${++id}`,
      now: () => new Date('2026-08-31T10:00:00.000Z')
    })
    expect(library.list()).toEqual([])

    // The session stays usable, but the unknown schema must not be overwritten.
    library.add(sqlInput('SELECT 1'))
    expect(library.list()).toHaveLength(1)
    expect(window.localStorage.getItem(QUERY_LIBRARY_STORAGE_KEY)).toBe(futurePayload)

    const oversized = 'x'.repeat(MAX_QUERY_LIBRARY_BYTES + 1)
    window.localStorage.setItem(QUERY_LIBRARY_STORAGE_KEY, oversized)
    expect(createQueryLibrary().list()).toEqual([])
    expect(window.localStorage.getItem(QUERY_LIBRARY_STORAGE_KEY)).toBe(oversized)
  })

  it('throws a readable RangeError when favorites alone exceed the storage limit', () => {
    let id = 0
    let clock = Date.parse('2026-08-31T10:00:00.000Z')
    const library = createQueryLibrary({
      storage: null,
      createId: () => `query-${++id}`,
      now: () => new Date(clock++)
    })

    expect(() => {
      for (let index = 0; index < 2 * MAX_QUERY_HISTORY; index += 1) {
        const entry = library.add(sqlInput(`${index}:${'x'.repeat(MAX_QUERY_TEXT_LENGTH - 8)}`))
        library.toggleFavorite(entry.id)
      }
    }).toThrow(RangeError)
  })

  it('rejects invalid commands and remains usable when storage is unavailable', () => {
    const unavailableStorage = {
      getItem: (): string | null => {
        throw new Error('blocked')
      },
      setItem: (): void => {
        throw new Error('quota')
      }
    }
    let id = 0
    const library = createQueryLibrary({
      storage: unavailableStorage,
      createId: () => `volatile-${++id}`,
      now: () => new Date('2026-08-31T10:00:00.000Z')
    })

    expect(() => library.add(sqlInput('x'.repeat(MAX_QUERY_TEXT_LENGTH + 1)))).toThrow(RangeError)
    const entry = library.add(sqlInput('SELECT 1'))
    expect(library.list()).toEqual([entry])
  })
})
