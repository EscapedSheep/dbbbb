import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ImportProgressUpdate, DbbbbApi } from '../../shared/database'
import { DEFAULT_QUERY } from '../../shared/database'
import App from './App'

const api: DbbbbApi = {
  getStartupWarnings: vi.fn(async () => []),
  listConnections: vi.fn(async () => [
    {
      id: 'local-postgres',
      name: 'Local product',
      engine: 'postgresql' as const,
      endpoint: 'localhost:5432',
      database: 'dbbbb_dev',
      environment: 'development' as const,
      readOnly: false,
      demo: true
    }
  ]),
  connect: vi.fn(),
  createDemoConnection: vi.fn(),
  disconnect: vi.fn(async () => undefined),
  forgetConnection: vi.fn(async () => undefined),
  listObjects: vi.fn(async () => [
    { id: 'schema-app', name: 'app', kind: 'schema' as const },
    { id: 'table-users', parentId: 'schema-app', name: 'users', kind: 'table' as const }
  ]),
  previewObject: vi.fn(async () => ({
    engine: 'postgresql' as const,
    kind: 'query' as const,
    text: 'SELECT * FROM "app"."users" LIMIT 100;'
  })),
  execute: vi.fn(async () => ({
    kind: 'rows' as const,
    columns: [{ key: 'email', label: 'email', dataType: 'text' }],
    rows: [['maya@northstar.dev']],
    meta: { elapsedMs: 12, count: 1, truncated: false, source: 'demo' as const }
  })),
  cancel: vi.fn(async () => undefined),
  applyDataChange: vi.fn(async (request) => ({ action: request.action, affected: 1 as const })),
  exportResult: vi.fn(async () => ({ canceled: false, rows: 1, bytes: 32 })),
  chooseImportFile: vi.fn(async () => undefined),
  startImport: vi.fn(async () => ({ processed: 0, inserted: 0, failed: 0 })),
  cancelImport: vi.fn(async () => undefined),
  onImportProgress: vi.fn(() => () => undefined)
}

