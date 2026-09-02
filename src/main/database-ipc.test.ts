// @vitest-environment node
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { BrowserWindow, IpcMainInvokeEvent } from 'electron'

const electronMocks = vi.hoisted(() => {
  const handlers = new Map<string, (event: IpcMainInvokeEvent, ...args: unknown[]) => unknown>()
  return {
    handlers,
    handle: vi.fn((channel: string, handler: (event: IpcMainInvokeEvent, ...args: unknown[]) => unknown) => {
      handlers.set(channel, handler)
    }),
    removeHandler: vi.fn((channel: string) => handlers.delete(channel))
  }
})

vi.mock('electron', () => ({
  ipcMain: { handle: electronMocks.handle, removeHandler: electronMocks.removeHandler },
  dialog: { showOpenDialog: vi.fn(), showSaveDialog: vi.fn() }
}))

import { IPC_CHANNELS } from '../shared/database'
import type { ImportProgressUpdate } from '../shared/database'
import { parseApplyDataChangeRequest, registerDatabaseIpc } from './database-ipc'
import type { DatabaseService } from './database-service'
import { ImportCoordinator } from './transfers/import-coordinator'

const MAX_CHANGE_NODES = 100_000
const MAX_CHANGE_TEXT = 5 * 1024 * 1024

beforeEach(() => {
  electronMocks.handlers.clear()
  electronMocks.handle.mockClear()
  electronMocks.removeHandler.mockClear()
})

function updatePayload(): Record<string, unknown> {
  return {
    connectionId: 'connection-1',
    objectId: 'table-users',
    engine: 'postgresql',
    action: 'update',
    original: { id: 7, name: 'Before', meta: { active: false } },
    current: { id: 7, name: 'After', meta: { active: true } }
  }
}

function deletePayload(original: unknown = { id: 7 }): Record<string, unknown> {
  return {
    connectionId: 'connection-1',
    objectId: 'table-users',
    engine: 'postgresql',
    action: 'delete',
    original
  }
}

function ownKeyRecord(key: PropertyKey, nested: boolean): Record<string, unknown> {
  const unsafe = Object.create(null) as Record<PropertyKey, unknown>
  Object.defineProperty(unsafe, key, {
    configurable: true,
    enumerable: true,
    writable: true,
    value: 'unsafe'
  })
  return nested ? { safe: unsafe } : unsafe as Record<string, unknown>
}

function nestedRecord(objectDepth: number): Record<string, unknown> {
  let value: unknown = 'leaf'
  for (let depth = 0; depth < objectDepth; depth += 1) value = { next: value }
  return value as Record<string, unknown>
}

describe('parseApplyDataChangeRequest valid requests', () => {
  it('parses update and clones every record object onto a null prototype', () => {
    const payload = updatePayload()
    const original = payload.original as Record<string, unknown>
    const current = payload.current as Record<string, unknown>

    const parsed = parseApplyDataChangeRequest(payload)

    expect(parsed).toMatchObject({
      connectionId: 'connection-1',
      objectId: 'table-users',
      engine: 'postgresql',
      action: 'update',
      original: { id: 7, name: 'Before', meta: { active: false } },
      current: { id: 7, name: 'After', meta: { active: true } }
    })
    expect(parsed.original).not.toBe(original)
    expect(parsed.current).not.toBe(current)
    expect(Object.getPrototypeOf(parsed.original)).toBeNull()
    expect(Object.getPrototypeOf(parsed.current!)).toBeNull()
    expect(Object.getPrototypeOf(parsed.original.meta as object)).toBeNull()
    expect(Object.getPrototypeOf(parsed.current!.meta as object)).toBeNull()
  })

  it('parses delete without manufacturing a current record', () => {
    const parsed = parseApplyDataChangeRequest({
      connectionId: ' mongo-1 ',
      objectId: ' collection-users ',
      engine: 'mongodb',
      action: 'delete',
      original: { _id: { $oid: 'abc123' }, enabled: true }
    })

    expect(parsed).toMatchObject({
      connectionId: 'mongo-1',
      objectId: 'collection-users',
      engine: 'mongodb',
      action: 'delete',
      original: { _id: { $oid: 'abc123' }, enabled: true }
    })
    expect(parsed.current).toBeUndefined()
    expect(Object.getPrototypeOf(parsed.original)).toBeNull()
    expect(Object.getPrototypeOf(parsed.original._id as object)).toBeNull()
  })

  it('accepts null-prototype input but always returns a distinct safe clone', () => {
    const original = Object.create(null) as Record<string, unknown>
    original.id = 9
    original.nested = Object.assign(Object.create(null), { value: 'safe' })
    const payload = Object.assign(Object.create(null), deletePayload(original))

    const parsed = parseApplyDataChangeRequest(payload)

    expect(parsed.original).not.toBe(original)
    expect(parsed.original).toEqual({ id: 9, nested: { value: 'safe' } })
    expect(Object.getPrototypeOf(parsed.original)).toBeNull()
    expect(Object.getPrototypeOf(parsed.original.nested as object)).toBeNull()
  })
})

