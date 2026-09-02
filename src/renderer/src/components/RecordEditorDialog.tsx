import { AlertTriangle, ArrowLeft, Check, Trash2, X } from 'lucide-react'
import { useEffect, useMemo, useRef, useState } from 'react'
import type {
  ConnectionProfile,
  DataRecord,
  DatabaseObjectNode,
  WireValue
} from '../../../shared/database'
import { useRestoreFocus } from './useRestoreFocus'

interface RecordEditorDialogProps {
  connection: ConnectionProfile
  target: DatabaseObjectNode
  original: DataRecord
  onApply: (current: DataRecord) => Promise<void>
  onDelete: () => Promise<void>
  onClose: () => void
}

interface FieldChange {
  field: string
  kind: 'added' | 'changed' | 'removed'
  before?: WireValue
  after?: WireValue
}

type View = 'edit' | 'review' | 'delete'

const dangerousKeys = new Set(['__proto__', 'constructor', 'prototype'])

function valueFingerprint(value: WireValue | undefined): string {
  return value === undefined ? '__missing__' : JSON.stringify(value)
}

function validateJsonValue(value: unknown, depth = 0): WireValue {
  if (depth > 32) throw new Error('The record is nested too deeply.')
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value
  if (
    typeof value === 'number' &&
    Number.isFinite(value) &&
    (!Number.isInteger(value) || Number.isSafeInteger(value))
  ) return value
  if (typeof value === 'number') {
    throw new Error('Represent integers outside JavaScript’s safe range as strings or BSON tags.')
  }
  if (Array.isArray(value)) return value.map((item) => validateJsonValue(item, depth + 1))
  if (!value || typeof value !== 'object') throw new Error('The record contains an unsupported value.')

  const output = Object.create(null) as Record<string, WireValue>
  for (const key of Object.keys(value)) {
    if (dangerousKeys.has(key) || key.includes('\0')) {
      throw new Error(`The field ${JSON.stringify(key)} cannot be edited safely.`)
    }
    Object.defineProperty(output, key, {
      configurable: true,
      enumerable: true,
      writable: true,
      value: validateJsonValue((value as Record<string, unknown>)[key], depth + 1)
    })
  }
  return output
}

export function parseRecordDraft(text: string): DataRecord {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    throw new Error('Enter one valid JSON object before reviewing the change.')
  }
  const safe = validateJsonValue(parsed)
  if (!safe || typeof safe !== 'object' || Array.isArray(safe)) {
    throw new Error('The edited record must be one JSON object.')
  }
  if (Object.keys(safe).length === 0) throw new Error('The edited record cannot be empty.')
  return safe
}

export function recordChanges(original: DataRecord, current: DataRecord): FieldChange[] {
  const fields = new Set([...Object.keys(original), ...Object.keys(current)])
  const changes: FieldChange[] = []
  for (const field of fields) {
    const beforePresent = Object.hasOwn(original, field)
    const afterPresent = Object.hasOwn(current, field)
    const before = original[field]
    const after = current[field]
    if (beforePresent && !afterPresent) changes.push({ field, kind: 'removed', before })
    else if (!beforePresent && afterPresent) changes.push({ field, kind: 'added', after })
    else if (valueFingerprint(before) !== valueFingerprint(after)) {
      changes.push({ field, kind: 'changed', before, after })
    }
  }
  return changes
}

function previewValue(value: WireValue | undefined): string {
  if (value === undefined) return '—'
  const text = JSON.stringify(value)
  return text.length > 180 ? `${text.slice(0, 177)}…` : text
}

