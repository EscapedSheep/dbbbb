import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ConnectionProfile } from '../../../shared/database'
import { ForgetConnectionDialog } from './ForgetConnectionDialog'

const connection: ConnectionProfile = {
  id: 'saved-postgres',
  name: 'Saved orders',
  engine: 'postgresql',
  endpoint: 'db.example.test:5432',
  database: 'orders',
  environment: 'development',
  readOnly: true,
  demo: false,
  saved: true
}

describe('ForgetConnectionDialog', () => {
  it('focuses Cancel first and closes from Cancel', async () => {
    const onClose = vi.fn()
    render(
      <ForgetConnectionDialog
        connection={connection}
        onConfirm={vi.fn(async () => undefined)}
        onClose={onClose}
      />
    )

    const cancel = screen.getByRole('button', { name: 'Cancel' })
    await waitFor(() => expect(cancel).toHaveFocus())
    fireEvent.click(cancel)

    expect(onClose).toHaveBeenCalledOnce()
  })

  it('closes on Escape while idle', () => {
    const onClose = vi.fn()
    render(
      <ForgetConnectionDialog
        connection={connection}
        onConfirm={vi.fn(async () => undefined)}
        onClose={onClose}
      />
    )

    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' })

    expect(onClose).toHaveBeenCalledOnce()
  })

  it('keeps keyboard focus inside the modal', () => {
    render(
      <ForgetConnectionDialog
        connection={connection}
        onConfirm={vi.fn(async () => undefined)}
        onClose={vi.fn()}
      />
    )

    const dialog = screen.getByRole('dialog')
    const close = screen.getByRole('button', { name: 'Close forget connection dialog' })
    const confirm = screen.getByRole('button', { name: 'Forget connection' })
    close.focus()
    fireEvent.keyDown(dialog, { key: 'Tab', shiftKey: true })
    expect(confirm).toHaveFocus()
    fireEvent.keyDown(dialog, { key: 'Tab' })
    expect(close).toHaveFocus()
  })

  it('confirms once and disables dismissal while the request is pending', async () => {
    let resolveConfirm!: () => void
    const onConfirm = vi.fn(() => new Promise<void>((resolve) => {
      resolveConfirm = resolve
    }))
    const onClose = vi.fn()
    render(
      <ForgetConnectionDialog
        connection={connection}
        onConfirm={onConfirm}
        onClose={onClose}
      />
    )

    fireEvent.click(screen.getByRole('button', { name: 'Forget connection' }))

    expect(onConfirm).toHaveBeenCalledOnce()
    expect(screen.getByRole('button', { name: 'Forgetting' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeDisabled()
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' })
    expect(onClose).not.toHaveBeenCalled()

    // A successful confirm unmounts the dialog from the parent, so it keeps
    // its submitting state instead of resetting on a dead component.
    await act(async () => resolveConfirm())
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Forgetting' })).toBeDisabled()
  })

  it('shows an asynchronous error and allows retrying', async () => {
    const onConfirm = vi.fn(async () => {
      throw new Error('Protected credential storage is unavailable.')
    })
    render(
      <ForgetConnectionDialog
        connection={connection}
        onConfirm={onConfirm}
        onClose={vi.fn()}
      />
    )

    fireEvent.click(screen.getByRole('button', { name: 'Forget connection' }))

    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Protected credential storage is unavailable.'
    )
    expect(screen.getByRole('button', { name: 'Forget connection' })).toBeEnabled()
  })

  it('restores focus to the element that opened the dialog', async () => {
    const trigger = document.createElement('button')
    document.body.appendChild(trigger)
    trigger.focus()
    const { unmount } = render(
      <ForgetConnectionDialog
        connection={connection}
        onConfirm={vi.fn(async () => undefined)}
        onClose={vi.fn()}
      />
    )

    await waitFor(() => expect(screen.getByRole('button', { name: 'Cancel' })).toHaveFocus())
    unmount()
    expect(trigger).toHaveFocus()
    trigger.remove()
  })

  it('does not claim that an unavailable profile has a live session to close', () => {
    render(
      <ForgetConnectionDialog
        connection={{ ...connection, connected: false }}
        onConfirm={vi.fn(async () => undefined)}
        onClose={vi.fn()}
      />
    )

    expect(screen.getByText('Remove this saved profile and its protected credentials.')).toBeInTheDocument()
    expect(screen.getByText('dbbbb will no longer retry this profile at startup.')).toBeInTheDocument()
    expect(screen.queryByText(/close its session/i)).not.toBeInTheDocument()
  })
})