describe('parseApplyDataChangeRequest action shape', () => {
  it.each([
    ['missing', undefined],
    ['null', null],
    ['an array', []],
    ['an empty object', {}]
  ])('rejects update with %s current record', (_label, current) => {
    const payload = updatePayload()
    if (current === undefined) delete payload.current
    else payload.current = current

    expect(() => parseApplyDataChangeRequest(payload)).toThrow(/record change/i)
  })

  it('rejects delete when an extra current record is supplied', () => {
    expect(() => parseApplyDataChangeRequest({
      ...deletePayload(),
      current: { id: 7, status: 'deleted' }
    })).toThrow(/delete changes cannot include a current record/i)
  })

  it.each([
    ['unknown engine', { engine: 'oracle' }, /engine is invalid/i],
    ['unknown action', { action: 'insert' }, /action is invalid/i],
    ['missing original', { original: undefined }, /record change/i]
  ])('rejects %s', (_label, override, expected) => {
    expect(() => parseApplyDataChangeRequest({ ...updatePayload(), ...override })).toThrow(expected)
  })
})

describe('parseApplyDataChangeRequest hostile records', () => {
  it.each([
    ['__proto__', false],
    ['constructor', false],
    ['prototype', false],
    ['field\0name', false],
    ['__proto__', true],
    ['constructor', true],
    ['prototype', true],
    ['field\0name', true]
  ])('rejects unsafe key %s (nested: %s)', (key, nested) => {
    expect(() => parseApplyDataChangeRequest(deletePayload(ownKeyRecord(key, nested))))
      .toThrow(/unsafe field name/i)
  })

  it('rejects symbol keys', () => {
    expect(() => parseApplyDataChangeRequest(
      deletePayload(ownKeyRecord(Symbol('private'), false))
    )).toThrow(/unsafe field name/i)
  })

  it('rejects accessors without invoking them', () => {
    let invoked = false
    const original: Record<string, unknown> = { id: 1 }
    Object.defineProperty(original, 'secret', {
      enumerable: true,
      get: () => {
        invoked = true
        return 'should-not-run'
      }
    })

    expect(() => parseApplyDataChangeRequest(deletePayload(original)))
      .toThrow(/data properties only/i)
    expect(invoked).toBe(false)
  })

  it('rejects cyclic records as too complex instead of recursing forever', () => {
    const original: Record<string, unknown> = { id: 1 }
    original.self = original

    expect(() => parseApplyDataChangeRequest(deletePayload(original))).toThrow(/too complex/i)
  })
})

describe('parseApplyDataChangeRequest number and complexity bounds', () => {
  it.each([
    ['NaN', Number.NaN],
    ['positive infinity', Number.POSITIVE_INFINITY],
    ['negative infinity', Number.NEGATIVE_INFINITY],
    ['unsafe positive integer', Number.MAX_SAFE_INTEGER + 1],
    ['unsafe negative integer', Number.MIN_SAFE_INTEGER - 1]
  ])('rejects %s', (_label, value) => {
    expect(() => parseApplyDataChangeRequest(deletePayload({ id: value })))
      .toThrow(/invalid number/i)
  })

  it('accepts the exact depth limit and rejects one level beyond it', () => {
    expect(() => parseApplyDataChangeRequest(deletePayload(nestedRecord(32)))).not.toThrow()
    expect(() => parseApplyDataChangeRequest(deletePayload(nestedRecord(33))))
      .toThrow(/too complex/i)
  })

  it('accepts the exact node limit and rejects one node beyond it', () => {
    const atLimit = { items: new Array(MAX_CHANGE_NODES - 2).fill(null) }
    const overLimit = { items: new Array(MAX_CHANGE_NODES - 1).fill(null) }

    expect(() => parseApplyDataChangeRequest(deletePayload(atLimit))).not.toThrow()
    expect(() => parseApplyDataChangeRequest(deletePayload(overLimit))).toThrow(/too complex/i)
  })

  it('accepts the exact text budget and rejects one character beyond it', () => {
    const atLimit = { v: 'x'.repeat(MAX_CHANGE_TEXT - 1) }
    const overLimit = { v: 'x'.repeat(MAX_CHANGE_TEXT) }

    expect(() => parseApplyDataChangeRequest(deletePayload(atLimit))).not.toThrow()
    expect(() => parseApplyDataChangeRequest(deletePayload(overLimit))).toThrow(/too large/i)
  })
})

