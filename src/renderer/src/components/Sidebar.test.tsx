import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { Sidebar } from './Sidebar'

describe('Sidebar', () => {
  it('focuses the navigator search with the cross-platform shortcut', () => {
    render(
      <Sidebar
        connections={[]}
        objects={[]}
        objectsLoading={false}
        onSelectConnection={vi.fn()}
        onSelectObject={vi.fn()}
        onNewConnection={vi.fn()}
        onRefreshObjects={vi.fn()}
      />
    )

    const search = screen.getByRole('textbox', { name: 'Search connections' })
    fireEvent.keyDown(window, { key: 'p', ctrlKey: true })
    expect(search).toHaveFocus()
  })

  it('ignores the search shortcut while a modal dialog is open', () => {
    render(
      <>
        <Sidebar
          connections={[]}
          objects={[]}
          objectsLoading={false}
          onSelectConnection={vi.fn()}
          onSelectObject={vi.fn()}
          onNewConnection={vi.fn()}
          onRefreshObjects={vi.fn()}
        />
        <div role="dialog" aria-label="Any modal" />
      </>
    )

    const search = screen.getByRole('textbox', { name: 'Search connections' })
    fireEvent.keyDown(window, { key: 'p', metaKey: true })
    expect(search).not.toHaveFocus()
  })

  it('disables connection switching while a query is running', () => {
    render(
      <Sidebar
        connections={[{
          id: 'local-postgres',
          name: 'Local product',
          engine: 'postgresql',
          endpoint: 'localhost:5432',
          database: 'dbbbb_dev',
          environment: 'development',
          readOnly: false,
          demo: true
        }]}
        selectedConnectionId="local-postgres"
        objects={[]}
        objectsLoading={false}
        connectionsDisabled
        onSelectConnection={vi.fn()}
        onSelectObject={vi.fn()}
        onNewConnection={vi.fn()}
        onRefreshObjects={vi.fn()}
      />
    )

    expect(screen.getByRole('button', { name: /Local product/ })).toBeDisabled()
  })

  it('labels an unavailable saved profile without relying on color and disables refresh', () => {
    render(
      <Sidebar
        connections={[{
          id: 'saved-unavailable',
          name: 'Saved archive',
          engine: 'postgresql',
          endpoint: 'archive.example:5432',
          database: 'archive',
          environment: 'development',
          readOnly: true,
          demo: false,
          saved: true,
          connected: false
        }]}
        selectedConnectionId="saved-unavailable"
        objects={[]}
        objectsLoading={false}
        onSelectConnection={vi.fn()}
        onSelectObject={vi.fn()}
        onNewConnection={vi.fn()}
        onRefreshObjects={vi.fn()}
      />
    )

    expect(screen.getByText('· Unavailable')).toBeInTheDocument()
    expect(screen.getByLabelText('Unavailable')).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Connection unavailable')
    expect(screen.getByRole('button', { name: 'Refresh objects' })).toBeDisabled()
  })
})
