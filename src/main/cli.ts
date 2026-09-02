import type { ConnectionInput, DatabaseEngine } from '../shared/database'

export type CliAction =
  | { kind: 'open'; connection?: string }
  | { kind: 'query'; connection: string; command: string }
  | { kind: 'add'; input: ConnectionInput }
  | { kind: 'help' }

export type CliParseResult = { action: CliAction } | { error: string }

export const CLI_USAGE = `Usage: dbbbb [command]

Commands:
  open [connection]            Open the window and select a connection (id or name)
  query <connection> "<cmd>"   Select a connection, fill the editor, and run the command
  add --engine <engine> ...    Connect to a database and remember the connection
  --help                       Show this help

add options:
  --engine postgres|mysql      Requires --host and --database
                               [--port P] [--user U] [--password W]
  --engine mongodb             Requires --uri mongodb://host[:port]/<database>
  --engine sqlite              Requires --file /path/to.db
  common: [--name N] [--read-only]

Default ports: postgres 5432, mysql 3306.`

const DEFAULT_PORT: Record<'postgresql' | 'mysql', number> = {
  postgresql: 5432,
  mysql: 3306
}

const DEFAULT_USERNAME: Record<'postgresql' | 'mysql', string> = {
  postgresql: 'postgres',
  mysql: 'root'
}

const MONGO_URI_PATTERN = /^mongodb(?:\+srv)?:\/\/[^/?#]+/i

function errorResult(message: string): CliParseResult {
  return { error: message }
}

/** Parse the user arguments that follow the executable (and, in dev, the app path). */
export function parseCliArgs(args: string[]): CliParseResult | undefined {
  if (args.length === 0) return undefined
  const [command, ...rest] = args
  if (command === '--help' || command === '-h') return { action: { kind: 'help' } }
  if (command === 'open') {
    if (rest.length > 1) return errorResult('open accepts at most one connection argument.')
    return { action: { kind: 'open', connection: rest[0] } }
  }
  if (command === 'query') {
    if (rest.length !== 2) {
      return errorResult('query expects a connection and a command: dbbbb query <connection> "<command>"')
    }
    if (!rest[0]) return errorResult('query expects a connection id or name.')
    if (!rest[1]) return errorResult('query expects a non-empty command text.')
    return { action: { kind: 'query', connection: rest[0], command: rest[1] } }
  }
  if (command === 'add') return parseAddArgs(rest)
  return errorResult(`Unknown command "${command}". Run dbbbb --help for usage.`)
}

interface AddFlags {
  values: Map<string, string>
  readOnly: boolean
}

function collectAddFlags(args: string[]): AddFlags | { error: string } {
  const values = new Map<string, string>()
  let readOnly = false
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index]
    if (token === '--read-only') {
      readOnly = true
      continue
    }
    if (!token.startsWith('--')) return { error: `Unexpected argument "${token}" for add.` }
    const value = args[index + 1]
    if (value === undefined || value.startsWith('--')) {
      return { error: `Flag ${token} expects a value.` }
    }
    if (values.has(token)) return { error: `Flag ${token} was given twice.` }
    values.set(token, value)
    index += 1
  }
  return { values, readOnly }
}

function fileBaseName(filePath: string): string {
  return filePath.split(/[\\/]/).filter(Boolean).pop() ?? filePath
}

function mongoHostPort(uri: string): string {
  const authority = uri.replace(/^mongodb(?:\+srv)?:\/\//i, '').split(/[/?#]/)[0]
  const credentialSeparator = authority.lastIndexOf('@')
  return credentialSeparator >= 0 ? authority.slice(credentialSeparator + 1) : authority
}

function mongoDatabase(uri: string): string {
  const afterAuthority = uri.replace(/^mongodb(?:\+srv)?:\/\/[^/?#]+/i, '')
  const path = afterAuthority.split(/[?#]/)[0].replace(/^\//, '')
  return decodeURIComponent(path)
}

function parseAddArgs(args: string[]): CliParseResult {
  const collected = collectAddFlags(args)
  if ('error' in collected) return collected
  const { values, readOnly } = collected

  const engineFlag = values.get('--engine')
  if (!engineFlag) return errorResult('add requires --engine postgres|mysql|mongodb|sqlite.')
  const engine: DatabaseEngine | undefined =
    engineFlag === 'postgres'
      ? 'postgresql'
      : engineFlag === 'mysql' || engineFlag === 'mongodb' || engineFlag === 'sqlite'
        ? engineFlag
        : undefined
  if (!engine) return errorResult(`Unknown engine "${engineFlag}".`)

  const allowed =
    engine === 'postgresql' || engine === 'mysql'
      ? ['--engine', '--host', '--port', '--database', '--user', '--password', '--name']
      : engine === 'mongodb'
        ? ['--engine', '--uri', '--name']
        : ['--engine', '--file', '--name']
  for (const flag of values.keys()) {
    if (!allowed.includes(flag)) return errorResult(`Flag ${flag} does not apply to --engine ${engineFlag}.`)
  }

  const shared = {
    environment: 'development' as const,
    readOnly,
    remember: true as const
  }

  if (engine === 'postgresql' || engine === 'mysql') {
    const host = values.get('--host')?.trim()
    const database = values.get('--database')?.trim()
    if (!host) return errorResult(`add --engine ${engineFlag} requires --host.`)
    if (!database) return errorResult(`add --engine ${engineFlag} requires --database.`)
    const portText = values.get('--port')
    const port = portText === undefined ? DEFAULT_PORT[engine] : Number(portText)
    if (!Number.isInteger(port) || port < 1 || port > 65_535) {
      return errorResult(`Invalid --port "${portText}". Use an integer from 1 to 65535.`)
    }
    const input: ConnectionInput = {
      engine,
      name: values.get('--name')?.trim() || `${host}:${port}/${database}`,
      host,
      port,
      database,
      username: values.get('--user') ?? DEFAULT_USERNAME[engine],
      password: values.get('--password') ?? '',
      sslMode: 'disable',
      ...shared
    }
    return { action: { kind: 'add', input } }
  }

  if (engine === 'mongodb') {
    const uri = values.get('--uri')?.trim()
    if (!uri) return errorResult('add --engine mongodb requires --uri.')
    if (!MONGO_URI_PATTERN.test(uri)) {
      return errorResult('The MongoDB URI must begin with mongodb:// or mongodb+srv://.')
    }
    const database = mongoDatabase(uri)
    if (!database) {
      return errorResult('The MongoDB URI must include a database, e.g. mongodb://localhost:27017/mydb.')
    }
    const input: ConnectionInput = {
      engine: 'mongodb',
      name: values.get('--name')?.trim() || `${mongoHostPort(uri)}/${database}`,
      uri,
      database,
      // SRV URIs require TLS, matching the connection dialog default.
      tls: /^mongodb\+srv:\/\//i.test(uri),
      ...shared
    }
    return { action: { kind: 'add', input } }
  }

  const filePath = values.get('--file')?.trim()
  if (!filePath) return errorResult('add --engine sqlite requires --file.')
  const baseName = fileBaseName(filePath)
  const input: ConnectionInput = {
    engine: 'sqlite',
    name: values.get('--name')?.trim() || baseName,
    database: baseName,
    filePath,
    ...shared
  }
  return { action: { kind: 'add', input } }
}
