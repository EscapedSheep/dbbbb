import { Braces, Pencil, Rows3 } from 'lucide-react'
import type { DataRecord, DatabaseResult, ResultColumn, WireValue } from '../../../shared/database'

interface ResultViewProps {
  result?: DatabaseResult
  loading: boolean
  error?: string
  editingEnabled?: boolean
  onEditRecord?: (record: DataRecord) => void
}

function displayCell(value: WireValue): string {
  if (value === null) return 'NULL'
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}

export function rowToRecord(columns: ResultColumn[], row: WireValue[]): DataRecord | undefined {
  if (columns.length !== row.length) return undefined
  const record = Object.create(null) as DataRecord
  for (let index = 0; index < columns.length; index += 1) {
    const label = columns[index].label
    if (Object.hasOwn(record, label)) return undefined
    Object.defineProperty(record, label, {
      configurable: true,
      enumerable: true,
      writable: true,
      value: row[index]
    })
  }
  return record
}

export function ResultView({
  result,
  loading,
  error,
  editingEnabled = false,
  onEditRecord
}: ResultViewProps): React.JSX.Element {
  if (loading) {
    return (
      <div className="result-loading" aria-live="polite">
        <div className="skeleton-line wide" />
        <div className="skeleton-line" />
        <div className="skeleton-line medium" />
        <span>Running query…</span>
      </div>
    )
  }

  if (error) {
    return (
      <div className="result-empty result-error" role="alert">
        <strong>Query failed</strong>
        <p>{error}</p>
      </div>
    )
  }

  if (!result) {
    return (
      <div className="result-empty">
        <Rows3 size={24} strokeWidth={1.4} />
        <strong>No result yet</strong>
        <p>Run the current query with Ctrl/⌘ + Enter.</p>
      </div>
    )
  }

  if (result.kind === 'rows') {
    return (
      <div className="result-scroll">
        <table className="result-table" aria-label="Query result">
          <thead>
            <tr>
              <th className="row-index" aria-label="Row number" />
              {result.columns.map((column) => (
                <th key={column.key} scope="col">
                  <span>{column.label}</span>
                  <small>{column.dataType}</small>
                </th>
              ))}
              {editingEnabled && <th className="row-action-heading" aria-label="Row actions" />}
            </tr>
          </thead>
          <tbody>
            {result.rows.map((row, rowIndex) => {
              const record = editingEnabled ? rowToRecord(result.columns, row) : undefined
              return (
                <tr key={rowIndex}>
                  <td className="row-index">{rowIndex + 1}</td>
                  {row.map((cell, columnIndex) => (
                    <td className={cell === null ? 'null-cell' : ''} key={columnIndex}>
                      {displayCell(cell)}
                    </td>
                  ))}
                  {editingEnabled && (
                    <td className="row-action-cell">
                      <button
                        className="row-edit-button"
                        type="button"
                        onClick={() => record && onEditRecord?.(record)}
                        disabled={!record}
                        aria-label={`Edit row ${rowIndex + 1}`}
                      >
                        <Pencil size={13} /> Edit
                      </button>
                    </td>
                  )}
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    )
  }

  return (
    <div className="document-results" aria-label="MongoDB documents">
      {result.documents.map((document, index) => (
        <article className="document-row" key={index}>
          <div className="document-index">
            <Braces size={14} />
            <span>{index + 1}</span>
            {editingEnabled && (
              <button
                className="document-edit-button"
                type="button"
                onClick={() => onEditRecord?.(document)}
                aria-label={`Edit document ${index + 1}`}
              >
                <Pencil size={13} /> Edit
              </button>
            )}
          </div>
          <pre>{JSON.stringify(document, null, 2)}</pre>
        </article>
      ))}
    </div>
  )
}
