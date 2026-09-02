import type { ConnectionProfile } from '../../../shared/database'

export type ConnectionResolution =
  | { connection: ConnectionProfile }
  | { error: string }

/**
 * Resolve a CLI connection reference: an exact id match wins, otherwise the
 * name must match case-insensitively and unambiguously.
 */
export function resolveConnectionReference(
  connections: ConnectionProfile[],
  reference: string
): ConnectionResolution {
  const byId = connections.find((connection) => connection.id === reference)
  if (byId) return { connection: byId }
  const lowered = reference.toLowerCase()
  const byName = connections.filter((connection) => connection.name.toLowerCase() === lowered)
  if (byName.length === 1) return { connection: byName[0] }
  if (byName.length > 1) {
    const ids = byName.map((connection) => connection.id).join(', ')
    return {
      error: `Several connections are named "${reference}" (${ids}). Use the connection id instead.`
    }
  }
  return { error: `Connection "${reference}" was not found.` }
}
