import type { DatabaseCommand, DatabaseEngine } from '../../../shared/database'

export const QUERY_LIBRARY_STORAGE_KEY = 'dbbbb.query-library.v1'
export const QUERY_LIBRARY_VERSION = 1
export const MAX_QUERY_HISTORY = 100
export const MAX_QUERY_TEXT_LENGTH = 32_768
export const MAX_QUERY_LIBRARY_BYTES = 4 * 1024 * 1024

const MAX_TITLE_LENGTH = 200
const MAX_IDENTIFIER_LENGTH = 256

/** A saved query. connectionId is an opaque ID only; connection details are never stored. */
export interface QueryEntry {
  id: string
  connectionId: string
  title: string
  engine: DatabaseEngine
  command: DatabaseCommand
  createdAt: string
  favorite: boolean
}

export interface AddQueryInput {
  connectionId: string
  title?: string
  engine: DatabaseEngine
  command: DatabaseCommand
}

export interface QueryLibrary {
  list: () => QueryEntry[]
  add: (input: AddQueryInput) => QueryEntry
  toggleFavorite: (id: string) => QueryEntry | undefined
  remove: (id: string) => boolean
  clearHistory: () => void
}

export interface QueryLibraryStorage {
  getItem: (key: string) => string | null
  setItem: (key: string, value: string) => void
}

export interface QueryLibraryOptions {
  /** Pass null for an in-memory-only library. Defaults to window.localStorage when available. */
  storage?: QueryLibraryStorage | null
  now?: () => Date
  createId?: () => string
}

interface PersistedQueryLibrary {
  version: typeof QUERY_LIBRARY_VERSION
  entries: QueryEntry[]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function byteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength
}

function validIdentifier(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= MAX_IDENTIFIER_LENGTH
}

function sanitizeCommand(value: unknown): DatabaseCommand | undefined {
  if (!isRecord(value) || typeof value.text !== 'string') return undefined
  if (value.text.trim().length === 0 || value.text.length > MAX_QUERY_TEXT_LENGTH) return undefined

  if (
    (value.engine === 'postgresql' || value.engine === 'mysql' || value.engine === 'sqlite') &&
    value.kind === 'query'
  ) {
    return { engine: value.engine, kind: 'query', text: value.text }
  }

  if (
    value.engine === 'mongodb' &&
    (value.kind === 'find' || value.kind === 'aggregate') &&
    validIdentifier(value.collection)
  ) {
    return {
      engine: 'mongodb',
      kind: value.kind,
      collection: value.collection,
      text: value.text
    }
  }

  return undefined
}

function sanitizeEntry(value: unknown): QueryEntry | undefined {
  if (!isRecord(value)) return undefined

  const command = sanitizeCommand(value.command)
  if (
    !validIdentifier(value.id) ||
    !validIdentifier(value.connectionId) ||
    typeof value.title !== 'string' ||
    value.title.length === 0 ||
    value.title.length > MAX_TITLE_LENGTH ||
    (value.engine !== 'postgresql' &&
      value.engine !== 'mongodb' &&
      value.engine !== 'mysql' &&
      value.engine !== 'sqlite') ||
    !command ||
    command.engine !== value.engine ||
    typeof value.createdAt !== 'string' ||
    !Number.isFinite(Date.parse(value.createdAt)) ||
    typeof value.favorite !== 'boolean'
  ) {
    return undefined
  }

  // Explicit construction is intentional: unknown fields such as uri and password
  // must never survive parsing or reach localStorage again.
  return {
    id: value.id,
    connectionId: value.connectionId,
    title: value.title,
    engine: value.engine,
    command,
    createdAt: new Date(value.createdAt).toISOString(),
    favorite: value.favorite
  }
}

function cloneCommand(command: DatabaseCommand): DatabaseCommand {
  return command.engine === 'mongodb'
    ? {
        engine: 'mongodb',
        kind: command.kind,
        collection: command.collection,
        text: command.text
      }
    : { engine: command.engine, kind: 'query', text: command.text }
}

function cloneEntry(entry: QueryEntry): QueryEntry {
  return { ...entry, command: cloneCommand(entry.command) }
}

