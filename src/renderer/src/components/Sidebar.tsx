import { useEffect, useMemo, useRef, useState } from 'react'
import {
  Braces,
  ChevronDown,
  ChevronRight,
  Circle,
  Database,
  Eye,
  Plus,
  RefreshCw,
  Search,
  Table2
} from 'lucide-react'
import type { ConnectionProfile, DatabaseEngine, DatabaseObjectNode } from '../../../shared/database'

interface SidebarProps {
  connections: ConnectionProfile[]
  selectedConnectionId?: string
  objects: DatabaseObjectNode[]
  objectsLoading: boolean
  connectionsDisabled?: boolean
  onSelectConnection: (connectionId: string) => void
  onSelectObject: (object: DatabaseObjectNode) => void
  onNewConnection: () => void
  onRefreshObjects: () => void
}

const ENGINE_LABELS: Record<DatabaseEngine, string> = {
  postgresql: 'PG',
  mongodb: 'MO',
  mysql: 'MY',
  sqlite: 'SQ'
}

function engineLabel(connection: ConnectionProfile): string {
  return ENGINE_LABELS[connection.engine]
}

function objectIcon(kind: DatabaseObjectNode['kind']): React.JSX.Element {
  if (kind === 'table' || kind === 'view') return <Table2 size={14} />
  if (kind === 'collection') return <Braces size={14} />
  return <Database size={14} />
}

export function Sidebar({
  connections,
  selectedConnectionId,
  objects,
  objectsLoading,
  connectionsDisabled = false,
  onSelectConnection,
  onSelectObject,
  onNewConnection,
  onRefreshObjects
}: SidebarProps): React.JSX.Element {
  const [search, setSearch] = useState('')
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set())
  const searchRef = useRef<HTMLInputElement>(null)
  const normalizedSearch = search.trim().toLowerCase()
  const selectedConnection = connections.find((connection) => connection.id === selectedConnectionId)
  const selectedUnavailable = selectedConnection?.connected === false

  useEffect(() => {
    const focusSearch = (event: KeyboardEvent): void => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'p') {
        if (document.querySelector('[role="dialog"]')) return
        event.preventDefault()
        searchRef.current?.focus()
      }
    }
    window.addEventListener('keydown', focusSearch)
    return () => window.removeEventListener('keydown', focusSearch)
  }, [])

  const filteredConnections = connections.filter((connection) =>
    `${connection.name} ${connection.database} ${connection.endpoint}`
      .toLowerCase()
      .includes(normalizedSearch)
  )

  const objectTree = useMemo(() => {
    const roots = objects.filter((object) => !object.parentId)
    return roots.map((root) => ({
      root,
      children: objects.filter((object) => object.parentId === root.id)
    }))
  }, [objects])

  const toggleExpanded = (id: string): void => {
    setExpanded((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  return (
    <aside className="sidebar" aria-label="Database navigator">
      <div className="sidebar-search">
        <Search size={15} aria-hidden="true" />
        <input
          ref={searchRef}
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Search connections"
          aria-label="Search connections"
        />
        <kbd>Ctrl/⌘ P</kbd>
      </div>

      <section className="sidebar-section connections-section">
        <div className="section-heading">
          <span>Connections</span>
          <button className="icon-button compact" onClick={onNewConnection} aria-label="New connection">
            <Plus size={15} />
          </button>
        </div>

        <div className="connection-list">
          {filteredConnections.map((connection) => {
            const active = connection.id === selectedConnectionId
            return (
              <button
                className={`connection-item${active ? ' active' : ''}`}
                key={connection.id}
                type="button"
                onClick={() => onSelectConnection(connection.id)}
                disabled={connectionsDisabled}
                aria-current={active ? 'page' : undefined}
              >
                <span className={`engine-icon engine-${connection.engine}`}>
                  {engineLabel(connection)}
                </span>
                <span className="connection-copy">
                  <span className="connection-title-row">
                    <strong>{connection.name}</strong>
                    {connection.readOnly && <Eye size={13} aria-label="Read only" />}
                  </span>
                  <span>
                    {connection.endpoint}
                    {connection.connected === false && (
                      <em className="connection-unavailable-label"> · Unavailable</em>
                    )}
                  </span>
                </span>
                <Circle
                  className={connection.connected === false ? 'connection-unavailable' : 'connection-online'}
                  size={8}
                  fill="currentColor"
                  aria-label={connection.connected === false ? 'Unavailable' : 'Connected'}
                />
              </button>
            )
          })}
        </div>
      </section>

      <section className="sidebar-section objects-section">
        <div className="section-heading">
          <span>Objects</span>
          <button
            className="icon-button compact"
            onClick={onRefreshObjects}
            aria-label="Refresh objects"
            disabled={objectsLoading || !selectedConnectionId || selectedUnavailable}
          >
            <RefreshCw size={14} className={objectsLoading ? 'spin' : ''} />
          </button>
        </div>

        {/* Plain nested groups of buttons; no tree roles, since no tree keyboard interaction is offered. */}
        <div className="object-tree">
          {objectsLoading && <div className="tree-placeholder">Loading objects…</div>}
          {!objectsLoading && selectedUnavailable && (
            <div className="tree-placeholder" role="status">Connection unavailable</div>
          )}
          {!objectsLoading && !selectedUnavailable && objectTree.length === 0 && (
            <div className="tree-placeholder">No objects found</div>
          )}
          {!objectsLoading && !selectedUnavailable &&
            objectTree.map(({ root, children }) => {
              const isExpanded = expanded.has(root.id) || normalizedSearch.length > 0
              return (
                <div key={root.id}>
                  <button
                    className="tree-row tree-root"
                    type="button"
                    aria-expanded={children.length > 0 ? isExpanded : undefined}
                    onClick={() => toggleExpanded(root.id)}
                  >
                    {children.length > 0 ? (
                      isExpanded ? <ChevronDown size={13} /> : <ChevronRight size={13} />
                    ) : (
                      <span className="tree-spacer" />
                    )}
                    {objectIcon(root.kind)}
                    <span>{root.name}</span>
                    {root.detail && <small>{root.detail}</small>}
                  </button>
                  {isExpanded && (
                    <div>
                      {children
                        .filter((child) => child.name.toLowerCase().includes(normalizedSearch))
                        .map((child) => (
                          <button
                            className="tree-row tree-child"
                            type="button"
                            key={child.id}
                            onClick={() => onSelectObject(child)}
                          >
                            <span className="tree-spacer" />
                            {objectIcon(child.kind)}
                            <span>{child.name}</span>
                            {child.detail && <small>{child.detail}</small>}
                          </button>
                        ))}
                    </div>
                  )}
                </div>
              )
            })}
        </div>
      </section>
    </aside>
  )
}
