// @vitest-environment node
import { Readable } from 'node:stream'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { BrowserWindow } from 'electron'
import type {
  ConnectionProfile,
  DatabaseObjectNode,
  ImportFormat,
  ImportProgressUpdate,
  ImportResult
} from '../../shared/database'
import type { ImportDataOptions } from '../adapters/database-adapter'
import type { DatabaseService } from '../database-service'

const systemMocks = vi.hoisted(() => ({
  randomUUID: vi.fn(),
  createReadStream: vi.fn(),
  stat: vi.fn(),
  showOpenDialog: vi.fn()
}))

vi.mock('node:crypto', () => ({ randomUUID: systemMocks.randomUUID }))
vi.mock('node:fs', () => ({ createReadStream: systemMocks.createReadStream }))
vi.mock('node:fs/promises', () => ({ stat: systemMocks.stat }))
vi.mock('electron', () => ({ dialog: { showOpenDialog: systemMocks.showOpenDialog } }))

import {
  ImportCoordinator,
  type ImportProgressPublisher
} from './import-coordinator'

const PRIVATE_PATH = '/Users/alice/Private Data/orders.csv'
const FILE_SIZE = 128
const MODIFIED_AT_MS = 1_725_100_000_000
const MAX_FILE_BYTES = 1024 * 1024 * 1024
const windowStub = {} as BrowserWindow
const importSummary: ImportResult = { processed: 2, inserted: 2, failed: 0 }

interface FakeStats {
  isFile: () => boolean
  size: number
  mtimeMs: number
}

interface ServiceMocks {
  inspectImportTarget: ReturnType<typeof vi.fn>
  importData: ReturnType<typeof vi.fn>
}

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((resolvePromise) => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}

function stats(overrides: Partial<FakeStats> = {}): FakeStats {
  return {
    isFile: () => true,
    size: FILE_SIZE,
    mtimeMs: MODIFIED_AT_MS,
    ...overrides
  }
}

function profile(engine: ConnectionProfile['engine'], readOnly = false): ConnectionProfile {
  return {
    id: `${engine}-connection`,
    name: engine === 'postgresql' ? 'PostgreSQL' : 'MongoDB',
    engine,
    endpoint: 'redacted.example.test',
    database: 'app',
    environment: 'development',
    readOnly,
    demo: false
  }
}

function object(kind: DatabaseObjectNode['kind']): DatabaseObjectNode {
  return { id: `${kind}-target`, name: kind === 'collection' ? 'customers' : 'orders', kind }
}

function coordinatorFor(
  engine: ConnectionProfile['engine'] = 'postgresql',
  kind: DatabaseObjectNode['kind'] = 'table'
): { coordinator: ImportCoordinator; service: ServiceMocks } {
  const service: ServiceMocks = {
    inspectImportTarget: vi.fn(async () => ({ profile: profile(engine), object: object(kind) })),
    importData: vi.fn(async () => importSummary)
  }
  return {
    coordinator: new ImportCoordinator(service as unknown as DatabaseService),
    service
  }
}

async function choose(
  coordinator: ImportCoordinator,
  format: ImportFormat = 'csv',
  connectionId = 'connection-id',
  objectId = 'object-id',
  publishProgress?: ImportProgressPublisher
): Promise<{ token: string; name: string; size: number }> {
  const selection = await coordinator.chooseFile(
    windowStub,
    { connectionId, objectId, format },
    publishProgress
  )
  if (!selection) throw new Error('Expected a selected import file in this test.')
  return selection
}

beforeEach(() => {
  systemMocks.randomUUID.mockReset().mockReturnValue('opaque-import-token')
  systemMocks.createReadStream.mockReset().mockImplementation(() => Readable.from(['data']))
  systemMocks.stat.mockReset().mockResolvedValue(stats())
  systemMocks.showOpenDialog.mockReset().mockResolvedValue({
    canceled: false,
    filePaths: [PRIVATE_PATH]
  })
})

