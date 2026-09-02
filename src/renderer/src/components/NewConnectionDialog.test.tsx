import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { ConnectionInput, ConnectionProfile, DbbbbApi } from '../../../shared/database'
import { NewConnectionDialog } from './NewConnectionDialog'

const postgresProfile: ConnectionProfile = {
  id: 'postgres-real',
  name: 'Orders',
  engine: 'postgresql',
  endpoint: 'db.example.test:6432',
  database: 'orders',
  environment: 'production',
  readOnly: true,
  demo: false
}

const mongoProfile: ConnectionProfile = {
  id: 'mongo-real',
  name: 'Analytics',
  engine: 'mongodb',
  endpoint: 'cluster.example.test',
  database: 'analytics',
  environment: 'development',
  readOnly: true,
  demo: false
}

const mysqlProfile: ConnectionProfile = {
  id: 'mysql-real',
  name: 'Shop',
  engine: 'mysql',
  endpoint: 'db.example.test:3306',
  database: 'shop',
  environment: 'staging',
  readOnly: true,
  demo: false
}

const sqliteProfile: ConnectionProfile = {
  id: 'sqlite-real',
  name: 'Local archive',
  engine: 'sqlite',
  endpoint: '/data/archive.sqlite',
  database: 'archive.sqlite',
  environment: 'development',
  readOnly: true,
  demo: false
}