describe('App vertical slice', () => {
  beforeEach(() => {
    window.localStorage.clear()
    Object.defineProperty(window, 'dbbbb', { configurable: true, value: api })
    vi.clearAllMocks()
    vi.useRealTimers()
    vi.mocked(api.getStartupWarnings).mockResolvedValue([])
  })

  it('loads a connection and renders query results through the preload API', async () => {
    render(<App />)

    expect(await screen.findAllByText('Local product')).not.toHaveLength(0)
    fireEvent.click(screen.getByRole('button', { name: /^Run/ }))

    expect(await screen.findByText('maya@northstar.dev')).toBeInTheDocument()
    expect(api.execute).toHaveBeenCalledWith(
      expect.objectContaining({ connectionId: 'local-postgres', requestId: expect.any(String) })
    )

    fireEvent.click(screen.getByRole('button', { name: 'Export CSV' }))
    await vi.waitFor(() => {
      expect(api.exportResult).toHaveBeenCalledWith(
        expect.objectContaining({
          result: expect.objectContaining({ kind: 'rows' }),
          suggestedBaseName: expect.stringContaining('Local product-dbbbb_dev')
        })
      )
    })
  })

  it('cycles the theme preference through light, dark, and system', async () => {
    render(<App />)
    await screen.findAllByText('Local product')

    fireEvent.click(screen.getByRole('button', { name: /switch to light theme/i }))
    expect(window.localStorage.getItem('dbbbb.theme')).toBe('light')
    expect(document.documentElement.dataset.theme).toBe('light')

    fireEvent.click(screen.getByRole('button', { name: /switch to dark theme/i }))
    expect(window.localStorage.getItem('dbbbb.theme')).toBe('dark')
    expect(document.documentElement.dataset.theme).toBe('dark')

    fireEvent.click(screen.getByRole('button', { name: /switch to system theme/i }))
    expect(window.localStorage.getItem('dbbbb.theme')).toBe('system')
    // jsdom has no matchMedia, so the system preference resolves to light.
    expect(document.documentElement.dataset.theme).toBe('light')
  })

  it('ignores the query library shortcut while any dialog is open', async () => {
    const savedProfile = {
      id: 'saved-postgres',
      name: 'Saved orders',
      engine: 'postgresql' as const,
      endpoint: 'db.example.test:5432',
      database: 'orders',
      environment: 'development' as const,
      readOnly: true,
      demo: false,
      saved: true
    }
    vi.mocked(api.listConnections).mockResolvedValueOnce([savedProfile])

    render(<App />)
    await screen.findByText('Saved')
    fireEvent.click(screen.getByRole('button', {
      name: `Forget saved connection ${savedProfile.name}`
    }))
    const forgetDialog = await screen.findByRole('dialog', { name: 'Forget saved connection?' })

    fireEvent.keyDown(window, { key: 'k', metaKey: true })
    expect(screen.queryByRole('dialog', { name: 'Query library' })).not.toBeInTheDocument()

    fireEvent.keyDown(forgetDialog, { key: 'Escape' })
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())

    fireEvent.keyDown(window, { key: 'k', metaKey: true })
    expect(await screen.findByRole('dialog', { name: 'Query library' })).toBeInTheDocument()
  })

  it('hides the engine label in the status bar when no connection is selected', async () => {
    vi.mocked(api.listConnections).mockResolvedValueOnce([])

    render(<App />)

    expect(await screen.findByText('Not connected')).toBeInTheDocument()
    expect(screen.queryByText('PostgreSQL')).not.toBeInTheDocument()
    expect(screen.queryByText('MongoDB')).not.toBeInTheDocument()
    expect(screen.getByText('UTF-8')).toBeInTheDocument()
  })

  it('uses neutral session wording for MongoDB instead of SQL auto-commit language', async () => {
    const mongoProfile = {
      id: 'local-mongo',
      name: 'Local documents',
      engine: 'mongodb' as const,
      endpoint: 'localhost:27017',
      database: 'dbbbb_dev',
      environment: 'development' as const,
      readOnly: false,
      demo: true
    }
    vi.mocked(api.listConnections).mockResolvedValueOnce([mongoProfile])

    render(<App />)

    expect(await screen.findByText('Standard session')).toBeInTheDocument()
    expect(screen.queryByText('Auto-commit')).not.toBeInTheDocument()
    expect(screen.getByText('MongoDB')).toBeInTheDocument()
  })

  it('labels MySQL and SQLite connections correctly in the status bar', async () => {
    const mysqlProfile = {
      id: 'local-mysql',
      name: 'Local shop',
      engine: 'mysql' as const,
      endpoint: 'localhost:3306',
      database: 'dbbbb_dev',
      environment: 'development' as const,
      readOnly: false,
      demo: true
    }
    vi.mocked(api.listConnections).mockResolvedValueOnce([mysqlProfile])

    const { unmount } = render(<App />)

    expect(await screen.findByText('MySQL')).toBeInTheDocument()
    expect(screen.getByText('Auto-commit')).toBeInTheDocument()
    await waitFor(() =>
      expect(screen.getByLabelText('SQL editor')).toHaveValue(DEFAULT_QUERY.mysql.text)
    )
    unmount()

    const sqliteProfile = {
      id: 'local-sqlite',
      name: 'Local archive',
      engine: 'sqlite' as const,
      endpoint: '/data/archive.sqlite',
      database: 'archive.sqlite',
      environment: 'development' as const,
      readOnly: true,
      demo: true
    }
    vi.mocked(api.listConnections).mockResolvedValueOnce([sqliteProfile])

    render(<App />)

    expect(await screen.findByText('SQLite')).toBeInTheDocument()
    expect(screen.getByText('Read-only session')).toBeInTheDocument()
    await waitFor(() =>
      expect(screen.getByLabelText('SQL editor')).toHaveValue(DEFAULT_QUERY.sqlite.text)
    )
  })

  it('hides record editing and import entry points for MySQL results and objects', async () => {
    const mysqlProfile = {
      id: 'real-mysql',
      name: 'Shop MySQL',
      engine: 'mysql' as const,
      endpoint: 'localhost:3306',
      database: 'dbbbb_dev',
      environment: 'development' as const,
      readOnly: false,
      demo: false
    }
    const previewText = 'SELECT * FROM `users` LIMIT 100;'
    const mysqlApi: DbbbbApi = {
      ...api,
      listConnections: vi.fn(async () => [mysqlProfile]),
      listObjects: vi.fn(async () => [
        { id: 'schema-app', name: 'app', kind: 'schema' as const },
        { id: 'table-users', parentId: 'schema-app', name: 'users', kind: 'table' as const }
      ]),
      previewObject: vi.fn(async () => ({
        engine: 'mysql' as const,
        kind: 'query' as const,
        text: previewText
      })),
      execute: vi.fn(async () => ({
        kind: 'rows' as const,
        columns: [{ key: 'email', label: 'email', dataType: 'varchar' }],
        rows: [['maya@northstar.dev']],
        meta: { elapsedMs: 5, count: 1, truncated: false, source: 'database' as const }
      }))
    }
    Object.defineProperty(window, 'dbbbb', { configurable: true, value: mysqlApi })
    render(<App />)

    expect(await screen.findAllByText('Shop MySQL')).not.toHaveLength(0)
    fireEvent.click(await screen.findByRole('button', { name: 'app' }))
    fireEvent.click(await screen.findByRole('button', { name: 'users' }))
    await waitFor(() => expect(screen.getByLabelText('SQL editor')).toHaveValue(previewText))
    expect(screen.queryByRole('button', { name: 'Import' })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /^Run/ }))
    expect(await screen.findByText('maya@northstar.dev')).toBeInTheDocument()
    expect(mysqlApi.execute).toHaveBeenCalledWith(
      expect.objectContaining({
        command: { engine: 'mysql', kind: 'query', text: previewText }
      })
    )
    expect(screen.queryByRole('button', { name: 'Edit row 1' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Import' })).not.toBeInTheDocument()
  })

  it('clears a status notice automatically after a few seconds', async () => {
    render(<App />)
    await screen.findAllByText('Local product')
    fireEvent.click(screen.getByRole('button', { name: /^Run/ }))
    await screen.findByText('maya@northstar.dev')

    vi.useFakeTimers()
    try {
      fireEvent.click(screen.getByRole('button', { name: 'Export CSV' }))
      await act(async () => undefined)
      expect(screen.getByText('Exported 1 items.')).toBeInTheDocument()

      act(() => vi.advanceTimersByTime(5999))
      expect(screen.getByText('Exported 1 items.')).toBeInTheDocument()
      act(() => vi.advanceTimersByTime(1))
      expect(screen.queryByText('Exported 1 items.')).not.toBeInTheDocument()
    } finally {
      vi.useRealTimers()
    }
  })

  it('marks saved profiles and forgets one only after confirmation', async () => {
    const savedProfile = {
      id: 'saved-postgres',
      name: 'Saved orders',
      engine: 'postgresql' as const,
      endpoint: 'db.example.test:5432',
      database: 'orders',
      environment: 'development' as const,
      readOnly: true,
      demo: false,
      saved: true
    }
    vi.mocked(api.listConnections).mockResolvedValueOnce([savedProfile])

    render(<App />)

    expect(await screen.findByText('Saved')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', {
      name: `Forget saved connection ${savedProfile.name}`
    }))
    expect(await screen.findByRole('dialog', { name: 'Forget saved connection?' })).toHaveTextContent(
      `${savedProfile.name} / ${savedProfile.database}`
    )
    expect(api.forgetConnection).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Forget connection' }))

    await waitFor(() => {
      expect(api.forgetConnection).toHaveBeenCalledWith(savedProfile.id)
      expect(screen.getByText('Not connected')).toBeInTheDocument()
    })
    expect(api.disconnect).not.toHaveBeenCalled()
    expect(screen.queryByText(savedProfile.name)).not.toBeInTheDocument()
  })

  it('disconnects a saved profile for the session without forgetting it', async () => {
    const savedProfile = {
      id: 'saved-postgres',
      name: 'Saved orders',
      engine: 'postgresql' as const,
      endpoint: 'db.example.test:5432',
      database: 'orders',
      environment: 'development' as const,
      readOnly: true,
      demo: false,
      saved: true
    }
    vi.mocked(api.listConnections).mockResolvedValueOnce([savedProfile])

    render(<App />)
    await screen.findByText('Saved')
    fireEvent.click(screen.getByRole('button', { name: `Disconnect ${savedProfile.name}` }))

    await waitFor(() => {
      expect(api.disconnect).toHaveBeenCalledWith(savedProfile.id)
      expect(screen.getByText('Not connected')).toBeInTheDocument()
    })
    expect(api.forgetConnection).not.toHaveBeenCalled()
  })

  it('keeps an unavailable saved profile manageable without opening database operations', async () => {
    const unavailableProfile = {
      id: 'saved-unavailable',
      name: 'Saved archive',
      engine: 'postgresql' as const,
      endpoint: 'archive.example.test:5432',
      database: 'archive',
      environment: 'production' as const,
      readOnly: true,
      demo: false,
      saved: true,
      connected: false,
      storageWarning: 'A saved connection could not be restored. Check its server access and credentials.'
    }
    const demoProfile = {
      id: 'local-postgres',
      name: 'Local product',
      engine: 'postgresql' as const,
      endpoint: 'localhost:5432',
      database: 'dbbbb_dev',
      environment: 'development' as const,
      readOnly: false,
      demo: true
    }
    vi.mocked(api.listConnections).mockResolvedValueOnce([unavailableProfile, demoProfile])

    render(<App />)

    expect(await screen.findByLabelText('Current connection')).toHaveTextContent('Local product')
    await waitFor(() => expect(api.listObjects).toHaveBeenCalledWith(demoProfile.id))
    fireEvent.click(screen.getByRole('button', { name: /Saved archive/ }))

    expect(await screen.findByRole('heading', { name: 'Saved connection unavailable' })).toBeInTheDocument()
    expect(screen.getAllByText('Unavailable').length).toBeGreaterThan(0)
    expect(screen.queryByRole('button', { name: /^Run/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: `Disconnect ${unavailableProfile.name}` })).not.toBeInTheDocument()
    expect(api.listObjects).not.toHaveBeenCalledWith(unavailableProfile.id)

    fireEvent.click(screen.getByRole('button', {
      name: `Forget saved connection ${unavailableProfile.name}`
    }))
    expect(await screen.findByText(
      'Remove this saved profile and its protected credentials.'
    )).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Forget connection' }))

    await waitFor(() => {
      expect(api.forgetConnection).toHaveBeenCalledWith(unavailableProfile.id)
      expect(screen.getByLabelText('Current connection')).toHaveTextContent('Local product')
    })
  })

  it('renders startup credential warnings in the warning status', async () => {
    const warning = 'One saved connection could not be restored safely.'
    vi.mocked(api.getStartupWarnings).mockResolvedValueOnce([warning])

    render(<App />)

    expect(await screen.findByText(warning)).toHaveClass('status-warning')
  })

  it('renders a connection storage warning instead of a saved notice', async () => {
    const warning = 'Secure storage is unavailable; credentials are used only for this session.'
    const connectedProfile = {
      id: 'session-postgres',
      name: 'Session PostgreSQL',
      engine: 'postgresql' as const,
      endpoint: 'localhost:5432',
      database: 'postgres',
      environment: 'development' as const,
      readOnly: true,
      demo: false,
      saved: false,
      storageWarning: warning
    }
    vi.mocked(api.connect).mockResolvedValueOnce(connectedProfile)

    render(<App />)
    await screen.findAllByText('Local product')
    fireEvent.click(screen.getByRole('button', { name: 'New connection' }))
    fireEvent.change(screen.getByLabelText('Username'), { target: { value: 'line_user' } })
    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))

    expect(await screen.findByText(warning)).toHaveClass('status-warning')
    expect(await screen.findAllByText(connectedProfile.name)).not.toHaveLength(0)
  })

  it('edits only a real database result from an unchanged object preview', async () => {
    const realProfile = {
      id: 'real-postgres',
      name: 'Production-like local',
      engine: 'postgresql' as const,
      endpoint: 'localhost:5432',
      database: 'dbbbb_dev',
      environment: 'development' as const,
      readOnly: false,
      demo: false
    }
    const previewText = 'SELECT * FROM "app"."users" LIMIT 100;'
    const realApi: DbbbbApi = {
      ...api,
      listConnections: vi.fn(async () => [realProfile]),
      listObjects: vi.fn(async () => [
        { id: 'schema-app', name: 'app', kind: 'schema' as const },
        { id: 'table-users', parentId: 'schema-app', name: 'users', kind: 'table' as const }
      ]),
      previewObject: vi.fn(async () => ({
        engine: 'postgresql' as const,
        kind: 'query' as const,
        text: previewText
      })),
      execute: vi.fn(async () => ({
        kind: 'rows' as const,
        columns: [
          { key: 'id', label: 'id', dataType: 'int4' },
          { key: 'email', label: 'email', dataType: 'text' }
        ],
        rows: [[7, 'maya@northstar.dev']],
        meta: { elapsedMs: 8, count: 1, truncated: false, source: 'database' as const }
      })),
      applyDataChange: vi.fn(async (request) => ({ action: request.action, affected: 1 as const }))
    }
    Object.defineProperty(window, 'dbbbb', { configurable: true, value: realApi })
    render(<App />)

    expect(await screen.findAllByText('Production-like local')).not.toHaveLength(0)
    fireEvent.click(await screen.findByRole('button', { name: 'app' }))
    fireEvent.click(await screen.findByRole('button', { name: 'users' }))
    await waitFor(() => expect(screen.getByLabelText('SQL editor')).toHaveValue(previewText))

    fireEvent.click(screen.getByRole('button', { name: /^Run/ }))
    expect(await screen.findByText('maya@northstar.dev')).toBeInTheDocument()
    fireEvent.click(await screen.findByRole('button', { name: 'Edit row 1' }))

    fireEvent.change(screen.getByLabelText('Record JSON'), {
      target: {
        value: JSON.stringify({ id: 7, email: 'maya+edited@northstar.dev' }, null, 2)
      }
    })
    fireEvent.click(screen.getByRole('button', { name: 'Review' }))
    fireEvent.click(screen.getByRole('button', { name: 'Apply changes' }))

    await waitFor(() => {
      expect(realApi.applyDataChange).toHaveBeenCalledWith({
        connectionId: realProfile.id,
        objectId: 'table-users',
        engine: 'postgresql',
        action: 'update',
        original: { id: 7, email: 'maya@northstar.dev' },
        current: { id: 7, email: 'maya+edited@northstar.dev' }
      })
      expect(realApi.execute).toHaveBeenCalledTimes(2)
    })

    expect(await screen.findByRole('button', { name: 'Edit row 1' })).toBeEnabled()
    fireEvent.change(screen.getByLabelText('SQL editor'), {
      target: { value: `${previewText}\n-- manually changed` }
    })

    await waitFor(() => {
      expect(screen.queryByRole('button', { name: 'Edit row 1' })).not.toBeInTheDocument()
    })
  })

  it('updates import progress only for the active opaque token and unsubscribes on unmount', async () => {
    const realProfile = {
      id: 'real-postgres-import',
      name: 'Import PostgreSQL',
      engine: 'postgresql' as const,
      endpoint: 'localhost:5432',
      database: 'dbbbb_dev',
      environment: 'development' as const,
      readOnly: false,
      demo: false
    }
    let progressListener: ((update: ImportProgressUpdate) => void) | undefined
    const unsubscribe = vi.fn()
    let finishImport!: (value: { processed: number; inserted: number; failed: number }) => void
    const importFinished = new Promise<{ processed: number; inserted: number; failed: number }>(
      (resolve) => {
        finishImport = resolve
      }
    )
    const progressApi: DbbbbApi = {
      ...api,
      listConnections: vi.fn(async () => [realProfile]),
      listObjects: vi.fn(async () => [
        { id: 'schema-app', name: 'app', kind: 'schema' as const },
        { id: 'table-users', parentId: 'schema-app', name: 'users', kind: 'table' as const }
      ]),
      chooseImportFile: vi.fn(async () => ({
        token: 'active-import-token',
        name: 'users.csv',
        size: 2048
      })),
      startImport: vi.fn(() => importFinished),
      onImportProgress: vi.fn((listener) => {
        progressListener = listener
        return unsubscribe
      })
    }
    Object.defineProperty(window, 'dbbbb', { configurable: true, value: progressApi })
    const { unmount } = render(<App />)

    expect(await screen.findAllByText(realProfile.name)).not.toHaveLength(0)
    fireEvent.click(await screen.findByRole('button', { name: 'app' }))
    fireEvent.click(await screen.findByRole('button', { name: 'users' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Import' }))
    fireEvent.click(screen.getByRole('button', { name: 'Choose .csv' }))
    expect(await screen.findByText('users.csv')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Review import' }))
    fireEvent.click(screen.getByRole('button', { name: 'Confirm import' }))
    await waitFor(() => expect(progressApi.startImport).toHaveBeenCalledWith({
      token: 'active-import-token',
      hasHeader: true
    }))

    const progressbar = screen.getByRole('progressbar', { name: 'Import progress' })
    expect(progressbar).toHaveAttribute('value', '0')
    act(() => progressListener?.({
      token: 'different-token',
      processed: 99,
      inserted: 99,
      failed: 0,
      bytes: 2048,
      totalBytes: 2048
    }))
    expect(progressbar).toHaveAttribute('value', '0')

    act(() => progressListener?.({
      token: 'active-import-token',
      processed: 5,
      inserted: 4,
      failed: 1,
      bytes: 512,
      totalBytes: 2048
    }))
    expect(progressbar).toHaveAttribute('value', '25')
    expect(screen.getByText('25%')).toBeInTheDocument()

    act(() => progressListener?.({
      token: 'active-import-token',
      processed: 10,
      inserted: 9,
      failed: 1,
      bytes: 4096,
      totalBytes: 2048
    }))
    expect(progressbar).toHaveAttribute('value', '100')

    await act(async () => {
      finishImport({ processed: 10, inserted: 9, failed: 1 })
      await importFinished
    })
    expect(await screen.findByText('Import completed')).toBeInTheDocument()

    unmount()
    expect(unsubscribe).toHaveBeenCalledOnce()
  })
})