export function RecordEditorDialog({
  connection,
  target,
  original,
  onApply,
  onDelete,
  onClose
}: RecordEditorDialogProps): React.JSX.Element {
  const [view, setView] = useState<View>('edit')
  const [draft, setDraft] = useState(() => JSON.stringify(original, null, 2))
  const [current, setCurrent] = useState<DataRecord>()
  const [confirmation, setConfirmation] = useState('')
  const [error, setError] = useState<string>()
  const [submitting, setSubmitting] = useState(false)
  const dialogRef = useRef<HTMLElement>(null)
  const editorRef = useRef<HTMLTextAreaElement>(null)
  const changes = useMemo(
    () => current ? recordChanges(original, current) : [],
    [current, original]
  )
  const needsProductionConfirmation = connection.environment === 'production'

  useRestoreFocus()

  useEffect(() => {
    editorRef.current?.focus()
  }, [])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape' && !submitting) onClose()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [onClose, submitting])

  const review = (): void => {
    setError(undefined)
    try {
      const next = parseRecordDraft(draft)
      if (connection.engine === 'postgresql') {
        const originalFields = Object.keys(original)
        const currentFields = Object.keys(next)
        if (
          originalFields.length !== currentFields.length ||
          originalFields.some((field) => !Object.hasOwn(next, field))
        ) {
          throw new Error('PostgreSQL row editing cannot add or remove columns.')
        }
      }
      const nextChanges = recordChanges(original, next)
      if (nextChanges.length === 0) throw new Error('Change at least one value before reviewing.')
      if (connection.engine === 'mongodb') {
        if (!Object.hasOwn(next, '_id')) {
          throw new Error('MongoDB documents must keep their _id field.')
        }
        if (valueFingerprint(original._id) !== valueFingerprint(next._id)) {
          throw new Error('MongoDB _id cannot be edited.')
        }
      }
      setCurrent(next)
      setConfirmation('')
      setView('review')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'The record could not be reviewed.')
    }
  }

  const apply = async (): Promise<void> => {
    if (!current || submitting) return
    setSubmitting(true)
    setError(undefined)
    try {
      // On success the parent unmounts this dialog.
      await onApply(current)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'The change could not be applied.')
      setSubmitting(false)
    }
  }

  const remove = async (): Promise<void> => {
    if (confirmation !== 'DELETE' || submitting) return
    setSubmitting(true)
    setError(undefined)
    try {
      // On success the parent unmounts this dialog.
      await onDelete()
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'The record could not be deleted.')
      setSubmitting(false)
    }
  }

  const handleDialogKeyDown = (event: React.KeyboardEvent<HTMLElement>): void => {
    if (event.key !== 'Tab' || !dialogRef.current) return
    const focusable = Array.from(
      dialogRef.current.querySelectorAll<HTMLElement>(
        'button:not(:disabled), textarea:not(:disabled), input:not(:disabled), select:not(:disabled), [href], [tabindex]:not([tabindex="-1"])'
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

  const title = view === 'delete' ? 'Delete record' : view === 'review' ? 'Review changes' : 'Edit record'

  return (
    <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget && !submitting) onClose()
    }}>
      <section
        ref={dialogRef}
        className="dialog record-editor-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="record-editor-title"
        aria-busy={submitting}
        onKeyDown={handleDialogKeyDown}
      >
        <header className="dialog-header">
          <div>
            <span className="eyebrow">{connection.engine === 'postgresql' ? 'PostgreSQL row' : 'MongoDB document'}</span>
            <h2 id="record-editor-title">{title}</h2>
            <p>{connection.name} / {target.name}</p>
          </div>
          <button className="icon-button" type="button" onClick={onClose} disabled={submitting} aria-label="Close record editor">
            <X size={16} />
          </button>
        </header>

        {connection.environment === 'production' && (
          <div className="record-production-warning">
            <AlertTriangle size={15} />
            Production connection — review every field before applying.
          </div>
        )}

        <div className="record-editor-body">
          {view === 'edit' && (
            <>
              <label className="record-json-field">
                <span>Record JSON</span>
                <textarea
                  ref={editorRef}
                  value={draft}
                  onChange={(event) => {
                    setDraft(event.target.value)
                    setError(undefined)
                  }}
                  spellCheck={false}
                  aria-describedby="record-editor-help"
                />
              </label>
              <p className="field-help" id="record-editor-help">
                {connection.engine === 'mongodb' ? (
                  <>BSON tags such as <code>$oid</code> and <code>$date</code> must stay intact; <code>_id</code> cannot change.</>
                ) : (
                  <>Values use JSON and are converted through their PostgreSQL column types; primary-key fields cannot change.</>
                )}
              </p>
            </>
          )}

          {view === 'review' && (
            <>
              <div className="change-summary" aria-label="Change summary">
                {changes.map((change) => (
                  <div className="change-row" key={change.field}>
                    <div>
                      <strong>{change.field}</strong>
                      <span className={`change-kind ${change.kind}`}>{change.kind}</span>
                    </div>
                    <code>{previewValue(change.before)}</code>
                    <span aria-hidden="true">→</span>
                    <code>{previewValue(change.after)}</code>
                  </div>
                ))}
              </div>
              {needsProductionConfirmation && (
                <label className="confirmation-field">
                  <span>Type <strong>APPLY</strong> to change production data</span>
                  <input
                    value={confirmation}
                    onChange={(event) => setConfirmation(event.target.value)}
                    autoComplete="off"
                  />
                </label>
              )}
            </>
          )}

          {view === 'delete' && (
            <div className="delete-confirmation">
              <Trash2 size={28} strokeWidth={1.4} />
              <strong>This permanently deletes one {connection.engine === 'postgresql' ? 'row' : 'document'}.</strong>
              <p>An optimistic check will stop the deletion if the database record changed after it was loaded.</p>
              <label className="confirmation-field">
                <span>Type <strong>DELETE</strong> to confirm</span>
                <input
                  value={confirmation}
                  onChange={(event) => setConfirmation(event.target.value)}
                  autoFocus
                  autoComplete="off"
                />
              </label>
            </div>
          )}

          {error && <div className="dialog-error" role="alert">{error}</div>}
        </div>

        <footer className="dialog-footer record-editor-footer">
          {view === 'edit' ? (
            <>
              <button className="danger-text-button" type="button" onClick={() => {
                setConfirmation('')
                setError(undefined)
                setView('delete')
              }}>
                <Trash2 size={14} /> Delete
              </button>
              <span className="dialog-footer-spacer" />
              <button className="secondary-button" type="button" onClick={onClose}>Cancel</button>
              <button className="primary-button" type="button" onClick={review}>
                Review
              </button>
            </>
          ) : view === 'review' ? (
            <>
              <button className="secondary-button" type="button" onClick={() => {
                setConfirmation('')
                setError(undefined)
                setView('edit')
              }} disabled={submitting}>
                <ArrowLeft size={14} /> Back
              </button>
              <span className="dialog-footer-spacer" />
              <button
                className="primary-button"
                type="button"
                onClick={() => void apply()}
                disabled={submitting || (needsProductionConfirmation && confirmation !== 'APPLY')}
              >
                {submitting ? <span className="button-spinner" /> : <Check size={14} />}
                {submitting ? 'Applying' : 'Apply changes'}
              </button>
            </>
          ) : (
            <>
              <button className="secondary-button" type="button" onClick={() => {
                setConfirmation('')
                setError(undefined)
                setView('edit')
              }} disabled={submitting}>
                <ArrowLeft size={14} /> Back
              </button>
              <span className="dialog-footer-spacer" />
              <button
                className="danger-button"
                type="button"
                onClick={() => void remove()}
                disabled={submitting || confirmation !== 'DELETE'}
              >
                {submitting ? <span className="button-spinner" /> : <Trash2 size={14} />}
                {submitting ? 'Deleting' : 'Delete record'}
              </button>
            </>
          )}
        </footer>
      </section>
    </div>
  )
}