describe('saved connection IPC boundary', () => {
  const mainFrame = {}
  const webContents = {
    id: 17,
    isDestroyed: () => false,
    mainFrame
  }
  const trustedEvent = { sender: webContents, senderFrame: mainFrame } as unknown as IpcMainInvokeEvent
  const untrustedEvent = {
    sender: { id: 99, isDestroyed: () => false },
    senderFrame: mainFrame
  } as unknown as IpcMainInvokeEvent
  const window = {
    isDestroyed: () => false,
    webContents
  } as unknown as BrowserWindow

  function register(service: Record<string, unknown>): void {
    registerDatabaseIpc(service as unknown as DatabaseService, () => window)
  }

  it('serves startup warnings only for a trusted, payload-free request', () => {
    const getStartupWarnings = vi.fn(() => ['One safe warning.'])
    register({ getStartupWarnings })
    const handler = electronMocks.handlers.get(IPC_CHANNELS.getStartupWarnings)!

    expect(handler(trustedEvent)).toEqual(['One safe warning.'])
    expect(getStartupWarnings).toHaveBeenCalledOnce()
    expect(() => handler(trustedEvent, 'unexpected')).toThrow(/request is invalid/i)
    expect(() => handler(untrustedEvent)).toThrow(/unknown renderer/i)
  })

  it('rejects stale or destroyed senders even when a numeric webContents id matches', () => {
    const listConnections = vi.fn(() => [])
    let currentWindow: BrowserWindow | null = window
    registerDatabaseIpc({ listConnections } as unknown as DatabaseService, () => currentWindow)
    const handler = electronMocks.handlers.get(IPC_CHANNELS.listConnections)!
    const staleSameId = {
      sender: { id: webContents.id, isDestroyed: () => false },
      senderFrame: mainFrame
    } as unknown as IpcMainInvokeEvent

    expect(() => handler(staleSameId)).toThrow(/unknown renderer/i)
    currentWindow = {
      isDestroyed: () => true,
      webContents
    } as unknown as BrowserWindow
    expect(() => handler(trustedEvent)).toThrow(/unknown renderer/i)
    currentWindow = null
    expect(() => handler(trustedEvent)).toThrow(/unknown renderer/i)
    expect(listConnections).not.toHaveBeenCalled()
  })

  it('removes database invoke handlers exactly once during shutdown cleanup', () => {
    const cleanup = registerDatabaseIpc({} as DatabaseService, () => window)

    expect(electronMocks.handlers.has(IPC_CHANNELS.listConnections)).toBe(true)
    cleanup()
    cleanup()

    expect(electronMocks.handlers.has(IPC_CHANNELS.listConnections)).toBe(false)
    expect(electronMocks.handlers.has(IPC_CHANNELS.importProgress)).toBe(false)
    expect(electronMocks.removeHandler).toHaveBeenCalledTimes(
      Object.keys(IPC_CHANNELS).length - 1
    )
  })

  it('validates and trims one forget id without accepting extra arguments', async () => {
    const forgetConnection = vi.fn(async () => undefined)
    register({ forgetConnection })
    const handler = electronMocks.handlers.get(IPC_CHANNELS.forgetConnection)!

    await expect(handler(trustedEvent, ' saved-id ')).resolves.toBeUndefined()
    expect(forgetConnection).toHaveBeenCalledWith('saved-id')
    expect(() => handler(trustedEvent, '')).toThrow(/Connection id is invalid/i)
    expect(() => handler(trustedEvent, '../saved-id')).toThrow(/Connection id is invalid/i)
    expect(() => handler(trustedEvent, 'saved-id', 'extra')).toThrow(/request is invalid/i)
  })

  it('parses an optional boolean remember intent and rejects other values before service access', async () => {
    const connect = vi.fn(async (input) => input)
    register({ connect })
    const handler = electronMocks.handlers.get(IPC_CHANNELS.connect)!
    const payload = {
      engine: 'postgresql',
      name: 'Saved PostgreSQL',
      database: 'app',
      environment: 'development',
      readOnly: false,
      remember: true,
      host: 'localhost',
      port: 5432,
      username: 'app',
      password: 'secret',
      sslMode: 'require'
    }

    await expect(handler(trustedEvent, payload)).resolves.toMatchObject({ remember: true })
    expect(connect).toHaveBeenCalledWith(expect.objectContaining({ remember: true }))
    expect(() => handler(trustedEvent, { ...payload, remember: 'yes' })).toThrow(/Remember/i)
    expect(connect).toHaveBeenCalledOnce()
  })

  it('parses a MySQL connection payload and rejects invalid port or SSL mode', async () => {
    const connect = vi.fn(async (input) => input)
    register({ connect })
    const handler = electronMocks.handlers.get(IPC_CHANNELS.connect)!
    const payload = {
      engine: 'mysql',
      name: 'Staging MySQL',
      database: 'shop',
      environment: 'staging',
      readOnly: true,
      host: ' mysql.internal ',
      port: 3306,
      username: 'shop_user',
      password: 'MYSQL_SECRET',
      sslMode: 'verify-full'
    }

    await expect(handler(trustedEvent, payload)).resolves.toMatchObject({
      engine: 'mysql',
      host: 'mysql.internal',
      port: 3306,
      username: 'shop_user',
      password: 'MYSQL_SECRET',
      sslMode: 'verify-full'
    })
    expect(() => handler(trustedEvent, { ...payload, port: 0 })).toThrow(/MySQL port is invalid/i)
    expect(() => handler(trustedEvent, { ...payload, port: 3.5 })).toThrow(/MySQL port is invalid/i)
    expect(() => handler(trustedEvent, { ...payload, sslMode: 'prefer' }))
      .toThrow(/MySQL SSL mode is invalid/i)
    expect(connect).toHaveBeenCalledOnce()
  })

  it('parses a SQLite connection payload and rejects empty, overlong, or NUL file paths', async () => {
    const connect = vi.fn(async (input) => input)
    register({ connect })
    const handler = electronMocks.handlers.get(IPC_CHANNELS.connect)!
    const payload = {
      engine: 'sqlite',
      name: 'Local SQLite',
      database: 'main',
      environment: 'development',
      readOnly: false,
      filePath: '/Users/tester/data/local.db'
    }

    await expect(handler(trustedEvent, payload)).resolves.toMatchObject({
      engine: 'sqlite',
      filePath: '/Users/tester/data/local.db'
    })
    expect(() => handler(trustedEvent, { ...payload, filePath: '   ' }))
      .toThrow(/SQLite file path is invalid/i)
    expect(() => handler(trustedEvent, { ...payload, filePath: `/${'a'.repeat(1024)}` }))
      .toThrow(/SQLite file path is invalid/i)
    expect(() => handler(trustedEvent, { ...payload, filePath: 'data/local\0.db' }))
      .toThrow(/SQLite file path is invalid/i)
    expect(connect).toHaveBeenCalledOnce()
  })

  it('keeps demo connections restricted to PostgreSQL and MongoDB drafts', () => {
    const createDemoConnection = vi.fn((draft) => draft)
    register({ createDemoConnection })
    const handler = electronMocks.handlers.get(IPC_CHANNELS.createDemoConnection)!
    const draft = {
      name: 'Demo',
      endpoint: 'localhost:3306',
      database: 'demo',
      environment: 'development',
      readOnly: true
    }

    expect(() => handler(trustedEvent, { ...draft, engine: 'mysql' }))
      .toThrow(/engine is invalid/i)
    expect(() => handler(trustedEvent, { ...draft, engine: 'sqlite' }))
      .toThrow(/engine is invalid/i)
    handler(trustedEvent, { ...draft, engine: 'mongodb' })
    expect(createDemoConnection).toHaveBeenCalledOnce()
  })

  it('routes MySQL and SQLite SQL commands through the execute parser', async () => {
    const execute = vi.fn(async (connectionId, requestId, command) => command)
    register({ execute })
    const handler = electronMocks.handlers.get(IPC_CHANNELS.execute)!

    for (const engine of ['mysql', 'sqlite'] as const) {
      await expect(handler(trustedEvent, {
        connectionId: 'connection-1',
        requestId: 'request-1',
        command: { engine, kind: 'query', text: 'SELECT 1;' }
      })).resolves.toEqual({ engine, kind: 'query', text: 'SELECT 1;' })
    }
    expect(() => handler(trustedEvent, {
      connectionId: 'connection-1',
      requestId: 'request-1',
      command: { engine: 'mysql', kind: 'find', collection: 'users', text: '{}' }
    })).toThrow(/Query command is invalid/i)
    expect(execute).toHaveBeenCalledTimes(2)
  })
})

