import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ConnectionProfile, DatabaseObjectNode } from '../../../shared/database'
import { ImportDialog, type ImportDialogProps } from './ImportDialog'

const postgresConnection: ConnectionProfile = {
  id: 'postgres-1',
  name: 'Orders database',
  engine: 'postgresql',
  endpoint: 'localhost:5432',
  database: 'orders',
  environment: 'development',
  readOnly: false,
  demo: false
}

const mongoConnection: ConnectionProfile = {
  id: 'mongo-1',
  name: 'Customer documents',
  engine: 'mongodb',
  endpoint: 'localhost:27017',
  database: 'app',
  environment: 'production',
  readOnly: false,
  demo: false
}

const table: DatabaseObjectNode = {
  id: 'table-orders',
  name: 'orders',
  kind: 'table'
}

const collection: DatabaseObjectNode = {
  id: 'collection-customers',
  name: 'customers',
  kind: 'collection'
}

function callbacks(
  overrides: Partial<Pick<ImportDialogProps, 'onChooseFile' | 'onImport' | 'onCancel'>> = {}
): Pick<ImportDialogProps, 'onChooseFile' | 'onImport' | 'onClose' | 'onCancel'> {
  return {
    onChooseFile: vi.fn(async () => ({ name: 'orders.csv', size: 1536 })),
    onImport: vi.fn(async () => undefined),
    onClose: vi.fn(),
    onCancel: vi.fn(),
    ...overrides
  }
}

describe('ImportDialog', () => {
  it('reviews and confirms a PostgreSQL table CSV import with header settings', async () => {
    const handlers = callbacks()
    render(
      <ImportDialog
        connection={postgresConnection}
        target={table}
        {...handlers}
      />
    )

    expect(screen.getByText('Orders database')).toBeInTheDocument()
    expect(screen.getByText('orders')).toBeInTheDocument()
    expect(screen.getByText('CSV')).toBeInTheDocument()
    expect(screen.getByLabelText(/First row contains column names/)).toBeChecked()

    fireEvent.click(screen.getByRole('button', { name: 'Choose .csv' }))
    expect(await screen.findByText('orders.csv')).toBeInTheDocument()
    expect(screen.getByText(/1\.5 KB/)).toBeInTheDocument()
    expect(handlers.onChooseFile).toHaveBeenCalledWith('csv')

    fireEvent.click(screen.getByRole('button', { name: 'Review import' }))
    const confirmation = screen.getByRole('heading', { name: 'Confirm import' })
    await waitFor(() => expect(confirmation).toHaveFocus())
    expect(handlers.onImport).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Confirm import' }))
    await waitFor(() => expect(handlers.onImport).toHaveBeenCalledWith({ format: 'csv', hasHeader: true }))
    expect(await screen.findByText('Import completed')).toBeInTheDocument()
  })

  it('allows only JSONL for MongoDB collections and never sends a CSV header option', async () => {
    const handlers = callbacks({
      onChooseFile: vi.fn(async () => ({ name: 'customers.jsonl', size: 2048 }))
    })
    render(
      <ImportDialog
        connection={mongoConnection}
        target={collection}
        {...handlers}
      />
    )

    expect(screen.getByText('Production')).toBeInTheDocument()
    expect(screen.getByText('JSONL')).toBeInTheDocument()
    expect(screen.queryByLabelText(/First row contains column names/)).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Choose .jsonl' }))
    expect(await screen.findByText('customers.jsonl')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Review import' }))
    fireEvent.click(screen.getByRole('button', { name: 'Confirm import' }))

    await waitFor(() => expect(handlers.onImport).toHaveBeenCalledWith({ format: 'jsonl', hasHeader: false }))
    expect(handlers.onChooseFile).toHaveBeenCalledWith('jsonl')
  })

  it('disables imports for read-only connections and incompatible targets', () => {
    const handlers = callbacks()
    const readOnly = { ...postgresConnection, readOnly: true }
    const { rerender } = render(
      <ImportDialog connection={readOnly} target={table} {...handlers} />
    )

    expect(screen.getByRole('alert')).toHaveTextContent(/read-only guardrail enabled/i)
    expect(screen.getByRole('button', { name: 'Choose .csv' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Review import' })).toBeDisabled()

    const view: DatabaseObjectNode = { id: 'view-orders', name: 'order_summary', kind: 'view' }
    rerender(<ImportDialog connection={postgresConnection} target={view} {...handlers} />)
    expect(screen.getByRole('alert')).toHaveTextContent(/PostgreSQL imports require a table target/i)
    expect(screen.getByRole('button', { name: 'Choose file' })).toBeDisabled()
    expect(handlers.onChooseFile).not.toHaveBeenCalled()
  })

  it('shows actionable, redacted file and import errors', async () => {
    const path = '/Users/example/private/orders.csv'
    const chooseHandlers = callbacks({
      onChooseFile: vi.fn(async () => { throw new Error(`permission denied: ${path}`) })
    })
    const { unmount } = render(
      <ImportDialog connection={postgresConnection} target={table} {...chooseHandlers} />
    )

    fireEvent.click(screen.getByRole('button', { name: 'Choose .csv' }))
    let alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent(/check file permissions/i)
    expect(alert).not.toHaveTextContent(path)
    expect(alert).toHaveFocus()
    unmount()

    const importHandlers = callbacks({
      onImport: vi.fn(async () => {
        throw new Error(`CSV parse failed at ${path}: secret-value`)
      })
    })
    render(<ImportDialog connection={postgresConnection} target={table} {...importHandlers} />)
    fireEvent.click(screen.getByRole('button', { name: 'Choose .csv' }))
    await screen.findByText('orders.csv')
    fireEvent.click(screen.getByRole('button', { name: 'Review import' }))
    fireEvent.click(screen.getByRole('button', { name: 'Confirm import' }))

    alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent(/check the header setting, columns, delimiters, and data types/i)
    expect(alert).not.toHaveTextContent(/secret-value|\/Users\/example/)
  })

  it('announces controlled progress, exposes cancellation, and blocks Escape closing', () => {
    const handlers = callbacks()
    render(
      <ImportDialog
        connection={postgresConnection}
        target={table}
        progress={42.4}
        {...handlers}
      />
    )

    const progress = screen.getByRole('progressbar', { name: 'Import progress' })
    expect(progress).toHaveAttribute('value', '42.4')
    expect(progress).toHaveAccessibleName('Import progress')
    expect(screen.getByText('42%')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Close import dialog' })).toBeDisabled()

    fireEvent.keyDown(progress, { key: 'Escape' })
    expect(handlers.onClose).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Cancel import' }))
    expect(handlers.onCancel).toHaveBeenCalledOnce()
  })
})
