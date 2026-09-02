import { useEffect, useRef, useState } from 'react'
import { Braces, Database, HardDrive, Server, ShieldAlert, ShieldCheck, X } from 'lucide-react'
import type {
  ConnectionEnvironment,
  ConnectionInput,
  ConnectionProfile,
  DatabaseEngine,
  PostgresSslMode
} from '../../../shared/database'

type ConnectedHandler = (profile: ConnectionProfile) => void

export type NewConnectionDialogProps = {
  onClose: () => void
} & (
  | { onConnected: ConnectedHandler; onCreated?: ConnectedHandler }
  /** @deprecated Use onConnected. Retained while callers migrate from demo connections. */
  | { onConnected?: undefined; onCreated: ConnectedHandler }
)

interface FormError {
  message: string
  fieldId?: string
}

const DEFAULT_NAMES: Record<DatabaseEngine, string> = {
  postgresql: 'Local PostgreSQL',
  mongodb: 'Local MongoDB',
  mysql: 'Local MySQL',
  sqlite: 'Local SQLite'
}

function decodeUriPart(value: string): string {
  try {
    return decodeURIComponent(value)
  } catch {
    return value
  }
}

/**
 * Credentials in pasted MongoDB URIs are moved to password controls immediately,
 * so the URI field cannot keep displaying or later persist a password.
 */
