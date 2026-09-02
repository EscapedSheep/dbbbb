import { Trash2, X } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import type { ConnectionProfile } from '../../../shared/database'
import { useRestoreFocus } from './useRestoreFocus'

interface ForgetConnectionDialogProps {
  connection: ConnectionProfile
  onConfirm: () => Promise<void>
  onClose: () => void
}

export function ForgetConnectionDialog({
  connection,
  onConfirm,
  onClose
}: ForgetConnectionDialogProps): React.JSX.Element {
  const unavailable = connection.connected === false
  const dialogRef = useRef<HTMLElement>(null)
  const cancelRef = useRef<HTMLButtonElement>(null)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string>()

  useRestoreFocus()

  useEffect(() => cancelRef.current?.focus(), [])

  const handleDialogKeyDown = (event: React.KeyboardEvent<HTMLElement>): void => {
    if (event.key === 'Escape') {
      if (submitting) return
      event.preventDefault()
      event.stopPropagation()
      onClose()
      return
    }
    if (event.key !== 'Tab' || !dialogRef.current) return
    const focusable = Array.from(
      dialogRef.current.querySelectorAll<HTMLElement>(
        'button:not(:disabled), [href], [tabindex]:not([tabindex="-1"])'
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

  const confirm = async (): Promise<void> => {
    if (submitting) return
    setSubmitting(true)
    setError(undefined)
    try {
      // On success the parent unmounts this dialog.
      await onConfirm()
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'The saved connection could not be forgotten.')
      setSubmitting(false)
    }
  }

  return (
    <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget && !submitting) onClose()
    }}>
      <section
        ref={dialogRef}
        className="dialog forget-connection-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="forget-connection-title"
        aria-busy={submitting}
        onKeyDown={handleDialogKeyDown}
      >
        <header className="dialog-header">
          <div>
            <h2 id="forget-connection-title">Forget saved connection?</h2>
            <p>{connection.name} / {connection.database}</p>
          </div>
          <button className="icon-button" type="button" onClick={onClose} disabled={submitting} aria-label="Close forget connection dialog">
            <X size={16} />
          </button>
        </header>
        <div className="forget-connection-body">
          <Trash2 size={25} strokeWidth={1.4} />
          <div>
            <strong>
              {unavailable
                ? 'Remove this saved profile and its protected credentials.'
                : 'Remove this encrypted profile and close its session.'}
            </strong>
            <p>This does not alter the database or any data stored in it.</p>
          </div>
        </div>
        {error && <div className="dialog-error forget-connection-error" role="alert">{error}</div>}
        <footer className="dialog-footer forget-connection-footer">
          <span>
            {unavailable
              ? 'dbbbb will no longer retry this profile at startup.'
              : 'Saved credentials will no longer be restored at startup.'}
          </span>
          <div>
            <button ref={cancelRef} className="secondary-button" type="button" onClick={onClose} disabled={submitting}>Cancel</button>
            <button className="danger-button" type="button" onClick={() => void confirm()} disabled={submitting}>
              {submitting ? <span className="button-spinner" /> : <Trash2 size={14} />}
              {submitting ? 'Forgetting' : 'Forget connection'}
            </button>
          </div>
        </footer>
      </section>
    </div>
  )
}
