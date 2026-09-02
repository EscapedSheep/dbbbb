import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { ConnectionProfile, DataRecord, DatabaseObjectNode } from '../../../shared/database'
import { parseRecordDraft, recordChanges, RecordEditorDialog } from './RecordEditorDialog'

const postgres: ConnectionProfile = {
  id: 'postgres-1',
  name: 'Product database',
  engine: 'postgresql',
  endpoint: 'localhost:5432',
  database: 'product',
  environment: 'development',
  readOnly: false,
  demo: false
}

const mongo: ConnectionProfile = {
  ...postgres,
  id: 'mongo-1',
  name: 'Product documents',
  engine: 'mongodb',
  endpoint: 'localhost:27017'
}

const table: DatabaseObjectNode = { id: 'table-users', name: 'users', kind: 'table' }
const collection: DatabaseObjectNode = {
  id: 'collection-users',
  name: 'users',
  kind: 'collection'
}

interface RenderEditorOptions {
  connection?: ConnectionProfile
  target?: DatabaseObjectNode
  original?: DataRecord
  onApply?: (current: DataRecord) => Promise<void>
  onDelete?: () => Promise<void>
  onClose?: () => void
}

function renderEditor(options: RenderEditorOptions = {}): ReturnType<typeof render> {
  return render(
    <RecordEditorDialog
      connection={options.connection ?? postgres}
      target={options.target ?? table}
      original={options.original ?? { id: 1, name: 'Before' }}
      onApply={options.onApply ?? vi.fn(async () => undefined)}
      onDelete={options.onDelete ?? vi.fn(async () => undefined)}
      onClose={options.onClose ?? vi.fn()}
    />
  )
}

function replaceDraft(value: unknown): void {
  fireEvent.change(screen.getByLabelText('Record JSON'), {
    target: { value: JSON.stringify(value, null, 2) }
  })
}

function openReview(value: unknown): void {
  replaceDraft(value)
  fireEvent.click(screen.getByRole('button', { name: 'Review' }))
}

describe('RecordEditorDialog JSON helpers', () => {
  it('parses one JSON object into recursively null-prototype data', () => {
    const parsed = parseRecordDraft(
      '{"id":1,"enabled":false,"nested":{"tags":["a",null]}}'
    )

    expect(parsed).toEqual({ id: 1, enabled: false, nested: { tags: ['a', null] } })
    expect(Object.getPrototypeOf(parsed)).toBeNull()
    expect(Object.getPrototypeOf(parsed.nested as object)).toBeNull()
    expect(() => parseRecordDraft('{not json')).toThrow(/valid JSON object/i)
    expect(() => parseRecordDraft('[1, 2]')).toThrow(/must be one JSON object/i)
    expect(() => parseRecordDraft('{}')).toThrow(/cannot be empty/i)
  })

  it('reports top-level added, changed, and removed fields', () => {
    expect(recordChanges(
      { unchanged: true, changed: 'before', removed: 0 },
      { unchanged: true, changed: 'after', added: null }
    )).toEqual([
      { field: 'changed', kind: 'changed', before: 'before', after: 'after' },
      { field: 'removed', kind: 'removed', before: 0 },
      { field: 'added', kind: 'added', after: null }
    ])
  })
})

describe('RecordEditorDialog validation', () => {
  it('prevents PostgreSQL rows from adding or removing columns', () => {
    renderEditor()

    openReview({ id: 1, name: 'After', extra: true })
    expect(screen.getByRole('alert')).toHaveTextContent(/cannot add or remove columns/i)
    expect(screen.getByRole('heading', { name: 'Edit record' })).toBeInTheDocument()

    openReview({ id: 1 })
    expect(screen.getByRole('alert')).toHaveTextContent(/cannot add or remove columns/i)
    expect(screen.getByRole('heading', { name: 'Edit record' })).toBeInTheDocument()
  })

  it('requires MongoDB documents to keep an unchanged _id', () => {
    const original = { _id: { $oid: 'abc123' }, name: 'Before' }
    renderEditor({ connection: mongo, target: collection, original })

    openReview({ name: 'After' })
    expect(screen.getByRole('alert')).toHaveTextContent(/must keep their _id/i)
    expect(screen.getByRole('heading', { name: 'Edit record' })).toBeInTheDocument()

    openReview({ _id: { $oid: 'different' }, name: 'After' })
    expect(screen.getByRole('alert')).toHaveTextContent(/_id.*cannot|unchanged.*_id/i)
    expect(screen.getByRole('heading', { name: 'Edit record' })).toBeInTheDocument()
  })

  it('does not review a record with no effective changes', () => {
    renderEditor()

    fireEvent.click(screen.getByRole('button', { name: 'Review' }))

    expect(screen.getByRole('alert')).toHaveTextContent(/change at least one value/i)
    expect(screen.getByRole('heading', { name: 'Edit record' })).toBeInTheDocument()
  })
})

