import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type {
  ConnectionProfile,
  DataRecord,
  DatabaseCommand,
  DatabaseEngine,
  DatabaseObjectNode,
  DatabaseResult,
  ImportProgressUpdate,
  MongoCommand
} from '../../shared/database'
import { DEFAULT_QUERY } from '../../shared/database'
import { AppHeader } from './components/AppHeader'
import { ForgetConnectionDialog } from './components/ForgetConnectionDialog'
import { ImportDialog, type ImportFormat } from './components/ImportDialog'
import { NewConnectionDialog } from './components/NewConnectionDialog'
import { QueryLibraryPanel } from './components/QueryLibraryPanel'
import { RecordEditorDialog } from './components/RecordEditorDialog'
import { Sidebar } from './components/Sidebar'
import { Workspace } from './components/Workspace'
import {
  createQueryLibrary,
  type QueryEntry,
  type QueryLibrary
} from './lib/query-library'
import {
  applyTheme,
  readThemePreference,
  type ThemePreference
} from './lib/theme'

function createRequestId(): string {
  return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`
}

const ENGINE_LABELS: Record<DatabaseEngine, string> = {
  postgresql: 'PostgreSQL',
  mongodb: 'MongoDB',
  mysql: 'MySQL',
  sqlite: 'SQLite'
}

interface PreviewContext {
  connectionId: string
  object: DatabaseObjectNode
  command: DatabaseCommand
}

function commandsMatch(left: DatabaseCommand, right: DatabaseCommand): boolean {
  if (left.engine !== right.engine || left.kind !== right.kind || left.text !== right.text) return false
  if (left.engine === 'mongodb' && right.engine === 'mongodb') {
    return left.collection === right.collection
  }
  return true
}

export default function App(): React.JSX.Element {
  const [connections, setConnections] = useState<ConnectionProfile[]>([])
  const [selectedConnectionId, setSelectedConnectionId] = useState<string>()
  const [objects, setObjects] = useState<DatabaseObjectNode[]>([])
  const [selectedObject, setSelectedObject] = useState<DatabaseObjectNode>()
  const [previewContext, setPreviewContext] = useState<PreviewContext>()
  const [resultEditTarget, setResultEditTarget] = useState<DatabaseObjectNode>()
  const [editingRecord, setEditingRecord] = useState<DataRecord>()
  const [objectsLoading, setObjectsLoading] = useState(false)
  const [query, setQuery] = useState('')
  const [mongoMode, setMongoMode] = useState<MongoCommand['kind']>('find')
  const [mongoCollection, setMongoCollection] = useState('')
  const [result, setResult] = useState<DatabaseResult>()
  const [queryLoading, setQueryLoading] = useState(false)
  const [queryCancelling, setQueryCancelling] = useState(false)
  const [resultExporting, setResultExporting] = useState(false)
  const [queryError, setQueryError] = useState<string>()
  const [appError, setAppError] = useState<string>()
  const [appWarning, setAppWarning] = useState<string>()
  const [appNotice, setAppNotice] = useState<string>()
  const [showNewConnection, setShowNewConnection] = useState(false)
  const [showForgetConnection, setShowForgetConnection] = useState(false)
  const [showQueryLibrary, setShowQueryLibrary] = useState(false)
  const [showImport, setShowImport] = useState(false)
  const [importProgress, setImportProgress] = useState<number>()
  const [sidebarOpen, setSidebarOpen] = useState(true)
  const [themePreference, setThemePreference] = useState<ThemePreference>(() => readThemePreference())
  const [queryLibrary] = useState<QueryLibrary>(() => createQueryLibrary())
  const [queryEntries, setQueryEntries] = useState<QueryEntry[]>(() => queryLibrary.list())
  const activeRequest = useRef<{ connectionId: string; requestId: string } | undefined>(undefined)
  const importTokenRef = useRef<string | undefined>(undefined)
  const selectedConnectionIdRef = useRef<string | undefined>(undefined)
  const objectLoadVersion = useRef(0)
  const objectSelectVersion = useRef(0)
  const pendingLibraryEntry = useRef<QueryEntry | undefined>(undefined)

  const selectedConnection = useMemo(
    () => connections.find((connection) => connection.id === selectedConnectionId),
    [connections, selectedConnectionId]
  )

  useEffect(() => {
    selectedConnectionIdRef.current = selectedConnectionId
  }, [selectedConnectionId])

  useEffect(() => window.dbbbb.onImportProgress((update: ImportProgressUpdate) => {
    if (update.token !== importTokenRef.current) return
    if (
      !Number.isFinite(update.bytes) ||
      !Number.isFinite(update.totalBytes) ||
      update.bytes < 0 ||
      update.totalBytes <= 0
    ) {
      return
    }
    setImportProgress(Math.min(100, Math.max(0, (update.bytes / update.totalBytes) * 100)))
  }), [])

  useEffect(() => {
    let active = true
    window.dbbbb
      .getStartupWarnings()
      .then((warnings) => {
        if (active && warnings.length > 0) setAppWarning(warnings.join(' '))
      })
      .catch(() => {
        if (active) setAppWarning('Saved connection status could not be loaded.')
      })
    window.dbbbb
      .listConnections()
      .then((profiles) => {
        if (!active) return
        setConnections(profiles)
        setSelectedConnectionId(
          (current) => current ??
            profiles.find((profile) => !profile.demo && profile.connected !== false)?.id ??
            profiles.find((profile) => profile.demo)?.id ??
            profiles[0]?.id
        )
      })
      .catch((reason) => {
        if (active) setAppError(reason instanceof Error ? reason.message : 'Could not load connections.')
      })
    return () => {
      active = false
    }
  }, [])

  useEffect(() => {
    const media =
      typeof window.matchMedia === 'function'
        ? window.matchMedia('(prefers-color-scheme: dark)')
        : undefined

    const updateTheme = (): void => {
      applyTheme(themePreference, media?.matches ?? false)
    }

    updateTheme()
    media?.addEventListener('change', updateTheme)
    return () => media?.removeEventListener('change', updateTheme)
  }, [themePreference])

  const anyDialogOpen =
    showNewConnection ||
    showForgetConnection ||
    showQueryLibrary ||
    showImport ||
    editingRecord !== undefined

  useEffect(() => {
    const onShortcut = (event: KeyboardEvent): void => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        if (anyDialogOpen) return
        event.preventDefault()
        setShowQueryLibrary(true)
      }
    }
    window.addEventListener('keydown', onShortcut)
    return () => window.removeEventListener('keydown', onShortcut)
  }, [anyDialogOpen])

  useEffect(() => {
    if (!appNotice) return
    const timeout = window.setTimeout(() => setAppNotice(undefined), 6000)
    return () => window.clearTimeout(timeout)
  }, [appNotice])

  const loadObjects = useCallback(async (connectionId: string): Promise<void> => {
    const version = ++objectLoadVersion.current
    setObjectsLoading(true)
    setObjects([])
    setAppError(undefined)
    try {
      const nextObjects = await window.dbbbb.listObjects(connectionId)
      if (objectLoadVersion.current === version) setObjects(nextObjects)
    } catch (reason) {
      if (objectLoadVersion.current === version) {
        setObjects([])
        setAppError(reason instanceof Error ? reason.message : 'Could not load database objects.')
      }
    } finally {
      if (objectLoadVersion.current === version) setObjectsLoading(false)
    }
  }, [])

  useEffect(() => {
    if (!selectedConnection) return
    const pending = pendingLibraryEntry.current
    const command =
      pending && pending.connectionId === selectedConnection.id
        ? pending.command
        : DEFAULT_QUERY[selectedConnection.engine]
    pendingLibraryEntry.current = undefined
    setQuery(command.text)
    if (command.engine === 'mongodb') {
      setMongoMode(command.kind)
      setMongoCollection(command.collection)
    }
    setResult(undefined)
    setSelectedObject(undefined)
    setPreviewContext(undefined)
    setResultEditTarget(undefined)
    setEditingRecord(undefined)
    setShowImport(false)
    setShowForgetConnection(false)
    setQueryError(undefined)
    if (selectedConnection.connected === false) {
      setObjects([])
      setObjectsLoading(false)
      if (selectedConnection.storageWarning) setAppWarning(selectedConnection.storageWarning)
      return
    }
    void loadObjects(selectedConnection.id)
  }, [loadObjects, selectedConnection])

  useEffect(() => {
    if (selectedConnection?.engine !== 'mongodb') return
    const collections = objects.filter((object) => object.kind === 'collection')
    if (collections.length === 0) return
    setMongoCollection((current) =>
      collections.some((collection) => collection.name === current)
        ? current
        : collections[0].name
    )
  }, [objects, selectedConnection])

  const runQuery = useCallback(async (): Promise<void> => {
    if (!selectedConnection || selectedConnection.connected === false || queryLoading) return
    if (selectedConnection.engine === 'mongodb' && mongoCollection.trim().length === 0) {
      setQueryError('Choose a MongoDB collection before running the query.')
      return
    }
    const requestId = createRequestId()
    const connectionId = selectedConnection.id
    const command: DatabaseCommand =
      selectedConnection.engine === 'mongodb'
        ? { engine: 'mongodb', kind: mongoMode, collection: mongoCollection, text: query }
        : { engine: selectedConnection.engine, kind: 'query', text: query }
    const editablePreview =
      previewContext?.connectionId === connectionId &&
      commandsMatch(previewContext.command, command)
        ? previewContext.object
        : undefined

    setQueryLoading(true)
    setEditingRecord(undefined)
    setResultEditTarget(undefined)
    activeRequest.current = { connectionId, requestId }
    setQueryError(undefined)
    try {
      const nextResult = await window.dbbbb.execute({
        connectionId,
        requestId,
        command
      })
      if (selectedConnectionIdRef.current === connectionId) {
        setResult(nextResult)
        setResultEditTarget(
          editablePreview &&
          // Record editing is implemented only for PostgreSQL and MongoDB.
          (selectedConnection.engine === 'postgresql' || selectedConnection.engine === 'mongodb') &&
          nextResult.meta.source === 'database' &&
          !selectedConnection.readOnly &&
          !selectedConnection.demo
            ? editablePreview
            : undefined
        )
      }
      try {
        queryLibrary.add({
          connectionId,
          engine: command.engine,
          command
        })
        setQueryEntries(queryLibrary.list())
      } catch (reason) {
        setAppError(reason instanceof Error ? reason.message : 'Could not save query history.')
      }
    } catch (reason) {
      if (selectedConnectionIdRef.current === connectionId) {
        setQueryError(reason instanceof Error ? reason.message : 'The query failed.')
      }
    } finally {
      if (activeRequest.current?.requestId === requestId) {
        activeRequest.current = undefined
        setQueryLoading(false)
        setQueryCancelling(false)
      }
    }
  }, [mongoCollection, mongoMode, previewContext, query, queryLibrary, queryLoading, selectedConnection])

  const cancelQuery = useCallback(async (): Promise<void> => {
    const request = activeRequest.current
    if (!request || queryCancelling) return
    setQueryCancelling(true)
    try {
      await window.dbbbb.cancel(request)
    } catch (reason) {
      setQueryError(reason instanceof Error ? reason.message : 'Could not cancel the query.')
      setQueryCancelling(false)
    }
  }, [queryCancelling])

  const selectObject = async (object: DatabaseObjectNode): Promise<void> => {
    if (!selectedConnection || selectedConnection.connected === false) return
    const version = ++objectSelectVersion.current
    const connectionId = selectedConnection.id
    setQueryError(undefined)
    setPreviewContext(undefined)
    setResultEditTarget(undefined)
    setEditingRecord(undefined)
    try {
      const command = await window.dbbbb.previewObject({
        connectionId,
        objectId: object.id
      })
      if (objectSelectVersion.current !== version || selectedConnectionIdRef.current !== connectionId) return
      setQuery(command.text)
      if (command.engine === 'mongodb') {
        setMongoMode(command.kind)
        setMongoCollection(command.collection)
      }
      setSelectedObject(object)
      setPreviewContext({ connectionId, object, command })
      setResult(undefined)
    } catch (reason) {
      if (objectSelectVersion.current !== version || selectedConnectionIdRef.current !== connectionId) return
      setQueryError(reason instanceof Error ? reason.message : 'Could not preview this object.')
    }
  }

  const toggleTheme = (): void => {
    setThemePreference((current) =>
      current === 'light' ? 'dark' : current === 'dark' ? 'system' : 'light'
    )
  }

  const changeQuery = (nextQuery: string): void => {
    setQuery(nextQuery)
    setPreviewContext(undefined)
    setResultEditTarget(undefined)
    setEditingRecord(undefined)
  }

  const changeMongoMode = (nextMode: MongoCommand['kind']): void => {
    setMongoMode(nextMode)
    setPreviewContext(undefined)
    setResultEditTarget(undefined)
    setEditingRecord(undefined)
    setQuery((current) => {
      const normalized = current.trim()
      if (nextMode === 'aggregate' && normalized === '{}') {
        return '[\n  { "$match": {} }\n]'
      }
      if (nextMode === 'find' && (normalized === '[]' || normalized === '[\n  { "$match": {} }\n]')) {
        return '{}'
      }
      return current
    })
    setResult(undefined)
    setQueryError(undefined)
  }

  const changeMongoCollection = (collection: string): void => {
    setMongoCollection(collection)
    setPreviewContext(undefined)
    setResultEditTarget(undefined)
    setEditingRecord(undefined)
  }

  const exportResult = async (): Promise<void> => {
    if (!selectedConnection || !result || resultExporting) return
    setResultExporting(true)
    setAppError(undefined)
    setAppNotice(undefined)
    try {
      const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)
      const response = await window.dbbbb.exportResult({
        result,
        suggestedBaseName: `${selectedConnection.name}-${selectedConnection.database}-${timestamp}`
      })
      if (!response.canceled) {
        setAppNotice(`Exported ${response.rows ?? result.meta.count} items.`)
      }
    } catch (reason) {
      setAppError(reason instanceof Error ? reason.message : 'Could not export the result.')
    } finally {
      setResultExporting(false)
    }
  }

  const onConnectionCreated = (profile: ConnectionProfile): void => {
    setConnections((current) => [...current, profile])
    setSelectedConnectionId(profile.id)
    setShowNewConnection(false)
    if (profile.storageWarning) setAppWarning(profile.storageWarning)
    else if (profile.saved) {
      setAppWarning(undefined)
      setAppNotice('Connection saved with protected OS credential storage.')
    }
  }

  const selectLibraryEntry = (entry: QueryEntry): void => {
    const originalConnection = connections.find(
      (candidate) => candidate.id === entry.connectionId && candidate.connected !== false
    )
    const connection =
      originalConnection ??
      (selectedConnection?.engine === entry.engine && selectedConnection.connected !== false
        ? selectedConnection
        : undefined) ??
      connections.find(
        (candidate) => candidate.engine === entry.engine && candidate.connected !== false
      )
    if (!connection) {
      setAppError(`Connect to ${ENGINE_LABELS[entry.engine]} before opening this query.`)
      return
    }
    if (connection.engine !== entry.engine) {
      setAppError('The saved query does not match its original database engine.')
      return
    }

    setPreviewContext(undefined)
    setResultEditTarget(undefined)
    setEditingRecord(undefined)

    if (!originalConnection) {
      setAppNotice(`The original session is closed; opened this query on ${connection.name}.`)
    }

    if (connection.id === selectedConnectionId) {
      setQuery(entry.command.text)
      if (entry.command.engine === 'mongodb') {
        setMongoMode(entry.command.kind)
        setMongoCollection(entry.command.collection)
      }
      setResult(undefined)
      setQueryError(undefined)
    } else {
      pendingLibraryEntry.current = entry
      setSelectedConnectionId(connection.id)
    }
    setShowQueryLibrary(false)
  }

  const refreshQueryLibrary = (): void => setQueryEntries(queryLibrary.list())

  const chooseImportFile = async (format: ImportFormat): Promise<{ name: string; size: number } | undefined> => {
    if (!selectedConnection || selectedConnection.connected === false || !selectedObject) return undefined
    const previousToken = importTokenRef.current
    importTokenRef.current = undefined
    if (previousToken) await window.dbbbb.cancelImport(previousToken)
    const selection = await window.dbbbb.chooseImportFile({
      connectionId: selectedConnection.id,
      objectId: selectedObject.id,
      format
    })
    importTokenRef.current = selection?.token
    return selection ? { name: selection.name, size: selection.size } : undefined
  }

  const startImport = async (hasHeader: boolean): Promise<void> => {
    const token = importTokenRef.current
    if (!token) throw new Error('Choose an import file first.')
    setImportProgress(0)
    setAppError(undefined)
    try {
      const summary = await window.dbbbb.startImport({ token, hasHeader })
      setAppNotice(`Imported ${summary.inserted} of ${summary.processed} items.`)
      if (selectedConnection) void loadObjects(selectedConnection.id)
    } finally {
      if (importTokenRef.current === token) {
        importTokenRef.current = undefined
      }
      setImportProgress(undefined)
    }
  }

  const closeImport = (): void => {
    const token = importTokenRef.current
    importTokenRef.current = undefined
    if (token) void window.dbbbb.cancelImport(token)
    setImportProgress(undefined)
    setShowImport(false)
  }

  const applyRecordUpdate = async (current: DataRecord): Promise<void> => {
    if (
      !selectedConnection ||
      selectedConnection.connected === false ||
      !resultEditTarget ||
      !editingRecord
    ) {
      throw new Error('The editable result is no longer available. Run the object preview again.')
    }
    await window.dbbbb.applyDataChange({
      connectionId: selectedConnection.id,
      objectId: resultEditTarget.id,
      engine: selectedConnection.engine,
      action: 'update',
      original: editingRecord,
      current
    })
    setEditingRecord(undefined)
    setAppNotice('Applied one optimistic record update.')
    await runQuery()
  }

  const deleteRecord = async (): Promise<void> => {
    if (
      !selectedConnection ||
      selectedConnection.connected === false ||
      !resultEditTarget ||
      !editingRecord
    ) {
      throw new Error('The editable result is no longer available. Run the object preview again.')
    }
    await window.dbbbb.applyDataChange({
      connectionId: selectedConnection.id,
      objectId: resultEditTarget.id,
      engine: selectedConnection.engine,
      action: 'delete',
      original: editingRecord
    })
    setEditingRecord(undefined)
    setAppNotice('Deleted one record after an optimistic concurrency check.')
    await runQuery()
  }

  const removeConnectionFromUi = (connectionId: string): void => {
    const nextConnections = connections.filter((profile) => profile.id !== connectionId)
    objectLoadVersion.current += 1
    setConnections(nextConnections)
    setSelectedConnectionId(
      nextConnections.find((profile) => !profile.demo && profile.connected !== false)?.id ??
      nextConnections.find((profile) => profile.demo)?.id ??
      nextConnections[0]?.id
    )
    setObjects([])
    setResult(undefined)
    setSelectedObject(undefined)
    setPreviewContext(undefined)
    setResultEditTarget(undefined)
    setEditingRecord(undefined)
  }

  const disconnectSelected = async (): Promise<void> => {
    if (!selectedConnection || selectedConnection.connected === false || queryLoading) return
    setAppError(undefined)
    try {
      await window.dbbbb.disconnect(selectedConnection.id)
      removeConnectionFromUi(selectedConnection.id)
    } catch (reason) {
      setAppError(reason instanceof Error ? reason.message : 'Could not disconnect.')
    }
  }

  const forgetSelected = async (): Promise<void> => {
    if (!selectedConnection?.saved || queryLoading) return
    await window.dbbbb.forgetConnection(selectedConnection.id)
    removeConnectionFromUi(selectedConnection.id)
    setShowForgetConnection(false)
    setAppNotice('Removed the saved connection and its encrypted credentials.')
  }

  return (
    <div className={`app-shell${sidebarOpen ? '' : ' sidebar-collapsed'}`}>
      <AppHeader
        connection={selectedConnection}
        themePreference={themePreference}
        sidebarOpen={sidebarOpen}
        onToggleSidebar={() => setSidebarOpen((current) => !current)}
        onToggleTheme={toggleTheme}
        onOpenQueryLibrary={() => setShowQueryLibrary(true)}
        queryLibraryCount={queryEntries.length}
        onDisconnect={() => void disconnectSelected()}
        onForget={() => setShowForgetConnection(true)}
        disconnectDisabled={queryLoading}
      />

      <div className="app-body">
        {sidebarOpen && (
          <Sidebar
            connections={connections}
            selectedConnectionId={selectedConnectionId}
            objects={objects}
            objectsLoading={objectsLoading}
            connectionsDisabled={queryLoading}
            onSelectConnection={setSelectedConnectionId}
            onSelectObject={(object) => void selectObject(object)}
            onNewConnection={() => setShowNewConnection(true)}
            onRefreshObjects={() => selectedConnection && void loadObjects(selectedConnection.id)}
          />
        )}

        <Workspace
          connection={selectedConnection}
          importTarget={
            selectedObject &&
            ((selectedConnection?.engine === 'postgresql' && selectedObject.kind === 'table') ||
              (selectedConnection?.engine === 'mongodb' && selectedObject.kind === 'collection'))
              ? selectedObject
              : undefined
          }
          query={query}
          mongoMode={mongoMode}
          mongoCollection={mongoCollection}
          result={result}
          loading={queryLoading}
          cancelling={queryCancelling}
          exporting={resultExporting}
          editingEnabled={Boolean(resultEditTarget && result?.meta.source === 'database')}
          error={queryError}
          onQueryChange={changeQuery}
          onMongoModeChange={changeMongoMode}
          onMongoCollectionChange={changeMongoCollection}
          onRun={() => void runQuery()}
          onCancel={() => void cancelQuery()}
          onExport={() => void exportResult()}
          onImport={() => setShowImport(true)}
          onEditRecord={setEditingRecord}
        />
      </div>

      <footer className="status-bar">
        {selectedConnection?.connected === false ? (
          <span className="status-unavailable"><i /> Unavailable</span>
        ) : selectedConnection ? (
          <span className="status-connected"><i /> {selectedConnection.demo ? 'Demo' : 'Connected'}</span>
        ) : (
          <span>Not connected</span>
        )}
        {selectedConnection && selectedConnection.connected !== false && (
          <span>
            {selectedConnection.readOnly
              ? 'Read-only session'
              : selectedConnection.engine === 'mongodb'
                ? 'Standard session'
                : 'Auto-commit'}
          </span>
        )}
        <span className="status-spacer" />
        {appError && <span className="status-error">{appError}</span>}
        {!appError && appWarning && <span className="status-warning">{appWarning}</span>}
        {!appError && !appWarning && appNotice && <span className="status-notice">{appNotice}</span>}
        {selectedConnection && (
          <span>{ENGINE_LABELS[selectedConnection.engine]}</span>
        )}
        <span>UTF-8</span>
      </footer>

      {showNewConnection && (
        <NewConnectionDialog
          onClose={() => setShowNewConnection(false)}
          onConnected={onConnectionCreated}
        />
      )}

      {showForgetConnection && selectedConnection?.saved && (
        <ForgetConnectionDialog
          connection={selectedConnection}
          onConfirm={forgetSelected}
          onClose={() => setShowForgetConnection(false)}
        />
      )}

      {showQueryLibrary && (
        <QueryLibraryPanel
          entries={queryEntries}
          onSelect={selectLibraryEntry}
          onToggleFavorite={(id) => {
            queryLibrary.toggleFavorite(id)
            refreshQueryLibrary()
          }}
          onRemove={(id) => {
            queryLibrary.remove(id)
            refreshQueryLibrary()
          }}
          onClearHistory={() => {
            queryLibrary.clearHistory()
            refreshQueryLibrary()
          }}
          onClose={() => setShowQueryLibrary(false)}
        />
      )}

      {showImport && selectedConnection && selectedObject && (
        <ImportDialog
          connection={selectedConnection}
          target={selectedObject}
          onChooseFile={chooseImportFile}
          onImport={({ hasHeader }) => startImport(hasHeader)}
          progress={importProgress}
          onCancel={() => {
            const token = importTokenRef.current
            if (token) void window.dbbbb.cancelImport(token)
          }}
          onClose={closeImport}
        />
      )}

      {editingRecord && resultEditTarget && selectedConnection && (
        <RecordEditorDialog
          connection={selectedConnection}
          target={resultEditTarget}
          original={editingRecord}
          onApply={applyRecordUpdate}
          onDelete={deleteRecord}
          onClose={() => setEditingRecord(undefined)}
        />
      )}
    </div>
  )
}
