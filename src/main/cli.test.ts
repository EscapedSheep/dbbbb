// @vitest-environment node
import { describe, expect, it } from 'vitest'
import { parseCliArgs } from './cli'

describe('parseCliArgs', () => {
  it('returns undefined for a bare launch without arguments', () => {
    expect(parseCliArgs([])).toBeUndefined()
  })

  it.each([['--help'], ['-h']])('parses %s as the help action', (flag) => {
    expect(parseCliArgs([flag])).toEqual({ action: { kind: 'help' } })
  })

  it('parses open with and without a connection reference', () => {
    expect(parseCliArgs(['open'])).toEqual({ action: { kind: 'open', connection: undefined } })
    expect(parseCliArgs(['open', 'my-db'])).toEqual({
      action: { kind: 'open', connection: 'my-db' }
    })
  })

  it('rejects open with extra arguments', () => {
    expect(parseCliArgs(['open', 'a', 'b'])).toEqual({
      error: 'open accepts at most one connection argument.'
    })
  })

  it('parses query with a connection and command text', () => {
    expect(parseCliArgs(['query', 'mydb', 'select 1'])).toEqual({
      action: { kind: 'query', connection: 'mydb', command: 'select 1' }
    })
  })

  it.each([
    [['query']],
    [['query', 'mydb']],
    [['query', 'mydb', 'select 1', 'extra']]
  ])('rejects malformed query invocation %j', (args) => {
    expect(parseCliArgs(args)).toEqual({
      error: 'query expects a connection and a command: dbbbb query <connection> "<command>"'
    })
  })

  it.each([
    [['query', '', 'select 1']],
    [['query', 'mydb', '']]
  ])('rejects empty query operands %j', (args) => {
    expect(parseCliArgs(args)).toHaveProperty('error')
  })

  it('rejects an unknown command', () => {
    expect(parseCliArgs(['frobnicate'])).toEqual({
      error: 'Unknown command "frobnicate". Run dbbbb --help for usage.'
    })
  })
})