describe('RecordEditorDialog apply and delete flows', () => {
  it('shows a field diff before applying the parsed record', async () => {
    const onApply = vi.fn(async (_current: DataRecord) => undefined)
    renderEditor({ onApply })

    openReview({ id: 1, name: 'After' })

    expect(screen.getByRole('heading', { name: 'Review changes' })).toBeInTheDocument()
    const summary = screen.getByLabelText('Change summary')
    expect(within(summary).getByText('name')).toBeInTheDocument()
    expect(within(summary).getByText('changed')).toBeInTheDocument()
    expect(within(summary).getByText('"Before"')).toBeInTheDocument()
    expect(within(summary).getByText('"After"')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Apply changes' }))

    await waitFor(() => expect(onApply).toHaveBeenCalledOnce())
    expect(onApply).toHaveBeenCalledWith({ id: 1, name: 'After' })
    const applied = onApply.mock.calls[0][0]
    expect(Object.getPrototypeOf(applied)).toBeNull()
  })

  it('requires exact APPLY confirmation for production updates', async () => {
    const onApply = vi.fn(async () => undefined)
    renderEditor({
      connection: { ...postgres, environment: 'production' },
      onApply
    })
    openReview({ id: 1, name: 'After' })

    expect(screen.getByText(/Production connection/)).toBeInTheDocument()
    const applyButton = screen.getByRole('button', { name: 'Apply changes' })
    const confirmation = screen.getByLabelText(/Type APPLY to change production data/)
    expect(applyButton).toBeDisabled()

    fireEvent.change(confirmation, { target: { value: 'apply' } })
    expect(applyButton).toBeDisabled()
    fireEvent.change(confirmation, { target: { value: 'APPLY' } })
    expect(applyButton).toBeEnabled()
    fireEvent.click(applyButton)

    await waitFor(() => expect(onApply).toHaveBeenCalledOnce())
  })

  it('requires exact DELETE confirmation before deleting', async () => {
    const onDelete = vi.fn(async () => undefined)
    renderEditor({ onDelete })

    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    expect(screen.getByRole('heading', { name: 'Delete record' })).toBeInTheDocument()
    expect(screen.getByText(/permanently deletes one row/i)).toBeInTheDocument()
    const deleteButton = screen.getByRole('button', { name: 'Delete record' })
    const confirmation = screen.getByLabelText(/Type DELETE to confirm/)
    expect(deleteButton).toBeDisabled()

    fireEvent.change(confirmation, { target: { value: 'delete' } })
    expect(deleteButton).toBeDisabled()
    fireEvent.change(confirmation, { target: { value: 'DELETE' } })
    expect(deleteButton).toBeEnabled()
    fireEvent.click(deleteButton)

    await waitFor(() => expect(onDelete).toHaveBeenCalledOnce())
  })

  it('shows an async apply error and permits a retry', async () => {
    const onApply = vi.fn(async () => {
      throw new Error('The record changed after it was loaded.')
    })
    renderEditor({ onApply })
    openReview({ id: 1, name: 'After' })

    fireEvent.click(screen.getByRole('button', { name: 'Apply changes' }))

    expect(await screen.findByRole('alert')).toHaveTextContent(/record changed after it was loaded/i)
    expect(screen.getByRole('button', { name: 'Apply changes' })).toBeEnabled()
  })
})
