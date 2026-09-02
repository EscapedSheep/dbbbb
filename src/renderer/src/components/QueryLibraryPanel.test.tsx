import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { QueryEntry } from '../lib/query-library'
import { QueryLibraryPanel, type QueryLibraryPanelProps } from './QueryLibraryPanel'

const historyEntry: QueryEntry = {
  id: 'history-1',
  connectionId: 'postgres-local',
  title: 'Recent users',
  engine: 'postgresql',
  command: { engine: 'postgresql', kind: 'query', text: 'SELECT * FROM users LIMIT 20;' },
  createdAt: '2026-08-31T10:00:00.000Z',
  favorite: false
}

const favoriteEntry: QueryEntry = {
  id: 'favorite-1',
  connectionId: 'mongo-local',
  title: 'Active customers',
  engine: 'mongodb',
  command: {
    engine: 'mongodb',
    kind: 'find',
    collection: 'customers',
    text: '{ "active": true }'
  },
  createdAt: '2026-08-30T09:30:00.000Z',
  favorite: true
}

describe('QueryLibraryPanel', () => {
  let callbacks: Omit<QueryLibraryPanelProps, 'entries'>

  beforeEach(() => {
    callbacks = {
      onSelect: vi.fn(),
      onToggleFavorite: vi.fn(),
      onRemove: vi.fn(),
      onClearHistory: vi.fn(),
      onClose: vi.fn()
    }
  })

  it('shows history metadata and exposes select, favorite, remove, and clear actions', () => {
    const { container } = render(
      <QueryLibraryPanel entries={[historyEntry, favoriteEntry]} {...callbacks} />
    )

    expect(screen.getByText('Recent users')).toBeInTheDocument()
    expect(screen.queryByText('Active customers')).not.toBeInTheDocument()
    expect(screen.getByText('PostgreSQL')).toBeInTheDocument()
    expect(screen.getByText('SELECT * FROM users LIMIT 20;')).toBeInTheDocument()
    expect(container.querySelector('time')).toHaveAttribute('dateTime', historyEntry.createdAt)

    fireEvent.click(screen.getByRole('button', { name: 'Open query Recent users' }))
    fireEvent.click(screen.getByRole('button', { name: 'Add Recent users to favorites' }))
    fireEvent.click(screen.getByRole('button', { name: 'Remove query Recent users' }))
    fireEvent.click(screen.getByRole('button', { name: 'Clear history' }))

    expect(callbacks.onSelect).toHaveBeenCalledWith(historyEntry)
    expect(callbacks.onToggleFavorite).toHaveBeenCalledWith(historyEntry.id)
    expect(callbacks.onRemove).toHaveBeenCalledWith(historyEntry.id)
    expect(callbacks.onClearHistory).toHaveBeenCalledOnce()
  })

  it('separates favorites, shows MongoDB collection metadata, and renders useful empty states', () => {
    const { rerender } = render(
      <QueryLibraryPanel entries={[historyEntry, favoriteEntry]} {...callbacks} />
    )

    fireEvent.click(screen.getByRole('tab', { name: /Favorites/ }))
    expect(screen.getByRole('tab', { name: /Favorites/ })).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByText('Active customers')).toBeInTheDocument()
    expect(screen.getByText('MongoDB')).toBeInTheDocument()
    expect(screen.getByText('Collection: customers')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Remove Active customers from favorites' }))
      .toHaveAttribute('aria-pressed', 'true')

    rerender(<QueryLibraryPanel entries={[historyEntry]} {...callbacks} />)
    expect(screen.getByRole('status')).toHaveTextContent('No favorites yet')
    expect(screen.getByRole('status')).toHaveTextContent('Mark a query as a favorite')
  })

  it('restores focus to the element that opened the panel', async () => {
    const trigger = document.createElement('button')
    document.body.appendChild(trigger)
    trigger.focus()
    const { unmount } = render(<QueryLibraryPanel entries={[]} {...callbacks} />)

    await waitFor(() => expect(screen.getByRole('tab', { name: /History/ })).toHaveFocus())
    unmount()
    expect(trigger).toHaveFocus()
    trigger.remove()
  })

  it('supports arrow-key tabs, Escape, focus containment, and an empty history', async () => {
    render(<QueryLibraryPanel entries={[]} {...callbacks} />)
    const historyTab = screen.getByRole('tab', { name: /History/ })
    const favoritesTab = screen.getByRole('tab', { name: /Favorites/ })

    await waitFor(() => expect(historyTab).toHaveFocus())
    expect(screen.getByRole('status')).toHaveTextContent('No query history yet')
    expect(screen.getByRole('button', { name: 'Clear history' })).toBeDisabled()

    fireEvent.keyDown(historyTab, { key: 'ArrowRight' })
    await waitFor(() => expect(favoritesTab).toHaveFocus())
    expect(favoritesTab).toHaveAttribute('aria-selected', 'true')

    const close = screen.getByRole('button', { name: 'Close query library' })
    close.focus()
    fireEvent.keyDown(close, { key: 'Tab', shiftKey: true })
    expect(screen.getByRole('tabpanel')).toHaveFocus()

    fireEvent.keyDown(screen.getByRole('tabpanel'), { key: 'Escape' })
    expect(callbacks.onClose).toHaveBeenCalledOnce()
  })
})
