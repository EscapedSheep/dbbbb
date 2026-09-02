import { Braces, Code2, Download, Eye, Play, Rows3, Square, Unplug, Upload } from 'lucide-react'
import type {
  ConnectionProfile,
  DataRecord,
  DatabaseObjectNode,
  DatabaseResult,
  MongoCommand
} from '../../../shared/database'
import { ResultView } from './ResultView'

interface WorkspaceProps {
  connection?: ConnectionProfile
  importTarget?: DatabaseObjectNode
  query: string
  mongoMode: MongoCommand['kind']
  mongoCollection: string
  result?: DatabaseResult
  loading: boolean
  cancelling: boolean
  exporting: boolean
  editingEnabled: boolean
  error?: string
  onQueryChange: (query: string) => void
  onMongoModeChange: (mode: MongoCommand['kind']) => void
  onMongoCollectionChange: (collection: string) => void
  onRun: () => void
  onCancel: () => void
  onExport: () => void
  onImport: () => void
  onEditRecord: (record: DataRecord) => void
}

export function Workspace({
  connection,
  importTarget,
  query,
  mongoMode,
  mongoCollection,
  result,
  loading,
  cancelling,
  exporting,
  editingEnabled,
  error,
  onQueryChange,
  onMongoModeChange,
  onMongoCollectionChange,
  onRun,
  onCancel,
  onExport,
  onImport,
  onEditRecord
}: WorkspaceProps): React.JSX.Element {
  if (!connection) {
    return (
      <main className="workspace workspace-empty">
        <div>
          <Code2 size={28} strokeWidth={1.4} />
          <h1>Select a connection</h1>
          <p>Choose a database connection from the navigator to open a query workspace.</p>
        </div>
      </main>
    )
  }

  if (connection.connected === false) {
    return (
      <main className="workspace workspace-empty" aria-label="Unavailable saved connection">
        <div>
          <Unplug size={28} strokeWidth={1.4} />
          <h1>Saved connection unavailable</h1>
          <p>
            Check the server, network, certificate, and credentials, then restart dbbbb to retry.
            Use Forget to remove the protected profile before creating a replacement.
          </p>
        </div>
      </main>
    )
  }

  const lines = query.split('\n')
  const queryLanguage = connection.engine === 'mongodb' ? 'Mongo filter' : 'SQL'

  const handleEditorKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>): void => {
    if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
      event.preventDefault()
      onRun()
    }
  }

  return (
    <main className="workspace">
      <div className="tab-strip" aria-label="Current query">
        <span className="query-tab active">
          <Code2 size={14} />
          Query
        </span>
      </div>

      <section className="query-panel" aria-label="Query editor">
        <div className="query-toolbar">
          <div className="toolbar-leading">
            <span className="language-label">{queryLanguage}</span>
            {connection.engine === 'mongodb' && (
              <>
                <label className="mongo-collection-field">
                  <span className="sr-only">MongoDB collection</span>
                  <input
                    value={mongoCollection}
                    onChange={(event) => onMongoCollectionChange(event.target.value)}
                    placeholder="collection"
                    required
                  />
                </label>
                <div className="segmented-control" aria-label="MongoDB operation">
                  <button
                    className={mongoMode === 'find' ? 'active' : ''}
                    type="button"
                    onClick={() => onMongoModeChange('find')}
                  >
                    find
                  </button>
                  <button
                    className={mongoMode === 'aggregate' ? 'active' : ''}
                    type="button"
                    onClick={() => onMongoModeChange('aggregate')}
                  >
                    aggregate
                  </button>
                </div>
              </>
            )}
            {connection.readOnly && (
              <span className="inline-status">
                <Eye size={13} /> Read only
              </span>
            )}
          </div>
          <div className="toolbar-actions">
            {importTarget && (
              <button
                className="secondary-button import-button"
                type="button"
                onClick={onImport}
                disabled={connection.readOnly || connection.demo || loading}
                title={
                  connection.demo
                    ? 'Connect to a real database to import data.'
                    : connection.readOnly
                      ? 'Disable the read-only guardrail to import data.'
                      : `Import into ${importTarget.name}`
                }
              >
                <Upload size={13} />
                Import
              </button>
            )}
            {loading ? (
              <button
                className="secondary-button cancel-button"
                type="button"
                onClick={onCancel}
                disabled={cancelling}
              >
                {cancelling ? <span className="button-spinner" /> : <Square size={12} fill="currentColor" />}
                {cancelling ? 'Cancelling' : 'Cancel'}
              </button>
            ) : (
              <button
                className="primary-button run-button"
                type="button"
                onClick={onRun}
                disabled={connection.engine === 'mongodb' && mongoCollection.trim().length === 0}
              >
                <Play size={14} fill="currentColor" />
                Run
                <kbd>Ctrl/⌘ ↵</kbd>
              </button>
            )}
          </div>
        </div>

        <div className="editor-wrap">
          <div className="line-numbers" aria-hidden="true">
            {lines.map((_, index) => (
              <span key={index}>{index + 1}</span>
            ))}
          </div>
          <textarea
            className="query-editor"
            value={query}
            onChange={(event) => onQueryChange(event.target.value)}
            onKeyDown={handleEditorKeyDown}
            aria-label={`${queryLanguage} editor`}
            spellCheck={false}
          />
        </div>
      </section>

      <section className="result-panel" aria-label="Query results">
        <div className="result-toolbar">
          <div className="result-title">
            {result?.kind === 'documents' ? <Braces size={14} /> : <Rows3 size={14} />}
            <strong>Results</strong>
            {result && <span className="result-count">{result.meta.count} items</span>}
          </div>
          <div className="result-meta" aria-live="polite">
            {result?.meta.source === 'demo' && <span className="badge badge-accent">Demo data</span>}
            {result && <span>{result.meta.elapsedMs} ms</span>}
            {result?.meta.truncated && <span className="badge badge-warning">Truncated</span>}
            {result && (
              <button
                className="secondary-button result-export-button"
                type="button"
                onClick={onExport}
                disabled={exporting || loading}
              >
                {exporting ? <span className="button-spinner" /> : <Download size={13} />}
                {exporting ? 'Exporting' : `Export ${result.kind === 'rows' ? 'CSV' : 'JSONL'}`}
              </button>
            )}
          </div>
        </div>
        <ResultView
          result={result}
          loading={loading}
          error={error}
          editingEnabled={editingEnabled}
          onEditRecord={onEditRecord}
        />
      </section>
    </main>
  )
}