function limitHistory(entries: QueryEntry[]): QueryEntry[] {
  let historyCount = 0
  return entries.filter((entry) => entry.favorite || ++historyCount <= MAX_QUERY_HISTORY)
}

function serialize(entries: QueryEntry[]): string {
  const value: PersistedQueryLibrary = {
    version: QUERY_LIBRARY_VERSION,
    entries
  }
  return JSON.stringify(value)
}

function fitStorageLimit(entries: QueryEntry[]): { entries: QueryEntry[]; serialized: string } {
  const fitted = [...entries]
  let serialized = serialize(fitted)

  while (byteLength(serialized) > MAX_QUERY_LIBRARY_BYTES) {
    let removableIndex = -1
    for (let index = fitted.length - 1; index >= 0; index -= 1) {
      if (!fitted[index].favorite) {
        removableIndex = index
        break
      }
    }
    if (removableIndex < 0) {
      throw new RangeError(
        'Query library storage is full of favorites. Remove one before adding more queries.'
      )
    }
    fitted.splice(removableIndex, 1)
    serialized = serialize(fitted)
  }

  return { entries: fitted, serialized }
}

interface LoadedQueryLibrary {
  entries: QueryEntry[]
  /**
   * True when the stored value belongs to a schema we do not understand (version
   * mismatch or over-limit data). The original value must be kept untouched and
   * this session runs with an in-memory library instead of rewriting storage.
   */
  keepStoredValue: boolean
}

function readEntries(storage: QueryLibraryStorage | null): LoadedQueryLibrary {
  if (!storage) return { entries: [], keepStoredValue: false }

  try {
    const raw = storage.getItem(QUERY_LIBRARY_STORAGE_KEY)
    if (!raw) return { entries: [], keepStoredValue: false }
    if (raw.length > MAX_QUERY_LIBRARY_BYTES || byteLength(raw) > MAX_QUERY_LIBRARY_BYTES) {
      return { entries: [], keepStoredValue: true }
    }

    const parsed: unknown = JSON.parse(raw)
    if (isRecord(parsed) && parsed.version !== QUERY_LIBRARY_VERSION) {
      return { entries: [], keepStoredValue: true }
    }
    if (!isRecord(parsed) || !Array.isArray(parsed.entries)) {
      return { entries: [], keepStoredValue: false }
    }

    const seenIds = new Set<string>()
    const entries: QueryEntry[] = []
    for (const candidate of parsed.entries) {
      const entry = sanitizeEntry(candidate)
      if (entry && !seenIds.has(entry.id)) {
        entries.push(entry)
        seenIds.add(entry.id)
      }
    }

    entries.sort((left, right) => Date.parse(right.createdAt) - Date.parse(left.createdAt))
    return { entries: fitStorageLimit(limitHistory(entries)).entries, keepStoredValue: false }
  } catch {
    return { entries: [], keepStoredValue: false }
  }
}

function browserStorage(): QueryLibraryStorage | null {
  try {
    return typeof window === 'undefined' ? null : window.localStorage
  } catch {
    return null
  }
}