describe('ImportCoordinator target and format validation', () => {
  const matrix: Array<[
    string,
    ConnectionProfile['engine'],
    DatabaseObjectNode['kind'],
    ImportFormat,
    boolean
  ]> = [
    ['PostgreSQL table CSV', 'postgresql', 'table', 'csv', true],
    ['PostgreSQL table JSONL', 'postgresql', 'table', 'jsonl', false],
    ['PostgreSQL collection CSV', 'postgresql', 'collection', 'csv', false],
    ['PostgreSQL collection JSONL', 'postgresql', 'collection', 'jsonl', false],
    ['MongoDB collection JSONL', 'mongodb', 'collection', 'jsonl', true],
    ['MongoDB collection CSV', 'mongodb', 'collection', 'csv', false],
    ['MongoDB table CSV', 'mongodb', 'table', 'csv', false],
    ['MongoDB table JSONL', 'mongodb', 'table', 'jsonl', false]
  ]

  it.each(matrix)('%s is accepted: %s', async (_label, engine, kind, format, valid) => {
    const { coordinator } = coordinatorFor(engine, kind)
    const choosing = coordinator.chooseFile(windowStub, {
      connectionId: `${engine}-connection`,
      objectId: `${kind}-target`,
      format
    })

    if (!valid) {
      await expect(choosing).rejects.toThrow(/format does not match/i)
      expect(systemMocks.showOpenDialog).not.toHaveBeenCalled()
      expect(systemMocks.stat).not.toHaveBeenCalled()
      return
    }

    await expect(choosing).resolves.toMatchObject({ token: 'opaque-import-token', size: FILE_SIZE })
    expect(systemMocks.showOpenDialog).toHaveBeenCalledWith(
      windowStub,
      expect.objectContaining({
        filters: format === 'csv'
          ? [{ name: 'CSV', extensions: ['csv'] }]
          : [{ name: 'JSON Lines', extensions: ['jsonl', 'ndjson'] }]
      })
    )
  })

  it('stops before opening a file dialog when target inspection rejects a read-only connection', async () => {
    const { coordinator, service } = coordinatorFor()
    service.inspectImportTarget.mockRejectedValueOnce(
      new Error('Import is disabled for read-only connections.')
    )

    await expect(choose(coordinator)).rejects.toThrow(/read-only connections/i)
    expect(systemMocks.showOpenDialog).not.toHaveBeenCalled()
    expect(systemMocks.stat).not.toHaveBeenCalled()
  })
})

describe('ImportCoordinator file selection capability', () => {
  it.each([
    ['a directory', stats({ isFile: () => false }) as FakeStats, /non-empty regular file/i],
    ['an empty file', stats({ size: 0 }) as FakeStats, /non-empty regular file/i],
    ['an oversized file', stats({ size: MAX_FILE_BYTES + 1 }) as FakeStats, /limited to 1 GB/i]
  ])('rejects %s', async (_label, fileStats, expected) => {
    const { coordinator } = coordinatorFor()
    systemMocks.stat.mockResolvedValueOnce(fileStats)

    await expect(choose(coordinator)).rejects.toThrow(expected)
  })

  it('returns opaque metadata without exposing the selected local path', async () => {
    const { coordinator } = coordinatorFor()
    const selection = await choose(coordinator)

    expect(selection).toEqual({
      token: 'opaque-import-token',
      name: 'orders.csv',
      size: FILE_SIZE
    })
    expect(selection.token).not.toContain('orders.csv')
    expect(JSON.stringify(selection)).not.toContain('/Users/alice')
  })

  it('returns undefined without reading the filesystem when the chooser is cancelled', async () => {
    const { coordinator } = coordinatorFor()
    systemMocks.showOpenDialog.mockResolvedValueOnce({ canceled: true, filePaths: [] })

    await expect(
      coordinator.chooseFile(windowStub, {
        connectionId: 'connection-id',
        objectId: 'object-id',
        format: 'csv'
      })
    ).resolves.toBeUndefined()
    expect(systemMocks.stat).not.toHaveBeenCalled()
  })

  it('rejects a file changed after review and consumes that selection', async () => {
    const { coordinator, service } = coordinatorFor()
    systemMocks.stat
      .mockResolvedValueOnce(stats())
      .mockResolvedValueOnce(stats({ size: FILE_SIZE + 1 }))
    const selection = await choose(coordinator)

    await expect(coordinator.start({ token: selection.token, hasHeader: true }))
      .rejects.toThrow(/file changed after review/i)
    expect(systemMocks.createReadStream).not.toHaveBeenCalled()
    expect(service.importData).not.toHaveBeenCalled()
    await expect(coordinator.start({ token: selection.token, hasHeader: true }))
      .rejects.toThrow(/selection expired/i)
  })
})

