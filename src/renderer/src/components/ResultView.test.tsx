import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import type { DocumentResult, ResultColumn, RowResult, WireValue } from '../../../shared/database'
import { ResultView, rowToRecord } from './ResultView'

const meta = {
  elapsedMs: 4,
  count: 1,
  truncated: false,
  source: 'database' as const
}

function rows(columns: ResultColumn[], values: WireValue[][]): RowResult {
  return { kind: 'rows', columns, rows: values, meta: { ...meta, count: values.length } }
}

describe('rowToRecord', () => {
  it('maps labels to row values on a null-prototype record', () => {
    const record = rowToRecord(
      [
        { key: 'user-id', label: 'id', dataType: 'int4' },
        { key: 'user-name', label: 'name', dataType: 'text' }
      ],
      [7, 'Maya']
    )

    expect(record).toEqual({ id: 7, name: 'Maya' })
    expect(Object.getPrototypeOf(record!)).toBeNull()
  })

  it('rejects duplicate labels and mismatched row widths', () => {
    expect(rowToRecord(
      [
        { key: 'left-id', label: 'id', dataType: 'int4' },
        { key: 'right-id', label: 'id', dataType: 'int4' }
      ],
      [1, 2]
    )).toBeUndefined()
    expect(rowToRecord(
      [{ key: 'id', label: 'id', dataType: 'int4' }],
      [1, 2]
    )).toBeUndefined()
  })
})

describe('ResultView edit entry points', () => {
  it('passes a relational row record to the edit callback', () => {
    const onEditRecord = vi.fn()
    render(
      <ResultView
        result={rows(
          [
            { key: 'id', label: 'id', dataType: 'int4' },
            { key: 'name', label: 'name', dataType: 'text' }
          ],
          [[7, 'Maya']]
        )}
        loading={false}
        editingEnabled
        onEditRecord={onEditRecord}
      />
    )

    fireEvent.click(screen.getByRole('button', { name: 'Edit row 1' }))

    expect(onEditRecord).toHaveBeenCalledOnce()
    expect(onEditRecord).toHaveBeenCalledWith({ id: 7, name: 'Maya' })
    expect(Object.getPrototypeOf(onEditRecord.mock.calls[0][0])).toBeNull()
  })

  it('renders a disabled row edit action when column labels are duplicated', () => {
    const onEditRecord = vi.fn()
    render(
      <ResultView
        result={rows(
          [
            { key: 'left-id', label: 'id', dataType: 'int4' },
            { key: 'right-id', label: 'id', dataType: 'int4' }
          ],
          [[1, 2]]
        )}
        loading={false}
        editingEnabled
        onEditRecord={onEditRecord}
      />
    )

    const edit = screen.getByRole('button', { name: 'Edit row 1' })
    expect(edit).toBeDisabled()
    fireEvent.click(edit)
    expect(onEditRecord).not.toHaveBeenCalled()
  })

  it('passes a MongoDB document to the edit callback', () => {
    const onEditRecord = vi.fn()
    const document = {
      _id: { $oid: 'abc123' },
      name: 'Maya',
      active: true
    }
    const result: DocumentResult = {
      kind: 'documents',
      documents: [document],
      meta
    }
    render(
      <ResultView
        result={result}
        loading={false}
        editingEnabled
        onEditRecord={onEditRecord}
      />
    )

    fireEvent.click(screen.getByRole('button', { name: 'Edit document 1' }))

    expect(onEditRecord).toHaveBeenCalledOnce()
    expect(onEditRecord).toHaveBeenCalledWith(document)
  })

  it('hides edit actions when editing is not enabled', () => {
    render(
      <ResultView
        result={rows([{ key: 'id', label: 'id', dataType: 'int4' }], [[1]])}
        loading={false}
      />
    )

    expect(screen.queryByRole('button', { name: /Edit row/ })).not.toBeInTheDocument()
  })
})
