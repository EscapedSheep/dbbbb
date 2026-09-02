// @vitest-environment node
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { IpcRendererEvent } from 'electron'
import type { ImportProgressUpdate, DbbbbApi } from '../shared/database'
import { IPC_CHANNELS } from '../shared/database'

const electronMocks = vi.hoisted(() => ({
  exposeInMainWorld: vi.fn(),
  invoke: vi.fn(),
  on: vi.fn(),
  removeListener: vi.fn()
}))

vi.mock('electron', () => ({
  contextBridge: { exposeInMainWorld: electronMocks.exposeInMainWorld },
  ipcRenderer: {
    invoke: electronMocks.invoke,
    on: electronMocks.on,
    removeListener: electronMocks.removeListener
  }
}))

import './index'

function exposedApi(): DbbbbApi {
  const exposed = electronMocks.exposeInMainWorld.mock.calls[0]?.[1]
  if (!exposed) throw new Error('Expected the preload API to be exposed.')
  return exposed as DbbbbApi
}

beforeEach(() => {
  electronMocks.invoke.mockClear()
  electronMocks.on.mockClear()
  electronMocks.removeListener.mockClear()
})

const INVOKE_METHOD_NAMES = [
  'listConnections',
  'getStartupWarnings',
  'connect',
  'createDemoConnection',
  'disconnect',
  'forgetConnection',
  'listObjects',
  'previewObject',
  'execute',
  'cancel',
  'applyDataChange',
  'exportResult',
  'chooseImportFile',
  'startImport',
  'cancelImport'
] as const

describe('preload invoke contract', () => {
  it.each(INVOKE_METHOD_NAMES)(
    '%s invokes its matching IPC channel with the original arguments',
    (name) => {
      const api = exposedApi()
      const method = api[name] as (...args: unknown[]) => Promise<unknown>
      const takesArgument = name !== 'listConnections' && name !== 'getStartupWarnings'
      const argument = { marker: `argument-for-${name}` }

      if (takesArgument) {
        void method(argument)
        expect(electronMocks.invoke).toHaveBeenCalledOnce()
        expect(electronMocks.invoke).toHaveBeenCalledWith(IPC_CHANNELS[name], argument)
        expect(electronMocks.invoke.mock.calls[0]?.[1]).toBe(argument)
      } else {
        void method()
        expect(electronMocks.invoke).toHaveBeenCalledOnce()
        expect(electronMocks.invoke).toHaveBeenCalledWith(IPC_CHANNELS[name])
        expect(electronMocks.invoke.mock.calls[0]).toHaveLength(1)
      }
    }
  )

  it('exposes exactly the DbbbbApi surface without extra or missing keys', () => {
    expect(Object.keys(exposedApi()).sort()).toEqual(
      [...INVOKE_METHOD_NAMES, 'onImportProgress'].sort()
    )
  })
})

describe('preload import progress subscription', () => {
  it('forwards typed progress without exposing the Electron event and unsubscribes idempotently', () => {
    const listener = vi.fn()
    const api = exposedApi()
    const update: ImportProgressUpdate = {
      token: 'opaque-token',
      processed: 10,
      inserted: 9,
      failed: 1,
      bytes: 512,
      totalBytes: 1024
    }

    const unsubscribe = api.onImportProgress(listener)
    expect(electronMocks.on).toHaveBeenCalledWith(
      IPC_CHANNELS.importProgress,
      expect.any(Function)
    )
    const wrapped = electronMocks.on.mock.calls[0]?.[1] as (
      event: IpcRendererEvent,
      progress: ImportProgressUpdate
    ) => void
    const electronEvent = { senderId: 42 } as unknown as IpcRendererEvent
    wrapped(electronEvent, update)

    expect(listener).toHaveBeenCalledWith(update)
    expect(listener).not.toHaveBeenCalledWith(electronEvent, update)

    unsubscribe()
    unsubscribe()
    expect(electronMocks.removeListener).toHaveBeenCalledOnce()
    expect(electronMocks.removeListener).toHaveBeenCalledWith(
      IPC_CHANNELS.importProgress,
      wrapped
    )
  })

  it('rejects a non-function listener before registering it', () => {
    const api = exposedApi()

    expect(() => api.onImportProgress(undefined as never)).toThrow(/must be a function/i)
    expect(electronMocks.on).not.toHaveBeenCalled()
  })

  it('unsubscribes a previous listener when subscribing again', () => {
    const api = exposedApi()

    const first = api.onImportProgress(vi.fn())
    const firstWrapped = electronMocks.on.mock.calls[0]?.[1]
    const second = api.onImportProgress(vi.fn())
    const secondWrapped = electronMocks.on.mock.calls[1]?.[1]

    expect(electronMocks.removeListener).toHaveBeenCalledOnce()
    expect(electronMocks.removeListener).toHaveBeenCalledWith(
      IPC_CHANNELS.importProgress,
      firstWrapped
    )

    first()
    expect(electronMocks.removeListener).toHaveBeenCalledOnce()

    second()
    expect(electronMocks.removeListener).toHaveBeenCalledTimes(2)
    expect(electronMocks.removeListener).toHaveBeenLastCalledWith(
      IPC_CHANNELS.importProgress,
      secondWrapped
    )
  })
})