describe('ImportCoordinator single-use and cancellation', () => {
  it('publishes token-bound byte progress with throttled intermediates and a forced final update', async () => {
    vi.useFakeTimers()
    vi.setSystemTime(1_000)
    try {
      const { coordinator, service } = coordinatorFor()
      const updates: ImportProgressUpdate[] = []
      service.importData.mockImplementationOnce(async (
        _connectionId: string,
        _objectId: string,
        _source: Readable,
        options: ImportDataOptions
      ) => {
        await options.onProgress?.({ processed: 1, inserted: 1, failed: 0, bytes: 32 })
        vi.advanceTimersByTime(75)
        await options.onProgress?.({ processed: 2, inserted: 2, failed: 0, bytes: 96 })
        await options.onProgress?.({ processed: 2, inserted: 2, failed: 0, bytes: 112 })
        return importSummary
      })
      const selection = await choose(
        coordinator,
        'csv',
        'connection-a',
        'table-a',
        (update) => {
          updates.push(update)
        }
      )

      await expect(coordinator.start({ token: selection.token, hasHeader: true }))
        .resolves.toEqual(importSummary)

      expect(updates).toEqual([
        {
          token: selection.token,
          processed: 0,
          inserted: 0,
          failed: 0,
          bytes: 0,
          totalBytes: FILE_SIZE
        },
        {
          token: selection.token,
          processed: 2,
          inserted: 2,
          failed: 0,
          bytes: 96,
          totalBytes: FILE_SIZE
        },
        {
          token: selection.token,
          processed: 2,
          inserted: 2,
          failed: 0,
          bytes: FILE_SIZE,
          totalBytes: FILE_SIZE
        }
      ])
    } finally {
      vi.useRealTimers()
    }
  })

  it('never lets progress publisher failures fail an import and ignores late adapter updates', async () => {
    const { coordinator, service } = coordinatorFor()
    const publishProgress = vi.fn(() => {
      throw new Error('renderer was destroyed')
    })
    let adapterProgress: ImportDataOptions['onProgress']
    service.importData.mockImplementationOnce(async (
      _connectionId: string,
      _objectId: string,
      _source: Readable,
      options: ImportDataOptions
    ) => {
      adapterProgress = options.onProgress
      await options.onProgress?.({ processed: 1, inserted: 1, failed: 0, bytes: 64 })
      return importSummary
    })
    const selection = await choose(
      coordinator,
      'csv',
      'connection-a',
      'table-a',
      publishProgress
    )

    await expect(coordinator.start({ token: selection.token, hasHeader: true }))
      .resolves.toEqual(importSummary)
    const callsAfterCompletion = publishProgress.mock.calls.length
    await adapterProgress?.({ processed: 3, inserted: 3, failed: 0, bytes: FILE_SIZE })
    expect(publishProgress).toHaveBeenCalledTimes(callsAfterCompletion)
  })

  it('streams a reviewed file once and rejects sequential token reuse', async () => {
    const { coordinator, service } = coordinatorFor()
    const stream = Readable.from(['row'])
    systemMocks.createReadStream.mockReturnValueOnce(stream)
    systemMocks.stat.mockResolvedValueOnce(stats()).mockResolvedValueOnce(stats())
    const selection = await choose(coordinator, 'csv', 'connection-a', 'table-a')

    await expect(coordinator.start({ token: selection.token, hasHeader: true }))
      .resolves.toEqual(importSummary)
    expect(systemMocks.createReadStream).toHaveBeenCalledWith(PRIVATE_PATH, {
      highWaterMark: 64 * 1024
    })
    expect(service.importData).toHaveBeenCalledWith(
      'connection-a',
      'table-a',
      stream,
      expect.objectContaining({
        format: 'csv',
        hasHeader: true,
        signal: expect.any(AbortSignal)
      })
    )
    await expect(coordinator.start({ token: selection.token, hasHeader: true }))
      .rejects.toThrow(/selection expired/i)
    expect(service.importData).toHaveBeenCalledTimes(1)
  })

  it('allows only one concurrent consumer of a selection token', async () => {
    const { coordinator, service } = coordinatorFor()
    systemMocks.stat
      .mockResolvedValueOnce(stats())
      .mockResolvedValueOnce(stats())
      .mockResolvedValueOnce(stats())
    const selection = await choose(coordinator)

    const first = coordinator.start({ token: selection.token, hasHeader: true })
    const second = coordinator.start({ token: selection.token, hasHeader: true })
    const outcomes = await Promise.allSettled([first, second])

    expect(outcomes.filter((outcome) => outcome.status === 'fulfilled')).toHaveLength(1)
    expect(outcomes.filter((outcome) => outcome.status === 'rejected')).toHaveLength(1)
    expect(service.importData).toHaveBeenCalledTimes(1)
  })

  it('cancels a pending selection before any file stream is opened', async () => {
    const { coordinator, service } = coordinatorFor()
    const selection = await choose(coordinator)

    coordinator.cancel(selection.token)

    await expect(coordinator.start({ token: selection.token, hasHeader: true }))
      .rejects.toThrow(/selection expired/i)
    expect(systemMocks.createReadStream).not.toHaveBeenCalled()
    expect(service.importData).not.toHaveBeenCalled()
  })

  it('cancels while file metadata is being revalidated without opening a stream', async () => {
    const { coordinator, service } = coordinatorFor()
    const revalidation = deferred<FakeStats>()
    systemMocks.stat
      .mockResolvedValueOnce(stats())
      .mockReturnValueOnce(revalidation.promise)
    const selection = await choose(coordinator)
    const running = coordinator.start({ token: selection.token, hasHeader: true })
    await vi.waitFor(() => expect(systemMocks.stat).toHaveBeenCalledTimes(2))

    coordinator.cancel(selection.token)
    revalidation.resolve(stats())

    await expect(running).rejects.toThrow('Import was cancelled.')
    expect(systemMocks.createReadStream).not.toHaveBeenCalled()
    expect(service.importData).not.toHaveBeenCalled()
    await expect(coordinator.start({ token: selection.token, hasHeader: true }))
      .rejects.toThrow(/selection expired/i)
  })

  it('aborts an active import and returns a path-free cancellation error', async () => {
    const { coordinator, service } = coordinatorFor()
    let signal: AbortSignal | undefined
    service.importData.mockImplementationOnce(
      async (
        _connectionId: string,
        _objectId: string,
        _source: Readable,
        options: { signal: AbortSignal }
      ) => {
        signal = options.signal
        return new Promise<ImportResult>((_resolve, reject) => {
          options.signal.addEventListener('abort', () => {
            const error = new Error(`aborted while reading ${PRIVATE_PATH}`)
            error.name = 'AbortError'
            reject(error)
          }, { once: true })
        })
      }
    )
    systemMocks.stat.mockResolvedValueOnce(stats()).mockResolvedValueOnce(stats())
    const selection = await choose(coordinator)
    const running = coordinator.start({ token: selection.token, hasHeader: false })
    await vi.waitFor(() => expect(service.importData).toHaveBeenCalledOnce())

    coordinator.cancel(selection.token)

    await expect(running).rejects.toThrow('Import was cancelled.')
    expect(signal?.aborted).toBe(true)
    const error = await coordinator.start({ token: selection.token, hasHeader: false })
      .catch((caught: unknown) => caught)
    expect((error as Error).message).not.toContain(PRIVATE_PATH)
  })
})

