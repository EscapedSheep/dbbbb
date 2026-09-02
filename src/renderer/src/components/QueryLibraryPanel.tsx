import { useEffect, useRef, useState } from 'react'
import { Clock3, History, Star, Trash2, X } from 'lucide-react'
import type { QueryEntry } from '../lib/query-library'
import { useRestoreFocus } from './useRestoreFocus'

type LibraryTab = 'history' | 'favorites'

export interface QueryLibraryPanelProps {
  entries: QueryEntry[]
  onSelect: (entry: QueryEntry) => void
  onToggleFavorite: (id: string) => void
  onRemove: (id: string) => void
  onClearHistory: () => void
  onClose: () => void
}

const dateFormatter = new Intl.DateTimeFormat(undefined, {
  dateStyle: 'medium',
  timeStyle: 'short'
})

function formatTime(value: string): string {
  const date = new Date(value)
  return Number.isFinite(date.getTime()) ? dateFormatter.format(date) : 'Unknown time'
}

const ENGINE_LABELS: Record<QueryEntry['engine'], string> = {
  postgresql: 'PostgreSQL',
  mongodb: 'MongoDB',
  mysql: 'MySQL',
  sqlite: 'SQLite'
}

function engineLabel(entry: QueryEntry): string {
  return ENGINE_LABELS[entry.engine]
}

interface EntryListProps {
  entries: QueryEntry[]
  tab: LibraryTab
  onSelect: QueryLibraryPanelProps['onSelect']
  onToggleFavorite: QueryLibraryPanelProps['onToggleFavorite']
  onRemove: QueryLibraryPanelProps['onRemove']
}

function EntryList({
  entries,
  tab,
  onSelect,
  onToggleFavorite,
  onRemove
}: EntryListProps): React.JSX.Element {
  if (entries.length === 0) {
    return (
      <div className="result-empty query-library-empty" role="status">
        {tab === 'history' ? <History size={22} aria-hidden="true" /> : <Star size={22} aria-hidden="true" />}
        <strong>{tab === 'history' ? 'No query history yet' : 'No favorites yet'}</strong>
        <p>
          {tab === 'history'
            ? 'Run a query to keep it in your local history.'
            : 'Mark a query as a favorite to keep it here.'}
        </p>
      </div>
    )
  }

  return (
    <ul className="query-library-list" aria-label={tab === 'history' ? 'Query history' : 'Favorite queries'}>
      {entries.map((entry) => (
        <li className="query-library-entry" key={entry.id}>
          <button
            className="query-library-entry-main"
            type="button"
            onClick={() => onSelect(entry)}
            aria-label={`Open query ${entry.title}`}
          >
            <span className="query-library-entry-heading">
              <strong>{entry.title}</strong>
              <span className="query-library-meta">
                <span className="badge badge-accent">{engineLabel(entry)}</span>
                {entry.command.engine === 'mongodb' && (
                  <span className="badge">Collection: {entry.command.collection}</span>
                )}
                <time dateTime={entry.createdAt}>
                  <Clock3 size={12} aria-hidden="true" />
                  {formatTime(entry.createdAt)}
                </time>
              </span>
            </span>
            <code className="query-library-preview">{entry.command.text}</code>
          </button>
          <div className="query-library-entry-actions">
            <button
              className="icon-button compact"
              type="button"
              onClick={() => onToggleFavorite(entry.id)}
              aria-label={
                entry.favorite
                  ? `Remove ${entry.title} from favorites`
                  : `Add ${entry.title} to favorites`
              }
              aria-pressed={entry.favorite}
            >
              <Star size={14} fill={entry.favorite ? 'currentColor' : 'none'} aria-hidden="true" />
            </button>
            <button
              className="icon-button compact"
              type="button"
              onClick={() => onRemove(entry.id)}
              aria-label={`Remove query ${entry.title}`}
            >
              <Trash2 size={14} aria-hidden="true" />
            </button>
          </div>
        </li>
      ))}
    </ul>
  )
}

