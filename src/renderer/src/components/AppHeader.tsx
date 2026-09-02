import { Database, History, KeyRound, Monitor, Moon, PanelLeftClose, PanelLeftOpen, Sun, TriangleAlert, Trash2, Unplug } from 'lucide-react'
import type { ConnectionProfile } from '../../../shared/database'
import type { ThemePreference } from '../lib/theme'

interface AppHeaderProps {
  connection?: ConnectionProfile
  themePreference: ThemePreference
  sidebarOpen: boolean
  onToggleSidebar: () => void
  onToggleTheme: () => void
  onOpenQueryLibrary: () => void
  queryLibraryCount: number
  onDisconnect: () => void
  onForget: () => void
  disconnectDisabled: boolean
}

function nextThemePreference(preference: ThemePreference): ThemePreference {
  return preference === 'light' ? 'dark' : preference === 'dark' ? 'system' : 'light'
}

export function AppHeader({
  connection,
  themePreference,
  sidebarOpen,
  onToggleSidebar,
  onToggleTheme,
  onOpenQueryLibrary,
  queryLibraryCount,
  onDisconnect,
  onForget,
  disconnectDisabled
}: AppHeaderProps): React.JSX.Element {
  const nextTheme = nextThemePreference(themePreference)
  return (
    <header className="app-header">
      <div className="header-leading">
        <button
          className="icon-button"
          type="button"
          onClick={onToggleSidebar}
          aria-label={sidebarOpen ? 'Hide navigator' : 'Show navigator'}
          title={sidebarOpen ? 'Hide navigator' : 'Show navigator'}
        >
          {sidebarOpen ? <PanelLeftClose size={17} /> : <PanelLeftOpen size={17} />}
        </button>
        <div className="wordmark" aria-label="dbbbb">
          <span className="wordmark-mark" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
          <span>dbbbb</span>
        </div>
        {connection && (
          <div className="connection-breadcrumb" aria-label="Current connection">
            <Database size={14} />
            <span>{connection.name}</span>
            <span className="breadcrumb-slash">/</span>
            <span className="muted">{connection.database}</span>
          </div>
        )}
      </div>

      <div className="header-actions">
        {connection?.environment === 'production' && (
          <span className="badge badge-danger">Production</span>
        )}
        {connection?.readOnly && <span className="badge badge-neutral">Read only</span>}
        {connection?.saved && (
          <span className="badge badge-neutral"><KeyRound size={11} /> Saved</span>
        )}
        {connection?.connected === false && (
          <span className="badge badge-warning"><TriangleAlert size={11} /> Unavailable</span>
        )}
        <button
          className="icon-button"
          type="button"
          onClick={onOpenQueryLibrary}
          aria-label={`Open query library${queryLibraryCount > 0 ? `, ${queryLibraryCount} entries` : ''}`}
          title="Query library"
        >
          <History size={16} />
        </button>
        <span className="header-shortcut" aria-label="Open query library shortcut">
          Ctrl/⌘ K
        </span>
        {connection && connection.connected !== false && (
          <button
            className="icon-button"
            type="button"
            onClick={onDisconnect}
            disabled={disconnectDisabled}
            aria-label={`Disconnect ${connection.name}`}
            title={connection.saved ? `Disconnect ${connection.name} for this session` : `Disconnect ${connection.name}`}
          >
            <Unplug size={16} />
          </button>
        )}
        {connection?.saved && (
          <button
            className="icon-button"
            type="button"
            onClick={onForget}
            disabled={disconnectDisabled}
            aria-label={`Forget saved connection ${connection.name}`}
            title={`Forget saved connection ${connection.name}`}
          >
            <Trash2 size={15} />
          </button>
        )}
        <button
          className="icon-button"
          type="button"
          onClick={onToggleTheme}
          aria-label={`Switch to ${nextTheme} theme (current: ${themePreference})`}
          title={`Switch to ${nextTheme} theme (current: ${themePreference})`}
        >
          {themePreference === 'dark' ? (
            <Moon size={17} />
          ) : themePreference === 'system' ? (
            <Monitor size={17} />
          ) : (
            <Sun size={17} />
          )}
        </button>
      </div>
    </header>
  )
}