describe('ImportCoordinator safe errors', () => {
  it('does not expose a local path from filesystem errors', async () => {
    const { coordinator } = coordinatorFor()
    systemMocks.stat.mockRejectedValueOnce(
      new Error(`EACCES: permission denied, stat '${PRIVATE_PATH}'`)
    )

    const error = await choose(coordinator).catch((caught: unknown) => caught)

    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).toBe(
      'The selected import file cannot be read. Check its permissions.'
    )
    expect((error as Error).message).not.toContain(PRIVATE_PATH)
  })

  it('redacts a local path from database import errors', async () => {
    const { coordinator, service } = coordinatorFor()
    service.importData.mockRejectedValueOnce(
      new Error(`Driver failed while importing ${PRIVATE_PATH}`)
    )
    systemMocks.stat.mockResolvedValueOnce(stats()).mockResolvedValueOnce(stats())
    const selection = await choose(coordinator)

    const error = await coordinator.start({ token: selection.token, hasHeader: true })
      .catch((caught: unknown) => caught)

    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).not.toContain('/Users/alice')
    expect((error as Error).message).toContain('[local file]')
  })

  it('redacts Windows-style local paths from database import errors', async () => {
    const { coordinator, service } = coordinatorFor()
    service.importData.mockRejectedValueOnce(
      new Error('Driver failed while importing C:\\Users\\alice\\Private Data\\orders.csv')
    )
    systemMocks.stat.mockResolvedValueOnce(stats()).mockResolvedValueOnce(stats())
    const selection = await choose(coordinator)

    const error = await coordinator.start({ token: selection.token, hasHeader: true })
      .catch((caught: unknown) => caught)

    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).not.toContain('C:\\Users\\alice')
    expect((error as Error).message).toContain('[local file]')
  })

  it('cleans up a consumed token when revalidation stat fails', async () => {
    const { coordinator, service } = coordinatorFor()
    systemMocks.stat
      .mockResolvedValueOnce(stats())
      .mockRejectedValueOnce(new Error(`ENOENT: no such file, stat '${PRIVATE_PATH}'`))
    const selection = await choose(coordinator)

    const error = await coordinator.start({ token: selection.token, hasHeader: true })
      .catch((caught: unknown) => caught)

    expect((error as Error).message).toBe('The selected import file is no longer available.')
    expect((error as Error).message).not.toContain(PRIVATE_PATH)
    expect(systemMocks.createReadStream).not.toHaveBeenCalled()
    expect(service.importData).not.toHaveBeenCalled()
    await expect(coordinator.start({ token: selection.token, hasHeader: true }))
      .rejects.toThrow(/selection expired/i)
  })
})

