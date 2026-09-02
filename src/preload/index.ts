import { contextBridge, ipcRenderer } from 'electron'
import type { IpcRendererEvent } from 'electron'
import type {
  ApplyDataChangeRequest,
  CancelRequest,
  ChooseImportFileRequest,
  ConnectionDraft,
  ConnectionInput,
  ExecuteRequest,
  ExportResultRequest,
  ImportProgressUpdate,
  StartImportRequest,
  DbbbbApi,
  PreviewRequest,
  StartupAction
} from '../shared/database'
import { IPC_CHANNELS } from '../shared/database'

let activeImportProgressUnsubscribe: (() => void) | undefined
let activeStartupActionUnsubscribe: (() => void) | undefined

const api: DbbbbApi = {
  listConnections: () => ipcRenderer.invoke(IPC_CHANNELS.listConnections),
  getStartupWarnings: () => ipcRenderer.invoke(IPC_CHANNELS.getStartupWarnings),
  connect: (input: ConnectionInput) => ipcRenderer.invoke(IPC_CHANNELS.connect, input),
  createDemoConnection: (draft: ConnectionDraft) =>
    ipcRenderer.invoke(IPC_CHANNELS.createDemoConnection, draft),
  disconnect: (connectionId: string) => ipcRenderer.invoke(IPC_CHANNELS.disconnect, connectionId),
  forgetConnection: (connectionId: string) =>
    ipcRenderer.invoke(IPC_CHANNELS.forgetConnection, connectionId),
  listObjects: (connectionId: string) =>
    ipcRenderer.invoke(IPC_CHANNELS.listObjects, connectionId),
  previewObject: (request: PreviewRequest) =>
    ipcRenderer.invoke(IPC_CHANNELS.previewObject, request),
  execute: (request: ExecuteRequest) => ipcRenderer.invoke(IPC_CHANNELS.execute, request),
  cancel: (request: CancelRequest) => ipcRenderer.invoke(IPC_CHANNELS.cancel, request),
  applyDataChange: (request: ApplyDataChangeRequest) =>
    ipcRenderer.invoke(IPC_CHANNELS.applyDataChange, request),
  exportResult: (request: ExportResultRequest) =>
    ipcRenderer.invoke(IPC_CHANNELS.exportResult, request),
  chooseImportFile: (request: ChooseImportFileRequest) =>
    ipcRenderer.invoke(IPC_CHANNELS.chooseImportFile, request),
  startImport: (request: StartImportRequest) =>
    ipcRenderer.invoke(IPC_CHANNELS.startImport, request),
  cancelImport: (token: string) => ipcRenderer.invoke(IPC_CHANNELS.cancelImport, token),
  onImportProgress: (listener: (update: ImportProgressUpdate) => void) => {
    if (typeof listener !== 'function') {
      throw new TypeError('Import progress listener must be a function.')
    }
    // Only one progress stream is live at a time; drop a previous subscription
    // so repeated mounts cannot accumulate listeners.
    activeImportProgressUnsubscribe?.()
    const wrapped = (_event: IpcRendererEvent, update: ImportProgressUpdate): void => {
      listener(update)
    }
    ipcRenderer.on(IPC_CHANNELS.importProgress, wrapped)
    let subscribed = true
    const unsubscribe = (): void => {
      if (!subscribed) return
      subscribed = false
      ipcRenderer.removeListener(IPC_CHANNELS.importProgress, wrapped)
      if (activeImportProgressUnsubscribe === unsubscribe) {
        activeImportProgressUnsubscribe = undefined
      }
    }
    activeImportProgressUnsubscribe = unsubscribe
    return unsubscribe
  },
  onStartupAction: (listener: (action: StartupAction) => void) => {
    if (typeof listener !== 'function') {
      throw new TypeError('Startup action listener must be a function.')
    }
    // Only one startup action stream is live at a time; drop a previous
    // subscription so repeated mounts cannot accumulate listeners.
    activeStartupActionUnsubscribe?.()
    const wrapped = (_event: IpcRendererEvent, action: StartupAction): void => {
      listener(action)
    }
    ipcRenderer.on(IPC_CHANNELS.startupAction, wrapped)
    let subscribed = true
    const unsubscribe = (): void => {
      if (!subscribed) return
      subscribed = false
      ipcRenderer.removeListener(IPC_CHANNELS.startupAction, wrapped)
      if (activeStartupActionUnsubscribe === unsubscribe) {
        activeStartupActionUnsubscribe = undefined
      }
    }
    activeStartupActionUnsubscribe = unsubscribe
    return unsubscribe
  }
}

contextBridge.exposeInMainWorld('dbbbb', api)