describe('NewConnectionDialog', () => {
  const connect = vi.fn<(input: ConnectionInput) => Promise<ConnectionProfile>>()

  beforeEach(() => {
    window.localStorage.clear()
    vi.clearAllMocks()
    Object.defineProperty(window, 'dbbbb', {
      configurable: true,
      value: { connect } as Pick<DbbbbApi, 'connect'>
    })
  })

  it('connects to PostgreSQL with explicit SSL, environment, and guardrail settings', async () => {
    connect.mockResolvedValue(postgresProfile)
    const onConnected = vi.fn()

    render(<NewConnectionDialog onClose={vi.fn()} onConnected={onConnected} />)

    fireEvent.change(screen.getByLabelText('Connection name'), { target: { value: 'Orders' } })
    fireEvent.change(screen.getByLabelText('Host'), { target: { value: 'db.example.test' } })
    fireEvent.change(screen.getByLabelText('Port'), { target: { value: '6432' } })
    fireEvent.change(screen.getByLabelText('Database'), { target: { value: 'orders' } })
    fireEvent.change(screen.getByLabelText('Username'), { target: { value: 'line_user' } })
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'session-secret' } })
    fireEvent.change(screen.getByLabelText('SSL mode'), { target: { value: 'require' } })
    fireEvent.change(screen.getByLabelText('Environment'), { target: { value: 'production' } })
    expect(screen.getByText('Passwords are used for this session only and are never saved.')).toBeInTheDocument()
    fireEvent.click(screen.getByLabelText('Remember and reconnect'))
    expect(screen.getByText(
      'If secure storage is unavailable, dbbbb connects without saving credentials.'
    )).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))

    await waitFor(() => {
      expect(connect).toHaveBeenCalledWith({
        engine: 'postgresql',
        name: 'Orders',
        host: 'db.example.test',
        port: 6432,
        database: 'orders',
        username: 'line_user',
        password: 'session-secret',
        sslMode: 'require',
        environment: 'production',
        readOnly: true,
        remember: true
      })
      expect(onConnected).toHaveBeenCalledWith(postgresProfile)
    })

    expect(screen.getByLabelText('Password')).toHaveValue('')
    expect(window.localStorage).toHaveLength(0)
  })

  it('removes pasted MongoDB credentials from the URI and supports the legacy callback', async () => {
    connect.mockResolvedValue(mongoProfile)
    const onCreated = vi.fn()

    render(<NewConnectionDialog onClose={vi.fn()} onCreated={onCreated} />)
    fireEvent.click(screen.getByRole('button', { name: /MongoDB/ }))
    fireEvent.change(screen.getByLabelText('Connection name'), { target: { value: 'Analytics' } })
    fireEvent.change(screen.getByLabelText('MongoDB URI'), {
      target: { value: 'mongodb+srv://line_user:session-secret@cluster.example.test/test?retryWrites=true' }
    })
    fireEvent.change(screen.getByLabelText('Database'), { target: { value: 'analytics' } })

    expect(screen.getByLabelText('MongoDB URI')).toHaveValue(
      'mongodb+srv://cluster.example.test/test?retryWrites=true'
    )
    expect(screen.getByLabelText('Username (optional)')).toHaveValue('line_user')
    expect(screen.getByLabelText('Password (optional)')).toHaveAttribute('type', 'password')
    expect(screen.getByLabelText(/Require TLS/)).toBeChecked()
    expect(screen.getByText('Credentials moved out of the URI')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))

    await waitFor(() => {
      expect(connect).toHaveBeenCalledWith({
        engine: 'mongodb',
        name: 'Analytics',
        uri: 'mongodb+srv://cluster.example.test/test?retryWrites=true',
        database: 'analytics',
        username: 'line_user',
        password: 'session-secret',
        tls: true,
        environment: 'development',
        readOnly: true
      })
      expect(onCreated).toHaveBeenCalledWith(mongoProfile)
    })
    expect(connect.mock.calls[0]?.[0]).not.toHaveProperty('remember')

    expect(screen.getByLabelText('Password (optional)')).toHaveValue('')
    expect(window.localStorage).toHaveLength(0)
  })

  it('auto-enables TLS for MongoDB SRV URIs but still allows an informed opt-out', async () => {
    connect.mockResolvedValue(mongoProfile)

    render(<NewConnectionDialog onClose={vi.fn()} onConnected={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: /MongoDB/ }))
    fireEvent.change(screen.getByLabelText('MongoDB URI'), {
      target: { value: 'mongodb+srv://cluster.example.test/analytics' }
    })

    const tlsToggle = screen.getByLabelText(/Require TLS/)
    expect(tlsToggle).toBeChecked()

    fireEvent.click(tlsToggle)
    expect(tlsToggle).not.toBeChecked()
    expect(screen.getByText(/TLS is off/i)).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))
    await waitFor(() => {
      expect(connect).toHaveBeenCalledWith(expect.objectContaining({
        uri: 'mongodb+srv://cluster.example.test/analytics',
        tls: false
      }))
    })
  })

  it('connects to MySQL with the shared server field family and default port 3306', async () => {
    connect.mockResolvedValue(mysqlProfile)
    const onConnected = vi.fn()

    render(<NewConnectionDialog onClose={vi.fn()} onConnected={onConnected} />)
    fireEvent.click(screen.getByRole('button', { name: /MySQL/ }))

    expect(screen.getByLabelText('Connection name')).toHaveValue('Local MySQL')
    expect(screen.getByLabelText('Port')).toHaveValue(3306)
    fireEvent.change(screen.getByLabelText('Connection name'), { target: { value: 'Shop' } })
    fireEvent.change(screen.getByLabelText('Host'), { target: { value: 'db.example.test' } })
    fireEvent.change(screen.getByLabelText('Database'), { target: { value: 'shop' } })
    fireEvent.change(screen.getByLabelText('Username'), { target: { value: 'shop_user' } })
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'session-secret' } })
    fireEvent.change(screen.getByLabelText('SSL mode'), { target: { value: 'require' } })
    fireEvent.change(screen.getByLabelText('Environment'), { target: { value: 'staging' } })
    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))

    await waitFor(() => {
      expect(connect).toHaveBeenCalledWith({
        engine: 'mysql',
        name: 'Shop',
        host: 'db.example.test',
        port: 3306,
        database: 'shop',
        username: 'shop_user',
        password: 'session-secret',
        sslMode: 'require',
        environment: 'staging',
        readOnly: true
      })
      expect(onConnected).toHaveBeenCalledWith(mysqlProfile)
    })

    expect(screen.getByLabelText('Password')).toHaveValue('')
    expect(window.localStorage).toHaveLength(0)
  })

  it('validates MySQL fields with engine-specific messages and focuses the invalid field', async () => {
    render(<NewConnectionDialog onClose={vi.fn()} onConnected={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: /MySQL/ }))

    fireEvent.change(screen.getByLabelText('Host'), { target: { value: ' ' } })
    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Enter the MySQL server host.')
    await waitFor(() => expect(screen.getByLabelText('Host')).toHaveFocus())
    expect(connect).not.toHaveBeenCalled()

    fireEvent.change(screen.getByLabelText('Host'), { target: { value: 'db.example.test' } })
    fireEvent.change(screen.getByLabelText('Port'), { target: { value: '0' } })
    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))

    expect(await screen.findByRole('alert')).toHaveTextContent(/1 to 65535/)
    await waitFor(() => expect(screen.getByLabelText('Port')).toHaveFocus())
    expect(connect).not.toHaveBeenCalled()
  })

  it('connects to SQLite with a file path and derives the database label from it', async () => {
    connect.mockResolvedValue(sqliteProfile)
    const onConnected = vi.fn()

    render(<NewConnectionDialog onClose={vi.fn()} onConnected={onConnected} />)
    fireEvent.click(screen.getByRole('button', { name: /SQLite/ }))

    expect(screen.getByLabelText('Connection name')).toHaveValue('Local SQLite')
    expect(screen.queryByLabelText('Database')).not.toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Database file'), {
      target: { value: '/data/archive.sqlite' }
    })
    fireEvent.click(screen.getByLabelText('Remember and reconnect'))
    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))

    await waitFor(() => {
      expect(connect).toHaveBeenCalledWith({
        engine: 'sqlite',
        name: 'Local SQLite',
        database: 'archive.sqlite',
        filePath: '/data/archive.sqlite',
        environment: 'development',
        readOnly: true,
        remember: true
      })
      expect(onConnected).toHaveBeenCalledWith(sqliteProfile)
    })
    expect(window.localStorage).toHaveLength(0)
  })

  it('requires a SQLite file path before connecting', async () => {
    render(<NewConnectionDialog onClose={vi.fn()} onConnected={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: /SQLite/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Enter the SQLite database file path.')
    await waitFor(() => expect(screen.getByLabelText('Database file')).toHaveFocus())
    expect(connect).not.toHaveBeenCalled()
  })

  it('shows an actionable connection error without echoing backend secrets', async () => {
    connect.mockRejectedValue(      new Error('connect ECONNREFUSED postgresql://line_user:server-secret@db.example.test:5432/orders')
    )

    render(<NewConnectionDialog onClose={vi.fn()} onConnected={vi.fn()} />)
    fireEvent.change(screen.getByLabelText('Username'), { target: { value: 'line_user' } })
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'server-secret' } })
    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))

    const alert = await screen.findByRole('alert')
    expect(alert).toHaveTextContent(/server refused the connection/i)
    expect(alert).not.toHaveTextContent('server-secret')
    expect(alert).toHaveFocus()
  })

  it('focuses invalid fields and closes with Escape', async () => {
    const onClose = vi.fn()
    render(<NewConnectionDialog onClose={onClose} onConnected={vi.fn()} />)

    fireEvent.change(screen.getByLabelText('Port'), { target: { value: '70000' } })
    fireEvent.change(screen.getByLabelText('Username'), { target: { value: 'line_user' } })
    fireEvent.click(screen.getByRole('button', { name: 'Connect' }))

    expect(await screen.findByRole('alert')).toHaveTextContent(/1 to 65535/)
    await waitFor(() => expect(screen.getByLabelText('Port')).toHaveFocus())
    expect(connect).not.toHaveBeenCalled()

    fireEvent.keyDown(window, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledOnce()
  })
})