describe('ImportCoordinator selection eviction', () => {
  it('evicts the oldest idle selection when the pending map is full', async () => {
    const { coordinator, service } = coordinatorFor()
    let tokenIndex = 0
    systemMocks.randomUUID.mockImplementation(() => `token-${(tokenIndex += 1)}`)
    service.importData.mockImplementation(() => new Promise<ImportResult>(() => undefined))

    const tokens: string[] = []
    for (let index = 0; index < 20; index += 1) {
      tokens.push((await choose(coordinator)).token)
    }

    let runningSignal: AbortSignal | undefined
    service.importData.mockImplementationOnce(async (
      _connectionId: string,
      _objectId: string,
      _source: Readable,
      options: ImportDataOptions
    ) => {
      runningSignal = options.signal
      return new Promise<ImportResult>(() => undefined)
    })
    void coordinator.start({ token: tokens[5], hasHeader: true })
    await vi.waitFor(() => expect(service.importData).toHaveBeenCalledOnce())

    const extra = await choose(coordinator)

    expect(extra.token).toBe('token-21')
    await expect(coordinator.start({ token: tokens[0], hasHeader: true }))
      .rejects.toThrow(/selection expired/i)
    expect(runningSignal?.aborted).toBe(false)
    coordinator.close()
  })

  it('refuses a new selection while every slot is running instead of aborting one', async () => {
    const { coordinator, service } = coordinatorFor()
    let tokenIndex = 0
    systemMocks.randomUUID.mockImplementation(() => `token-${(tokenIndex += 1)}`)
    const signals: AbortSignal[] = []
    service.importData.mockImplementation(async (
      _connectionId: string,
      _objectId: string,
      _source: Readable,
      options: ImportDataOptions
    ) => {
      if (options.signal) signals.push(options.signal)
      return new Promise<ImportResult>(() => undefined)
    })

    for (let index = 0; index < 20; index += 1) {
      const selection = await choose(coordinator)
      void coordinator.start({ token: selection.token, hasHeader: true })
    }
    await vi.waitFor(() => expect(service.importData).toHaveBeenCalledTimes(20))

    await expect(choose(coordinator)).rejects.toThrow(/too many imports are running/i)
    expect(signals).toHaveLength(20)
    expect(signals.every((signal) => !signal.aborted)).toBe(true)
    coordinator.close()
  })
})
