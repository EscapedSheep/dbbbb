/**
 * New-engine onboarding checklist: adding a DatabaseEngine also requires
 * coordinated changes in
 * - src/shared/database.ts: the DatabaseEngine union, the DatabaseCommand /
 *   DatabaseResult variants, and DEFAULT_QUERY
 * - src/main/database-ipc.ts: the IPC request/response parsers
 * - src/main/database-service.ts: the adapter factory
 * - the demo adapter for offline/demo profiles
 */
import type {
  ApplyDataChangeResult,
  ConnectionProfile,
  DataChangeAction,
  DataRecord,
  DatabaseCommand,
  DatabaseEngine,
  DatabaseObjectNode,
  DatabaseResult
} from '../../shared/database'
import type { ByteSource } from '../transfers/delimited'
import type { ImportProgress } from '../transfers/import-runner'

export interface ExecuteOptions {
  requestId: string
  timeoutMs: number
  maxRows: number
  maxBytes: number
}

export interface ImportDataOptions {
  format: 'csv' | 'jsonl'
  hasHeader: boolean
  signal?: AbortSignal
  onProgress?: (progress: ImportProgress) => void | Promise<void>
}

export interface ImportDataSummary {
  processed: number
  inserted: number
  failed: number
}

export interface AdapterDataChange {
  action: DataChangeAction
  original: DataRecord
  current?: DataRecord
}

export interface DatabaseAdapter {
  readonly engine: DatabaseEngine
  listObjects(profile: ConnectionProfile): Promise<DatabaseObjectNode[]>
  previewObject(profile: ConnectionProfile, objectId: string): Promise<DatabaseCommand>
  execute(
    profile: ConnectionProfile,
    command: DatabaseCommand,
    options: ExecuteOptions
  ): Promise<DatabaseResult>
  cancel(requestId: string): Promise<void>
  applyDataChange?(
    profile: ConnectionProfile,
    objectId: string,
    change: AdapterDataChange
  ): Promise<ApplyDataChangeResult>
  importData?(
    profile: ConnectionProfile,
    objectId: string,
    source: ByteSource,
    options: ImportDataOptions
  ): Promise<ImportDataSummary>
  close(): Promise<void>
}