describe('parseCliArgs add', () => {
  it('builds a postgres input with the default port and username', () => {
    expect(parseCliArgs(['add', '--engine', 'postgres', '--host', 'db.internal', '--database', 'orders']))
      .toEqual({
        action: {
          kind: 'add',
          input: {
            engine: 'postgresql',
            name: 'db.internal:5432/orders',
            host: 'db.internal',
            port: 5432,
            database: 'orders',
            username: 'postgres',
            password: '',
            sslMode: 'disable',
            environment: 'development',
            readOnly: false,
            remember: true
          }
        }
      })
  })

  it('builds a mysql input honoring port, credentials, name, and read-only', () => {
    expect(
      parseCliArgs([
        'add', '--engine', 'mysql', '--host', '127.0.0.1', '--port', '3307',
        '--database', 'shop', '--user', 'maya', '--password', 's3cret',
        '--name', 'Shop replica', '--read-only'
      ])
    ).toEqual({
      action: {
        kind: 'add',
        input: {
          engine: 'mysql',
          name: 'Shop replica',
          host: '127.0.0.1',
          port: 3307,
          database: 'shop',
          username: 'maya',
          password: 's3cret',
          sslMode: 'disable',
          environment: 'development',
          readOnly: true,
          remember: true
        }
      }
    })
  })

  it('defaults the mysql port to 3306', () => {
    const result = parseCliArgs(['add', '--engine', 'mysql', '--host', 'h', '--database', 'd'])
    expect(result).toMatchObject({ action: { input: { port: 3306, username: 'root' } } })
  })

  it('builds a mongodb input from a standard URI without TLS', () => {
    expect(parseCliArgs(['add', '--engine', 'mongodb', '--uri', 'mongodb://mongo.internal:27017/catalog']))
      .toEqual({
        action: {
          kind: 'add',
          input: {
            engine: 'mongodb',
            name: 'mongo.internal:27017/catalog',
            uri: 'mongodb://mongo.internal:27017/catalog',
            database: 'catalog',
            tls: false,
            environment: 'development',
            readOnly: false,
            remember: true
          }
        }
      })
  })

  it('enables TLS for mongodb+srv URIs and strips credentials from the default name', () => {
    const result = parseCliArgs([
      'add', '--engine', 'mongodb', '--uri', 'mongodb+srv://user:pass@cluster0.example.net/app'
    ])
    expect(result).toEqual({
      action: {
        kind: 'add',
        input: expect.objectContaining({
          name: 'cluster0.example.net/app',
          database: 'app',
          tls: true
        })
      }
    })
  })

  it('builds a sqlite input with the file base name as database and name', () => {
    expect(parseCliArgs(['add', '--engine', 'sqlite', '--file', '/data/audit.db'])).toEqual({
      action: {
        kind: 'add',
        input: {
          engine: 'sqlite',
          name: 'audit.db',
          database: 'audit.db',
          filePath: '/data/audit.db',
          environment: 'development',
          readOnly: false,
          remember: true
        }
      }
    })
  })

  it.each([
    [['add'], 'add requires --engine postgres|mysql|mongodb|sqlite.'],
    [['add', '--engine', 'oracle'], 'Unknown engine "oracle".'],
    [['add', '--engine', 'postgres', '--database', 'd'], 'add --engine postgres requires --host.'],
    [['add', '--engine', 'postgres', '--host', 'h'], 'add --engine postgres requires --database.'],
    [
      ['add', '--engine', 'postgres', '--host', 'h', '--database', 'd', '--port', 'abc'],
      'Invalid --port "abc". Use an integer from 1 to 65535.'
    ],
    [
      ['add', '--engine', 'postgres', '--host', 'h', '--database', 'd', '--port', '0'],
      'Invalid --port "0". Use an integer from 1 to 65535.'
    ],
    [
      ['add', '--engine', 'postgres', '--host', 'h', '--database', 'd', '--port', '70000'],
      'Invalid --port "70000". Use an integer from 1 to 65535.'
    ],
    [['add', '--engine', 'mongodb'], 'add --engine mongodb requires --uri.'],
    [
      ['add', '--engine', 'mongodb', '--uri', 'http://example.net/db'],
      'The MongoDB URI must begin with mongodb:// or mongodb+srv://.'
    ],
    [
      ['add', '--engine', 'mongodb', '--uri', 'mongodb://localhost:27017'],
      'The MongoDB URI must include a database, e.g. mongodb://localhost:27017/mydb.'
    ],
    [
      ['add', '--engine', 'mongodb', '--uri', 'mongodb://localhost:27017/?replicaSet=rs0'],
      'The MongoDB URI must include a database, e.g. mongodb://localhost:27017/mydb.'
    ],
    [['add', '--engine', 'sqlite'], 'add --engine sqlite requires --file.'],
    [
      ['add', '--engine', 'sqlite', '--file', 'a.db', '--host', 'h'],
      'Flag --host does not apply to --engine sqlite.'
    ],
    [
      ['add', '--engine', 'mongodb', '--uri', 'mongodb://h/db', '--user', 'u'],
      'Flag --user does not apply to --engine mongodb.'
    ],
    [['add', 'positional'], 'Unexpected argument "positional" for add.'],
    [['add', '--engine'], 'Flag --engine expects a value.'],
    [
      ['add', '--engine', 'sqlite', '--file', 'a.db', '--file', 'b.db'],
      'Flag --file was given twice.'
    ]
  ])('rejects %j with a targeted error', (args, error) => {
    expect(parseCliArgs(args)).toEqual({ error })
  })

  it('rejects a flag value that starts with --', () => {
    expect(parseCliArgs(['add', '--engine', 'sqlite', '--file', '--name'])).toEqual({
      error: 'Flag --file expects a value.'
    })
  })
})