function extractMongoUriCredentials(value: string): {
  uri: string
  username?: string
  password?: string
  hadCredentials: boolean
} {
  const schemeMatch = value.match(/^mongodb(?:\+srv)?:\/\//i)
  if (!schemeMatch) return { uri: value, hadCredentials: false }

  const authorityStart = schemeMatch[0].length
  const remainder = value.slice(authorityStart)
  const authorityEndOffset = remainder.search(/[/?#]/)
  const authorityEnd = authorityEndOffset === -1 ? value.length : authorityStart + authorityEndOffset
  const authority = value.slice(authorityStart, authorityEnd)
  const atIndex = authority.lastIndexOf('@')

  if (atIndex < 0) return { uri: value, hadCredentials: false }

  const userInfo = authority.slice(0, atIndex)
  const separator = userInfo.indexOf(':')
  const username = decodeUriPart(separator < 0 ? userInfo : userInfo.slice(0, separator))
  const password = separator < 0 ? undefined : decodeUriPart(userInfo.slice(separator + 1))
  const uri = `${value.slice(0, authorityStart)}${authority.slice(atIndex + 1)}${value.slice(authorityEnd)}`

  return { uri, username, password, hadCredentials: true }
}

function safeConnectionError(reason: unknown, engine: DatabaseEngine): string {
  const source = reason instanceof Error ? reason.message : typeof reason === 'string' ? reason : ''
  const message = source.toLowerCase()

  if (/password authentication failed|authentication failed|auth failed|unauthorized|bad auth/.test(message)) {
    return 'Authentication failed. Check the username, password, and authentication settings.'
  }
  if (/pg_hba|no pg_hba/.test(message)) {
    return 'The PostgreSQL server rejected this client. Check pg_hba.conf, the user, and the SSL mode.'
  }
  if (/enotfound|eai_again|dns|srv host/.test(message)) {
    return 'The server name could not be resolved. Check the host or MongoDB SRV URI and your network.'
  }
  if (/econnrefused|connection refused/.test(message)) {
    return 'The server refused the connection. Check that it is running and that the host and port are reachable.'
  }
  if (/timeout|timed out|server selection/.test(message)) {
    return 'The connection timed out. Check the address, firewall, VPN, and server allowlist.'
  }
  if (/hostname.*match|altname|certificate.*name/.test(message)) {
    return 'The TLS certificate does not match this host. Use the certificate host name or review the SSL mode.'
  }
  if (/certificate|self[- ]signed|unable to verify|unknown ca/.test(message)) {
    return 'The TLS certificate could not be verified. Install the correct CA or explicitly review the SSL mode.'
  }
  if (/database .* does not exist|namespace.*not found/.test(message)) {
    return 'The database was not found. Check its name and your access permissions.'
  }

  const fallbacks: Record<DatabaseEngine, string> = {
    postgresql: 'Could not connect to PostgreSQL. Check the address, credentials, SSL mode, and server logs.',
    mongodb: 'Could not connect to MongoDB. Check the URI, credentials, TLS setting, and server allowlist.',
    mysql: 'Could not connect to MySQL. Check the address, credentials, SSL mode, and server logs.',
    sqlite: 'Could not open the SQLite database file. Check the file path and your access permissions.'
  }
  return fallbacks[engine]
}

export function NewConnectionDialog(props: NewConnectionDialogProps): React.JSX.Element {
  const { onClose } = props
  const onConnected = props.onConnected ?? props.onCreated
  const dialogRef = useRef<HTMLElement>(null)
  const errorRef = useRef<HTMLDivElement>(null)

  const [engine, setEngine] = useState<DatabaseEngine>('postgresql')
  const [name, setName] = useState(DEFAULT_NAMES.postgresql)
  const [database, setDatabase] = useState('postgres')
  const [environment, setEnvironment] = useState<ConnectionEnvironment>('development')
  const [readOnly, setReadOnly] = useState(true)
  const [remember, setRemember] = useState(false)

  const [host, setHost] = useState('localhost')
  const [port, setPort] = useState('5432')
  const [serverUsername, setServerUsername] = useState('')
  const [serverPassword, setServerPassword] = useState('')
  const [sslMode, setSslMode] = useState<PostgresSslMode>('verify-full')

  const [sqliteFilePath, setSqliteFilePath] = useState('')

  const [mongoUri, setMongoUri] = useState('mongodb://localhost:27017')
  const [mongoUsername, setMongoUsername] = useState('')
  const [mongoPassword, setMongoPassword] = useState('')
  const [mongoTls, setMongoTls] = useState(false)
  const [credentialNotice, setCredentialNotice] = useState(false)

  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<FormError>()

  const clearPasswords = (): void => {
    setServerPassword('')
    setMongoPassword('')
  }

  const closeDialog = (): void => {
    if (submitting) return
    clearPasswords()
    onClose()
  }

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape' && !submitting) {
        event.preventDefault()
        clearPasswords()
        onClose()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [onClose, submitting])

  useEffect(() => {
    if (!error) return

    errorRef.current?.focus()
    if (error.fieldId) {
      window.setTimeout(() => document.getElementById(error.fieldId!)?.focus(), 0)
    }
  }, [error])

  const handleDialogKeyDown = (event: React.KeyboardEvent<HTMLElement>): void => {
    if (event.key !== 'Tab' || !dialogRef.current) return

    const focusable = Array.from(
      dialogRef.current.querySelectorAll<HTMLElement>(
        'button:not(:disabled), input:not(:disabled), select:not(:disabled), [href], [tabindex]:not([tabindex="-1"])'
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

  const chooseEngine = (nextEngine: DatabaseEngine): void => {
    if (nextEngine === engine) return
    setName((current) => current === DEFAULT_NAMES[engine] ? DEFAULT_NAMES[nextEngine] : current)
    setDatabase(nextEngine === 'postgresql' ? 'postgres' : 'test')
    setPort(nextEngine === 'mysql' ? '3306' : '5432')
    setEngine(nextEngine)
    setError(undefined)
  }

  const updateMongoUri = (value: string): void => {
    const extracted = extractMongoUriCredentials(value)
    setMongoUri(extracted.uri)
    if (extracted.hadCredentials) {
      setMongoUsername(extracted.username ?? '')
      if (extracted.password !== undefined) setMongoPassword(extracted.password)
      setCredentialNotice(true)
    }
    if (/^mongodb\+srv:\/\//i.test(extracted.uri)) setMongoTls(true)
  }

  const reportValidationError = (message: string, fieldId: string): void => {
    setError({ message, fieldId })
  }

  const buildInput = (): ConnectionInput | undefined => {
    const cleanName = name.trim()
    const cleanDatabase = database.trim()
    if (!cleanName) {
      reportValidationError('Enter a name for this connection.', 'connection-name')
      return undefined
    }

    if (engine === 'postgresql' || engine === 'mysql') {
      const engineName = engine === 'postgresql' ? 'PostgreSQL' : 'MySQL'
      const cleanHost = host.trim()
      const numericPort = Number(port)
      const cleanUsername = serverUsername.trim()

      if (!cleanHost) {
        reportValidationError(`Enter the ${engineName} server host.`, `${engine}-host`)
        return undefined
      }
      if (!Number.isInteger(numericPort) || numericPort < 1 || numericPort > 65_535) {
        reportValidationError('Enter a port from 1 to 65535.', `${engine}-port`)
        return undefined
      }
      if (!cleanDatabase) {
        reportValidationError(`Enter the ${engineName} database name.`, 'connection-database')
        return undefined
      }
      if (!cleanUsername) {
        reportValidationError(`Enter the ${engineName} username.`, `${engine}-username`)
        return undefined
      }

      const shared = {
        name: cleanName,
        host: cleanHost,
        port: numericPort,
        database: cleanDatabase,
        username: cleanUsername,
        password: serverPassword,
        sslMode,
        environment,
        readOnly,
        ...(remember ? { remember: true } : {})
      }
      return engine === 'postgresql'
        ? { engine: 'postgresql', ...shared }
        : { engine: 'mysql', ...shared }
    }

    if (engine === 'sqlite') {
      const cleanFilePath = sqliteFilePath.trim()
      if (!cleanFilePath) {
        reportValidationError('Enter the SQLite database file path.', 'sqlite-file-path')
        return undefined
      }

      return {
        engine: 'sqlite',
        name: cleanName,
        database: cleanFilePath.split(/[\\/]/).filter(Boolean).pop() ?? cleanFilePath,
        filePath: cleanFilePath,
        environment,
        readOnly,
        ...(remember ? { remember: true } : {})
      }
    }

    const cleanUri = mongoUri.trim()
    const cleanUsername = mongoUsername.trim()
    if (!/^mongodb(?:\+srv)?:\/\/[^/?#]+/i.test(cleanUri)) {
      reportValidationError('Enter a MongoDB URI beginning with mongodb:// or mongodb+srv://.', 'mongo-uri')
      return undefined
    }
    if (!cleanDatabase) {
      reportValidationError('Enter the MongoDB database name.', 'connection-database')
      return undefined
    }
    if (mongoPassword && !cleanUsername) {
      reportValidationError('Enter the username that belongs to this MongoDB password.', 'mongo-username')
      return undefined
    }

    return {
      engine: 'mongodb',
      name: cleanName,
      uri: cleanUri,
      database: cleanDatabase,
      username: cleanUsername || undefined,
      password: mongoPassword || undefined,
      tls: mongoTls,
      environment,
      readOnly,
      ...(remember ? { remember: true } : {})
    }
  }

  const handleSubmit = async (event: React.FormEvent): Promise<void> => {
    event.preventDefault()
    if (submitting) return

    setError(undefined)
    const input = buildInput()
    if (!input) return

    setSubmitting(true)
    try {
      const profile = await window.dbbbb.connect(input)
      clearPasswords()
      onConnected(profile)
    } catch (reason) {
      setError({ message: safeConnectionError(reason, engine) })
    } finally {
      setSubmitting(false)
    }
  }

  const fieldIsInvalid = (fieldId: string): boolean => error?.fieldId === fieldId
  const transportWarning = engine === 'postgresql' || engine === 'mysql'
    ? sslMode === 'disable'
      ? 'SSL is disabled. Credentials and query data can travel unencrypted.'
      : sslMode === 'require'
        ? 'SSL is encrypted, but the server identity is not verified in require mode.'
        : undefined
    : engine === 'mongodb' && !mongoTls
      ? 'TLS is off. Enable it for remote or untrusted networks.'
      : undefined

  return (
    <div
      className="dialog-backdrop"
      role="presentation"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) closeDialog()
      }}
    >
      <section
        ref={dialogRef}
        className="dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="new-connection-title"
        aria-describedby="new-connection-description credential-storage-note"
        aria-busy={submitting}
        onKeyDown={handleDialogKeyDown}
      >
        <header className="dialog-header">
          <div>
            <h2 id="new-connection-title">New connection</h2>
            <p id="new-connection-description">Connect directly to PostgreSQL, MySQL, MongoDB, or SQLite.</p>
          </div>
          <button
            className="icon-button"
            type="button"
            onClick={closeDialog}
            aria-label="Close dialog"
            disabled={submitting}
          >
            <X size={17} aria-hidden="true" />
          </button>
        </header>

        <form onSubmit={handleSubmit} noValidate>
          <fieldset className="engine-picker" disabled={submitting}>
            <legend>Database engine</legend>
            <button
              className={engine === 'postgresql' ? 'engine-option active' : 'engine-option'}
              type="button"
              aria-pressed={engine === 'postgresql'}
              onClick={() => chooseEngine('postgresql')}
            >
              <Database size={19} aria-hidden="true" />
              <span>
                <strong>PostgreSQL</strong>
                <small>Tables and SQL</small>
              </span>
            </button>
            <button
              className={engine === 'mongodb' ? 'engine-option active' : 'engine-option'}
              type="button"
              aria-pressed={engine === 'mongodb'}
              onClick={() => chooseEngine('mongodb')}
            >
              <Braces size={19} aria-hidden="true" />
              <span>
                <strong>MongoDB</strong>
                <small>Documents and filters</small>
              </span>
            </button>
            <button
              className={engine === 'mysql' ? 'engine-option active' : 'engine-option'}
              type="button"
              aria-pressed={engine === 'mysql'}
              onClick={() => chooseEngine('mysql')}
            >
              <Server size={19} aria-hidden="true" />
              <span>
                <strong>MySQL</strong>
                <small>Tables and SQL</small>
              </span>
            </button>
            <button
              className={engine === 'sqlite' ? 'engine-option active' : 'engine-option'}
              type="button"
              aria-pressed={engine === 'sqlite'}
              onClick={() => chooseEngine('sqlite')}
            >
              <HardDrive size={19} aria-hidden="true" />
              <span>
                <strong>SQLite</strong>
                <small>Local database file</small>
              </span>
            </button>
          </fieldset>

          <div className="form-grid">
            <label className="field field-wide" htmlFor="connection-name">
              <span>Connection name</span>
              <input
                id="connection-name"
                autoFocus
                value={name}
                onChange={(event) => setName(event.target.value)}
                aria-invalid={fieldIsInvalid('connection-name')}
                aria-describedby={fieldIsInvalid('connection-name') ? 'connection-error' : undefined}
                disabled={submitting}
              />
            </label>

            {engine === 'postgresql' || engine === 'mysql' ? (
              <>
                <label className="field" htmlFor={`${engine}-host`}>
                  <span>Host</span>
                  <input
                    id={`${engine}-host`}
                    value={host}
                    onChange={(event) => setHost(event.target.value)}
                    autoComplete="off"
                    spellCheck={false}
                    aria-invalid={fieldIsInvalid(`${engine}-host`)}
                    aria-describedby={fieldIsInvalid(`${engine}-host`) ? 'connection-error' : undefined}
                    disabled={submitting}
                  />
                </label>
                <label className="field" htmlFor={`${engine}-port`}>
                  <span>Port</span>
                  <input
                    id={`${engine}-port`}
                    type="number"
                    inputMode="numeric"
                    min={1}
                    max={65_535}
                    value={port}
                    onChange={(event) => setPort(event.target.value)}
                    aria-invalid={fieldIsInvalid(`${engine}-port`)}
                    aria-describedby={fieldIsInvalid(`${engine}-port`) ? 'connection-error' : undefined}
                    disabled={submitting}
                  />
                </label>
                <label className="field" htmlFor="connection-database">
                  <span>Database</span>
                  <input
                    id="connection-database"
                    value={database}
                    onChange={(event) => setDatabase(event.target.value)}
                    autoComplete="off"
                    spellCheck={false}
                    aria-invalid={fieldIsInvalid('connection-database')}
                    aria-describedby={fieldIsInvalid('connection-database') ? 'connection-error' : undefined}
                    disabled={submitting}
                  />
                </label>
                <label className="field" htmlFor={`${engine}-username`}>
                  <span>Username</span>
                  <input
                    id={`${engine}-username`}
                    value={serverUsername}
                    onChange={(event) => setServerUsername(event.target.value)}
                    autoComplete="username"
                    spellCheck={false}
                    aria-invalid={fieldIsInvalid(`${engine}-username`)}
                    aria-describedby={fieldIsInvalid(`${engine}-username`) ? 'connection-error' : undefined}
                    disabled={submitting}
                  />
                </label>
                <label className="field" htmlFor={`${engine}-password`}>
                  <span>Password</span>
                  <input
                    id={`${engine}-password`}
                    type="password"
                    value={serverPassword}
                    onChange={(event) => setServerPassword(event.target.value)}
                    autoComplete="new-password"
                    disabled={submitting}
                  />
                </label>
                <label className="field" htmlFor={`${engine}-ssl-mode`}>
                  <span>SSL mode</span>
                  <select
                    id={`${engine}-ssl-mode`}
                    value={sslMode}
                    onChange={(event) => setSslMode(event.target.value as PostgresSslMode)}
                    disabled={submitting}
                  >
                    <option value="verify-full">Verify full (recommended)</option>
                    <option value="require">Require encryption</option>
                    <option value="disable">Disable SSL</option>
                  </select>
                </label>
              </>
            ) : engine === 'mongodb' ? (
              <>
                <label className="field field-wide" htmlFor="mongo-uri">
                  <span>MongoDB URI</span>
                  <input
                    id="mongo-uri"
                    value={mongoUri}
                    onChange={(event) => updateMongoUri(event.target.value)}
                    placeholder="mongodb://host:27017"
                    autoComplete="off"
                    spellCheck={false}
                    aria-invalid={fieldIsInvalid('mongo-uri')}
                    aria-describedby={fieldIsInvalid('mongo-uri') ? 'connection-error' : undefined}
                    disabled={submitting}
                  />
                </label>
                <label className="field" htmlFor="connection-database">
                  <span>Database</span>
                  <input
                    id="connection-database"
                    value={database}
                    onChange={(event) => setDatabase(event.target.value)}
                    autoComplete="off"
                    spellCheck={false}
                    aria-invalid={fieldIsInvalid('connection-database')}
                    aria-describedby={fieldIsInvalid('connection-database') ? 'connection-error' : undefined}
                    disabled={submitting}
                  />
                </label>
                <label className="field" htmlFor="mongo-username">
                  <span>Username (optional)</span>
                  <input
                    id="mongo-username"
                    value={mongoUsername}
                    onChange={(event) => setMongoUsername(event.target.value)}
                    autoComplete="username"
                    spellCheck={false}
                    aria-invalid={fieldIsInvalid('mongo-username')}
                    aria-describedby={fieldIsInvalid('mongo-username') ? 'connection-error' : undefined}
                    disabled={submitting}
                  />
                </label>
                <label className="field" htmlFor="mongo-password">
                  <span>Password (optional)</span>
                  <input
                    id="mongo-password"
                    type="password"
                    value={mongoPassword}
                    onChange={(event) => setMongoPassword(event.target.value)}
                    autoComplete="new-password"
                    disabled={submitting}
                  />
                </label>
                <label className="check-field compact-check-field" htmlFor="mongo-tls">
                  <input
                    id="mongo-tls"
                    type="checkbox"
                    checked={mongoTls}
                    onChange={(event) => setMongoTls(event.target.checked)}
                    disabled={submitting}
                  />
                  <span>
                    <strong>Require TLS</strong>
                    <small>Encrypt traffic to the MongoDB server.</small>
                  </span>
                </label>
              </>
            ) : (
              <>
                <label className="field field-wide" htmlFor="sqlite-file-path">
                  <span>Database file</span>
                  <input
                    id="sqlite-file-path"
                    value={sqliteFilePath}
                    onChange={(event) => setSqliteFilePath(event.target.value)}
                    placeholder="/path/to/database.sqlite"
                    autoComplete="off"
                    spellCheck={false}
                    aria-invalid={fieldIsInvalid('sqlite-file-path')}
                    aria-describedby={fieldIsInvalid('sqlite-file-path') ? 'connection-error' : undefined}
                    disabled={submitting}
                  />
                </label>
              </>
            )}

            <label className="field" htmlFor="connection-environment">
              <span>Environment</span>
              <select
                id="connection-environment"
                value={environment}
                onChange={(event) => setEnvironment(event.target.value as ConnectionEnvironment)}
                disabled={submitting}
              >
                <option value="development">Development</option>
                <option value="staging">Staging</option>
                <option value="production">Production</option>
              </select>
            </label>
          </div>

          <label className="check-field" htmlFor="connection-read-only">
            <input
              id="connection-read-only"
              type="checkbox"
              checked={readOnly}
              onChange={(event) => setReadOnly(event.target.checked)}
              disabled={submitting}
            />
            <span>
              <strong>Read-only guardrail</strong>
              <small>Keep write actions hidden and reject writes for this profile.</small>
            </span>
          </label>

          <label className="check-field" htmlFor="connection-remember">
            <input
              id="connection-remember"
              type="checkbox"
              checked={remember}
              onChange={(event) => setRemember(event.target.checked)}
              aria-label="Remember and reconnect"
              disabled={submitting}
            />
            <span>
              <strong>Remember and reconnect</strong>
              <small>
                Save the complete connection only when protected OS credential storage is available.
              </small>
            </span>
          </label>

          <div aria-live="polite">
            {credentialNotice && engine === 'mongodb' && (
              <div className="check-field" role="status">
                <ShieldCheck size={16} aria-hidden="true" />
                <span>
                  <strong>Credentials moved out of the URI</strong>
                  <small>The password is handled only by the isolated main process.</small>
                </span>
              </div>
            )}
            {transportWarning && (
              <div className="check-field" role="note">
                <ShieldAlert size={16} aria-hidden="true" />
                <span>
                  <strong>Review transport security</strong>
                  <small>{transportWarning}</small>
                </span>
              </div>
            )}
            {environment === 'production' && !readOnly && (
              <div className="check-field" role="note">
                <ShieldAlert size={16} aria-hidden="true" />
                <span>
                  <strong>Production writes are enabled</strong>
                  <small>Enable the read-only guardrail unless writes are intentional.</small>
                </span>
              </div>
            )}
          </div>

          {error && (
            <div
              ref={errorRef}
              id="connection-error"
              className="form-error"
              role="alert"
              tabIndex={-1}
            >
              {error.message}
            </div>
          )}

          <footer className="dialog-footer">
            <span id="credential-storage-note">
              {remember
                ? 'If secure storage is unavailable, dbbbb connects without saving credentials.'
                : 'Passwords are used for this session only and are never saved.'}
            </span>
            <div>
              <button
                className="secondary-button"
                type="button"
                onClick={closeDialog}
                disabled={submitting}
              >
                Cancel
              </button>
              <button className="primary-button" type="submit" disabled={submitting}>
                {submitting ? 'Connecting…' : 'Connect'}
              </button>
            </div>
          </footer>
        </form>
      </section>
    </div>
  )
}
