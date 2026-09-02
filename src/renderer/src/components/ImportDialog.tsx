import { useEffect, useRef, useState } from 'react'
import { CheckCircle2, FileUp, ShieldAlert, X } from 'lucide-react'
import type { ConnectionProfile, DatabaseObjectNode } from '../../../shared/database'
import { useRestoreFocus } from './useRestoreFocus'

export type ImportFormat = 'csv' | 'jsonl'

export interface ImportFileInfo {
  name: string
  size: number
}

export interface ImportOptions {
  format: ImportFormat
  hasHeader: boolean
}

export interface ImportDialogProps {
  connection: ConnectionProfile
  target: DatabaseObjectNode
  onChooseFile: (format: ImportFormat) => Promise<ImportFileInfo | undefined>
  onImport: (options: ImportOptions) => void | Promise<void>
  onClose: () => void
  /** A controlled percentage. Its presence means an import is running. */
  progress?: number
  /** Optional real cancellation hook; onClose is used as a fallback. */
  onCancel?: () => void
}

function supportedFormat(
  connection: ConnectionProfile,
  target: DatabaseObjectNode
): ImportFormat | undefined {
  if (connection.engine === 'postgresql' && target.kind === 'table') return 'csv'
  if (connection.engine === 'mongodb' && target.kind === 'collection') return 'jsonl'
  return undefined
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`
}

function safeFileError(reason: unknown): string | undefined {
  if (typeof DOMException !== 'undefined' && reason instanceof DOMException && reason.name === 'AbortError') {
    return undefined
  }
  const message = reason instanceof Error ? reason.message.toLowerCase() : ''
  if (/permission|denied|not allowed/.test(message)) {
    return 'The file could not be opened. Check file permissions and try again.'
  }
  if (/too large|size|quota/.test(message)) {
    return 'The file is too large to open. Choose a smaller file and try again.'
  }
  return 'The file chooser could not be opened. Try again or check application permissions.'
}

function safeImportError(reason: unknown, format: ImportFormat): string {
  const message = reason instanceof Error ? reason.message.toLowerCase() : ''
  if (/column|header|delimiter|csv|parse/.test(message) && format === 'csv') {
    return 'The CSV could not be imported. Check the header setting, columns, delimiters, and data types.'
  }
  if (/json|document|parse/.test(message) && format === 'jsonl') {
    return 'The JSONL could not be imported. Check that every non-empty line is one valid JSON document.'
  }
  if (/permission|read.only|readonly|not authorized|unauthorized/.test(message)) {
    return 'The server rejected the import. Check write permissions and the connection guardrail.'
  }
  if (/timeout|timed out|network|connection/.test(message)) {
    return 'The import was interrupted. Check the connection; some rows or documents may already exist.'
  }
  return 'The import could not be completed. Check the file format, target constraints, and server logs.'
}

export function ImportDialog({
  connection,
  target,
  onChooseFile,
  onImport,
  onClose,
  progress,
  onCancel
}: ImportDialogProps): React.JSX.Element {
  const dialogRef = useRef<HTMLElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)
  const chooseRef = useRef<HTMLButtonElement>(null)
  const confirmationRef = useRef<HTMLHeadingElement>(null)
  const errorRef = useRef<HTMLDivElement>(null)
  const format = supportedFormat(connection, target)

  const [file, setFile] = useState<ImportFileInfo>()
  const [hasHeader, setHasHeader] = useState(true)
  const [confirming, setConfirming] = useState(false)
  const [choosing, setChoosing] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [submitted, setSubmitted] = useState(false)
  const [error, setError] = useState<string>()

  const importRunning = submitting || progress !== undefined
  const busy = choosing || importRunning
  const canImport = Boolean(format) && !connection.readOnly && !connection.demo
  const normalizedProgress = progress === undefined || !Number.isFinite(progress)
    ? undefined
    : Math.min(100, Math.max(0, progress))

  useRestoreFocus()

  useEffect(() => {
    setFile(undefined)
    setHasHeader(true)
    setConfirming(false)
    setSubmitted(false)
    setError(undefined)
  }, [connection.engine, connection.id, target.id, target.kind])

  useEffect(() => {
    if (canImport) chooseRef.current?.focus()
    else closeRef.current?.focus()
  }, [canImport, connection.id, target.id])

  useEffect(() => {
    if (confirming) confirmationRef.current?.focus()
  }, [confirming])

  useEffect(() => {
    if (error) errorRef.current?.focus()
  }, [error])

  const handleChooseFile = async (): Promise<void> => {
    if (!format || connection.readOnly || busy) return
    setChoosing(true)
    setError(undefined)
    setSubmitted(false)
    try {
      const selected = await onChooseFile(format)
      if (!selected) return
      if (!selected.name.trim() || !Number.isFinite(selected.size) || selected.size < 0) {
        setError('The selected file metadata is invalid. Choose the file again.')
        return
      }
      if (selected.size === 0) {
        setError('The selected file is empty. Choose a file containing rows or documents.')
        return
      }
      setFile({ name: selected.name, size: selected.size })
    } catch (reason) {
      setError(safeFileError(reason))
    } finally {
      setChoosing(false)
    }
  }

  const handleImport = async (): Promise<void> => {
    if (!format || !file || connection.readOnly || busy || submitted) return
    setSubmitting(true)
    setError(undefined)
    try {
      await onImport({ format, hasHeader: format === 'csv' ? hasHeader : false })
      setSubmitted(true)
      setConfirming(false)
    } catch (reason) {
      setError(safeImportError(reason, format))
    } finally {
      setSubmitting(false)
    }
  }

  const handleSubmit = (event: React.FormEvent): void => {
    event.preventDefault()
    if (!file || !canImport || busy || submitted) return
    if (!confirming) {
      setConfirming(true)
      return
    }
    void handleImport()
  }

  const handleCancelImport = (): void => {
    if (onCancel) onCancel()
    else onClose()
  }

  const handleDialogKeyDown = (event: React.KeyboardEvent<HTMLElement>): void => {
    if (event.key === 'Escape') {
      if (importRunning) return
      event.preventDefault()
      event.stopPropagation()
      if (confirming) {
        setConfirming(false)
        window.setTimeout(() => chooseRef.current?.focus(), 0)
      } else {
        onClose()
      }
      return
    }

    if (event.key !== 'Tab' || !dialogRef.current) return
    const focusable = Array.from(
      dialogRef.current.querySelectorAll<HTMLElement>(
        'button:not(:disabled), input:not(:disabled), select:not(:disabled), [href], [tabindex]:not([tabindex="-1"])'
      )
    )
    if (focusable.length === 0) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  const returnToSetup = (): void => {
    setConfirming(false)
    setError(undefined)
    window.setTimeout(() => chooseRef.current?.focus(), 0)
  }

  return (
    <div
      className="dialog-backdrop import-dialog-backdrop"
      role="presentation"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget && !busy) onClose()
      }}
    >
      <section
        ref={dialogRef}
        className="dialog import-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="import-dialog-title"
        aria-describedby="import-safety-note"
        aria-busy={busy}
        onKeyDown={handleDialogKeyDown}
      >
        <header className="dialog-header">
          <div>
            <h2 id="import-dialog-title">Import data</h2>
            <p>Review the local file and destination before writing data.</p>
          </div>
          <button
            ref={closeRef}
            className="icon-button"
            type="button"
            onClick={onClose}
            aria-label="Close import dialog"
            disabled={busy}
          >
            <X size={17} aria-hidden="true" />
          </button>
        </header>

        <form onSubmit={handleSubmit} noValidate>
          <div className="import-target-summary" aria-label="Import destination">
            <div>
              <span>Connection</span>
              <strong>{connection.name}</strong>
              {connection.environment === 'production' && <span className="badge badge-danger">Production</span>}
            </div>
            <div>
              <span>Target</span>
              <strong>{target.name}</strong>
              <span className="badge">{target.kind}</span>
            </div>
            <div>
              <span>Format</span>
              <strong>{format ? format.toUpperCase() : 'Unsupported'}</strong>
            </div>
          </div>

          {!format && (
            <div className="form-error" role="alert">
              PostgreSQL imports require a table target; MongoDB imports require a collection target.
            </div>
          )}

          {connection.readOnly && (
            <div className="form-error" role="alert">
              Import is disabled because “{connection.name}” has the read-only guardrail enabled.
            </div>
          )}

          {connection.demo && (
            <div className="form-error" role="alert">
              Import requires a real database connection; demo profiles never write files to a database.
            </div>
          )}

          {!confirming && !submitted && (
            <>
              <section className="import-file-section" aria-labelledby="import-file-heading">
                <div className="import-section-heading">
                  <div>
                    <h3 id="import-file-heading">Source file</h3>
                    <p>
                      {format === 'csv'
                        ? 'Choose one CSV file for the selected PostgreSQL table.'
                        : format === 'jsonl'
                          ? 'Choose JSONL with one JSON document per non-empty line.'
                          : 'Select a supported destination first.'}
                    </p>
                  </div>
                  <button
                    ref={chooseRef}
                    className="secondary-button"
                    type="button"
                    onClick={() => void handleChooseFile()}
                    disabled={!canImport || busy}
                  >
                    <FileUp size={14} aria-hidden="true" />
                    {choosing ? 'Choosing…' : file ? 'Change file' : `Choose ${format ? `.${format}` : 'file'}`}
                  </button>
                </div>

                {file && (
                  <div className="check-field import-selected-file" role="status">
                    <CheckCircle2 size={16} aria-hidden="true" />
                    <span>
                      <strong>{file.name}</strong>
                      <small>{formatFileSize(file.size)} · File contents are not loaded by this dialog.</small>
                    </span>
                  </div>
                )}
              </section>

              {format === 'csv' && (
                <label className="check-field" htmlFor="import-csv-header">
                  <input
                    id="import-csv-header"
                    type="checkbox"
                    checked={hasHeader}
                    onChange={(event) => setHasHeader(event.target.checked)}
                    disabled={!canImport || busy}
                  />
                  <span>
                    <strong>First row contains column names</strong>
                    <small>Turn this off when every row contains table data.</small>
                  </span>
                </label>
              )}
            </>
          )}

          {confirming && file && format && (
            <section className="import-confirmation" aria-labelledby="import-confirmation-heading">
              <ShieldAlert size={20} aria-hidden="true" />
              <div>
                <h3 id="import-confirmation-heading" ref={confirmationRef} tabIndex={-1}>
                  Confirm import
                </h3>
                <p>
                  Import <strong>{file.name}</strong> into <strong>{target.name}</strong> on{' '}
                  <strong>{connection.name}</strong>?
                </p>
                <p>
                  Format: {format.toUpperCase()}
                  {format === 'csv' ? ` · Header row: ${hasHeader ? 'Yes' : 'No'}` : ''}
                </p>
              </div>
            </section>
          )}

          <div id="import-safety-note" className="check-field" role="note">
            <ShieldAlert size={16} aria-hidden="true" />
            <span>
              <strong>Imports write to the selected target</strong>
              <small>
                {connection.engine === 'postgresql'
                  ? 'PostgreSQL runs this file in one transaction and rolls it back if a batch fails.'
                  : 'MongoDB imports are not transactional; a failed import may be partially complete.'}
              </small>
            </span>
          </div>

          {importRunning && (
            <div className="import-progress" role="status" aria-live="polite">
              <div>
                <strong>{file ? `Importing ${file.name}` : 'Importing data'}</strong>
                <span>{normalizedProgress === undefined ? 'Preparing…' : `${Math.round(normalizedProgress)}%`}</span>
              </div>
              <progress
                max={100}
                value={normalizedProgress}
                aria-label="Import progress"
                aria-valuetext={
                  normalizedProgress === undefined ? 'Preparing import' : `${Math.round(normalizedProgress)} percent`
                }
              />
            </div>
          )}

          {submitted && !importRunning && (
            <div className="check-field" role="status">
              <CheckCircle2 size={16} aria-hidden="true" />
              <span>
                <strong>Import completed</strong>
                <small>The import handler finished successfully.</small>
              </span>
            </div>
          )}

          {error && (
            <div ref={errorRef} className="form-error" role="alert" tabIndex={-1}>
              {error}
            </div>
          )}

          <footer className="dialog-footer">
            <span>{format ? `${format.toUpperCase()} → ${target.name}` : 'Choose a compatible target'}</span>
            <div>
              {importRunning ? (
                <button className="secondary-button" type="button" onClick={handleCancelImport}>
                  Cancel import
                </button>
              ) : submitted ? (
                <button className="primary-button" type="button" onClick={onClose}>
                  Close
                </button>
              ) : confirming ? (
                <>
                  <button className="secondary-button" type="button" onClick={returnToSetup}>
                    Back
                  </button>
                  <button className="primary-button" type="submit" disabled={!canImport || busy}>
                    Confirm import
                  </button>
                </>
              ) : (
                <>
                  <button className="secondary-button" type="button" onClick={onClose} disabled={busy}>
                    Cancel
                  </button>
                  <button
                    className="primary-button"
                    type="submit"
                    disabled={!file || !canImport || busy}
                  >
                    Review import
                  </button>
                </>
              )}
            </div>
          </footer>
        </form>
      </section>
    </div>
  )
}
