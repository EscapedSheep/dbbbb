// @vitest-environment node
import { describe, expect, it } from 'vitest'
import type { ConnectionProfile } from '../../../shared/database'
import { resolveConnectionReference } from './connection-reference'

function profile(id: string, name: string): ConnectionProfile {
  return {
    id,
    name,
    engine: 'postgresql',
    endpoint: 'localhost:5432',
    database: 'db',
    environment: 'development',
    readOnly: false,
    demo: false
  }
}

const connections = [
  profile('orders-prod', 'Orders'),
  profile('orders-copy', 'orders'),
  profile('analytics', 'Analytics')
]

describe('resolveConnectionReference', () => {
  it('matches an exact id before any name', () => {
    expect(resolveConnectionReference(connections, 'analytics')).toEqual({
      connection: connections[2]
    })
  })

  it('matches a single name case-insensitively', () => {
    expect(resolveConnectionReference([connections[2]], 'ANALYTICS')).toEqual({
      connection: connections[2]
    })
  })

  it('reports ambiguous names with the matching ids', () => {
    expect(resolveConnectionReference(connections, 'Orders')).toEqual({
      error: 'Several connections are named "Orders" (orders-prod, orders-copy). Use the connection id instead.'
    })
  })

  it('reports an unknown reference', () => {
    expect(resolveConnectionReference(connections, 'missing')).toEqual({
      error: 'Connection "missing" was not found.'
    })
  })
})