describe('import progress IPC boundary', () => {
  const request = {
    connectionId: 'postgres-1',
    objectId: 'table-orders',
    format: 'csv'
  } as const
  const update: ImportProgressUpdate = {
    token: 'opaque-import-token',
    processed: 25,
    inserted: 24,
    failed: 1,
    bytes: 512,
    totalBytes: 1024
  }

  it('publishes only to the initiating, live, current trusted webContents', async () => {
    const mainFrame = {}
    const sender = {
      id: 17,
      isDestroyed: vi.fn(() => false),
      mainFrame,
      send: vi.fn()
    }
    const event = { sender, senderFrame: mainFrame } as unknown as IpcMainInvokeEvent
    const window = {
      isDestroyed: vi.fn(() => false),
      webContents: sender
    } as unknown as BrowserWindow
    let currentWindow: BrowserWindow | null = window
    const chooseFile = vi.spyOn(ImportCoordinator.prototype, 'chooseFile').mockResolvedValue({
      token: update.token,
      name: 'orders.csv',
      size: update.totalBytes
    })

    try {
      registerDatabaseIpc({} as DatabaseService, () => currentWindow)
      const handler = electronMocks.handlers.get(IPC_CHANNELS.chooseImportFile)!
      await expect(handler(event, request)).resolves.toMatchObject({ token: update.token })
      const publisher = chooseFile.mock.calls[0]?.[2]
      expect(publisher).toEqual(expect.any(Function))

      publisher!(update)
      expect(sender.send).toHaveBeenCalledWith(IPC_CHANNELS.importProgress, update)

      currentWindow = null
      publisher!(update)
      currentWindow = {
        isDestroyed: vi.fn(() => false),
        webContents: { ...sender }
      } as unknown as BrowserWindow
      publisher!(update)
      currentWindow = window
      vi.mocked(window.isDestroyed).mockReturnValue(true)
      publisher!(update)
      vi.mocked(window.isDestroyed).mockReturnValue(false)
      sender.isDestroyed.mockReturnValue(true)
      publisher!(update)

      expect(sender.send).toHaveBeenCalledTimes(1)
    } finally {
      chooseFile.mockRestore()
    }
  })

  it('swallows send failures and rejects an untrusted chooser before binding progress', async () => {
    const mainFrame = {}
    const sender = {
      id: 17,
      isDestroyed: vi.fn(() => false),
      mainFrame,
      send: vi.fn(() => {
        throw new Error('webContents was destroyed')
      })
    }
    const window = {
      isDestroyed: vi.fn(() => false),
      webContents: sender
    } as unknown as BrowserWindow
    const chooseFile = vi.spyOn(ImportCoordinator.prototype, 'chooseFile').mockResolvedValue({
      token: update.token,
      name: 'orders.csv',
      size: update.totalBytes
    })

    try {
      registerDatabaseIpc({} as DatabaseService, () => window)
      const handler = electronMocks.handlers.get(IPC_CHANNELS.chooseImportFile)!
      await handler({ sender, senderFrame: mainFrame } as unknown as IpcMainInvokeEvent, request)
      const publisher = chooseFile.mock.calls[0]?.[2]

      expect(() => publisher!(update)).not.toThrow()
      expect(sender.send).toHaveBeenCalledOnce()

      const untrusted = {
        sender: { id: 99, isDestroyed: vi.fn(() => false), send: vi.fn() },
        senderFrame: mainFrame
      } as unknown as IpcMainInvokeEvent
      expect(() => handler(untrusted, request)).toThrow(/unknown renderer/i)
      expect(chooseFile).toHaveBeenCalledOnce()
    } finally {
      chooseFile.mockRestore()
    }
  })
})