function defaultId(): string {
  if (typeof globalThis.crypto?.randomUUID === 'function') return globalThis.crypto.randomUUID()
  return `query-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

function defaultTitle(command: DatabaseCommand): string {
  const firstLine = command.text.split(/\r?\n/, 1)[0].trim().replace(/\s+/g, ' ')
  if (firstLine) {
    return firstLine.length <= MAX_TITLE_LENGTH
      ? firstLine
      : `${firstLine.slice(0, MAX_TITLE_LENGTH - 1)}…`
  }
  if (command.engine === 'mongodb') return `${command.collection} ${command.kind}`
  return command.engine === 'postgresql' ? 'PostgreSQL query' : 'SQL query'
}

function normalizeTitle(title: string | undefined, command: DatabaseCommand): string {
  const clean = title?.trim()
  if (!clean) return defaultTitle(command)
  return clean.length <= MAX_TITLE_LENGTH ? clean : `${clean.slice(0, MAX_TITLE_LENGTH - 1)}…`
}

function sameAdjacentQuery(left: QueryEntry, right: AddQueryInput, command: DatabaseCommand): boolean {
  if (
    left.connectionId !== right.connectionId ||
    left.engine !== right.engine ||
    left.command.text !== command.text ||
    left.command.kind !== command.kind
  ) {
    return false
  }

  return left.command.engine !== 'mongodb' ||
    (command.engine === 'mongodb' && left.command.collection === command.collection)
}

function buildCommand(input: AddQueryInput): DatabaseCommand {
  const command = sanitizeCommand(input.command)
  if (!command) {
    throw new RangeError(
      `Query command must be valid, non-empty, and at most ${MAX_QUERY_TEXT_LENGTH} characters.`
    )
  }
  if (input.engine !== command.engine) {
    throw new TypeError('Query engine must match command.engine.')
  }
  return command
}

/**
 * Creates a small synchronous query store. All returned values are defensive copies;
 * callers cannot mutate the in-memory or persisted library accidentally.
 */
export function createQueryLibrary(options: QueryLibraryOptions = {}): QueryLibrary {
  const storage = options.storage === undefined ? browserStorage() : options.storage
  const now = options.now ?? (() => new Date())
  const createId = options.createId ?? defaultId
  const loaded = readEntries(storage)
  let entries = loaded.entries
  // Stored data from an incompatible schema is left untouched; this session
  // keeps working with an in-memory-only library until the app can read it again.
  const writableStorage = loaded.keepStoredValue ? null : storage

  const persist = (nextEntries: QueryEntry[], requiredId?: string): void => {
    const fitted = fitStorageLimit(limitHistory(nextEntries))
    if (requiredId && !fitted.entries.some((entry) => entry.id === requiredId)) {
      throw new RangeError('Query library storage is full of favorites. Remove one before adding history.')
    }

    entries = fitted.entries
    try {
      writableStorage?.setItem(QUERY_LIBRARY_STORAGE_KEY, fitted.serialized)
    } catch {
      // localStorage may be unavailable or out of quota. The session-local store remains usable.
    }
  }

  // Rewrite a valid, whitelisted schema on construction. This also removes unknown
  // legacy fields (including accidental connection URI or password fields).
  persist(entries)

  return {
    list: () => entries.map(cloneEntry),

    add: (input) => {
      if (!validIdentifier(input.connectionId)) {
        throw new TypeError('connectionId must be a non-empty opaque identifier.')
      }

      const command = buildCommand(input)
      const created = now()
      if (!Number.isFinite(created.getTime())) throw new TypeError('now() returned an invalid date.')
      const createdAt = created.toISOString()
      const title = normalizeTitle(input.title, command)
      const adjacent = entries[0]

      if (adjacent && sameAdjacentQuery(adjacent, input, command)) {
        const updated: QueryEntry = {
          ...adjacent,
          title,
          command,
          createdAt
        }
        persist([updated, ...entries.slice(1)], updated.id)
        return cloneEntry(updated)
      }

      const baseId = createId()
      if (!validIdentifier(baseId)) throw new TypeError('createId() returned an invalid identifier.')
      let id = baseId
      for (let suffix = 2; entries.some((entry) => entry.id === id); suffix += 1) {
        const suffixText = `-${suffix}`
        id = `${baseId.slice(0, MAX_IDENTIFIER_LENGTH - suffixText.length)}${suffixText}`
      }

      const entry: QueryEntry = {
        id,
        connectionId: input.connectionId,
        title,
        engine: input.engine,
        command,
        createdAt,
        favorite: false
      }
      persist([entry, ...entries], entry.id)
      return cloneEntry(entry)
    },

    toggleFavorite: (id) => {
      const index = entries.findIndex((entry) => entry.id === id)
      if (index < 0) return undefined

      const updated = { ...entries[index], favorite: !entries[index].favorite }
      const nextEntries = [...entries]
      nextEntries[index] = updated
      persist(nextEntries, updated.id)
      return cloneEntry(updated)
    },

    remove: (id) => {
      const nextEntries = entries.filter((entry) => entry.id !== id)
      if (nextEntries.length === entries.length) return false
      persist(nextEntries)
      return true
    },

    clearHistory: () => {
      persist(entries.filter((entry) => entry.favorite))
    }
  }
}