export function QueryLibraryPanel({
  entries,
  onSelect,
  onToggleFavorite,
  onRemove,
  onClearHistory,
  onClose
}: QueryLibraryPanelProps): React.JSX.Element {
  const [activeTab, setActiveTab] = useState<LibraryTab>('history')
  const panelRef = useRef<HTMLElement>(null)
  const historyTabRef = useRef<HTMLButtonElement>(null)
  const favoritesTabRef = useRef<HTMLButtonElement>(null)
  const history = entries.filter((entry) => !entry.favorite)
  const favorites = entries.filter((entry) => entry.favorite)
  const visibleEntries = activeTab === 'history' ? history : favorites

  useRestoreFocus()

  useEffect(() => {
    historyTabRef.current?.focus()
  }, [])

  const activateTab = (tab: LibraryTab, moveFocus = false): void => {
    setActiveTab(tab)
    if (moveFocus) {
      window.setTimeout(() => {
        if (tab === 'history') historyTabRef.current?.focus()
        else favoritesTabRef.current?.focus()
      }, 0)
    }
  }

  const handleTabKeyDown = (event: React.KeyboardEvent<HTMLButtonElement>): void => {
    let nextTab: LibraryTab | undefined
    if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
      nextTab = activeTab === 'history' ? 'favorites' : 'history'
    } else if (event.key === 'Home') {
      nextTab = 'history'
    } else if (event.key === 'End') {
      nextTab = 'favorites'
    }

    if (nextTab) {
      event.preventDefault()
      activateTab(nextTab, true)
    }
  }

  const handlePanelKeyDown = (event: React.KeyboardEvent<HTMLElement>): void => {
    if (event.key === 'Escape') {
      event.preventDefault()
      event.stopPropagation()
      onClose()
      return
    }

    if (event.key !== 'Tab' || !panelRef.current) return
    const focusable = Array.from(
      panelRef.current.querySelectorAll<HTMLElement>(
        'button:not(:disabled), [href], input:not(:disabled), [tabindex]:not([tabindex="-1"])'
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

  return (
    <div
      className="dialog-backdrop query-library-backdrop"
      role="presentation"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <section
        ref={panelRef}
        className="dialog query-library-panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby="query-library-title"
        onKeyDown={handlePanelKeyDown}
      >
        <header className="dialog-header">
          <div>
            <h2 id="query-library-title">Query library</h2>
            <p>History and favorites stored only on this device.</p>
          </div>
          <button className="icon-button" type="button" onClick={onClose} aria-label="Close query library">
            <X size={17} aria-hidden="true" />
          </button>
        </header>

        <div className="query-library-body">
          <div className="query-library-toolbar">
            <div className="segmented-control" role="tablist" aria-label="Query library sections">
              <button
                ref={historyTabRef}
                id="query-library-history-tab"
                className={activeTab === 'history' ? 'active' : undefined}
                type="button"
                role="tab"
                aria-selected={activeTab === 'history'}
                aria-controls="query-library-tabpanel"
                tabIndex={activeTab === 'history' ? 0 : -1}
                onClick={() => activateTab('history')}
                onKeyDown={handleTabKeyDown}
              >
                History <span className="badge">{history.length}</span>
              </button>
              <button
                ref={favoritesTabRef}
                id="query-library-favorites-tab"
                className={activeTab === 'favorites' ? 'active' : undefined}
                type="button"
                role="tab"
                aria-selected={activeTab === 'favorites'}
                aria-controls="query-library-tabpanel"
                tabIndex={activeTab === 'favorites' ? 0 : -1}
                onClick={() => activateTab('favorites')}
                onKeyDown={handleTabKeyDown}
              >
                Favorites <span className="badge">{favorites.length}</span>
              </button>
            </div>
            <button
              className="secondary-button"
              type="button"
              onClick={onClearHistory}
              disabled={history.length === 0}
            >
              <Trash2 size={13} aria-hidden="true" />
              Clear history
            </button>
          </div>

          <div
            id="query-library-tabpanel"
            className="query-library-tabpanel"
            role="tabpanel"
            aria-labelledby={
              activeTab === 'history' ? 'query-library-history-tab' : 'query-library-favorites-tab'
            }
            tabIndex={0}
          >
            <EntryList
              entries={visibleEntries}
              tab={activeTab}
              onSelect={onSelect}
              onToggleFavorite={onToggleFavorite}
              onRemove={onRemove}
            />
          </div>
        </div>
      </section>
    </div>
  )
}
