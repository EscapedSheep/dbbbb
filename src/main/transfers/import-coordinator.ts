import { randomUUID } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import { basename } from 'node:path'
import { dialog, type BrowserWindow } from 'electron'
import type {
  ChooseImportFileRequest,
  ImportFileSelection,
  ImportFormat,
  ImportProgressUpdate,
  ImportResult,
  StartImportRequest
} from '../../shared/database'
import type { DatabaseService } from '../database-service'
import type { ImportProgress } from './import-runner'

const SELECTION_TTL_MS = 10 * 60 * 1000
const MAX_FILE_BYTES = 1024 * 1024 * 1024
const MAX_SELECTIONS = 20
const PROGRESS_INTERVAL_MS = 75

export type ImportProgressPublisher = (
  update: ImportProgressUpdate
) => void | Promise<void>

interface PendingImport {
  token: string
  connectionId: string
  objectId: string
  format: ImportFormat
  path: string
  name: string
  size: number
  modifiedAtMs: number
  createdAtMs: number
  publishProgress?: ImportProgressPublisher
  latestProgress: Required<ImportProgress>
  lastProgressSentAtMs?: number
  controller?: AbortController
}

function safeImportError(error: unknown): Error {
  if (error instanceof Error) {
    if (error.name === 'AbortError' || /\babort(?:ed)?\b|cancelled/i.test(error.message)) {
      return new Error('Import was cancelled.')
    }
    if (/ENOENT|no such file/i.test(error.message)) {
      return new Error('The selected import file is no longer available.')
    }
    if (/EACCES|EPERM|permission/i.test(error.message)) {
      return new Error('The selected import file cannot be read. Check its permissions.')
    }
    return new Error(
      error.message
        .replace(/[a-zA-Z]:(?:\\[\w .@+-]+)+/g, '[local file]')
        .replace(/(?:\\[\w .@+-]+){2,}/g, '[local file]')
        .replace(/(?:\/[\w .@+-]+){2,}/g, '[local file]')
        .slice(0, 600)
    )
  }
  return new Error('Import failed.')
}

export class ImportCoordinator {
  private readonly pending = new Map<string, PendingImport>()

  constructor(private readonly service: DatabaseService) {}

  async chooseFile(
    window: BrowserWindow,
    request: ChooseImportFileRequest,
    publishProgress?: ImportProgressPublisher
  ): Promise<ImportFileSelection | undefined> {
    this.cleanupExpired()
    const target = await this.service.inspectImportTarget(request.connectionId, request.objectId)
    const validTarget =
      (target.profile.engine === 'postgresql' && target.object.kind === 'table' && request.format === 'csv') ||
      (target.profile.engine === 'mongodb' && target.object.kind === 'collection' && request.format === 'jsonl')
    if (!validTarget) {
      throw new Error('The selected file format does not match this import target.')
    }

    const selection = await dialog.showOpenDialog(window, {
      title: request.format === 'csv' ? 'Choose CSV to import' : 'Choose JSON Lines to import',
      properties: ['openFile'],
      filters:
        request.format === 'csv'
          ? [{ name: 'CSV', extensions: ['csv'] }]
          : [{ name: 'JSON Lines', extensions: ['jsonl', 'ndjson'] }]
    })
    if (selection.canceled || selection.filePaths.length !== 1) return undefined

    const path = selection.filePaths[0]
    let fileStats
    try {
      fileStats = await stat(path)
    } catch (error) {
      throw safeImportError(error)
    }
    if (!fileStats.isFile() || fileStats.size < 1) {
      throw new Error('Choose a non-empty regular file to import.')
    }
    if (fileStats.size > MAX_FILE_BYTES) {
      throw new Error('Import files are limited to 1 GB in this build.')
    }

    // Evict only idle selections; a running import is never aborted to make room.
    while (this.pending.size >= MAX_SELECTIONS) {
      const oldest = [...this.pending.values()]
        .filter((item) => !item.controller)
        .sort((left, right) => left.createdAtMs - right.createdAtMs)[0]
      if (!oldest) {
        throw new Error('Too many imports are running. Wait for one to finish before choosing another file.')
      }
      this.pending.delete(oldest.token)
    }

    const token = randomUUID()
    const pending: PendingImport = {
      token,
      connectionId: request.connectionId,
      objectId: request.objectId,
      format: request.format,
      path,
      name: basename(path),
      size: fileStats.size,
      modifiedAtMs: fileStats.mtimeMs,
      createdAtMs: Date.now(),
      publishProgress,
      latestProgress: { processed: 0, inserted: 0, failed: 0, bytes: 0 }
    }
    this.pending.set(token, pending)
    return { token, name: pending.name, size: pending.size }
  }

  async start(request: StartImportRequest): Promise<ImportResult> {
    this.cleanupExpired()
    const pending = this.pending.get(request.token)
    if (!pending) throw new Error('The import selection expired. Choose the file again.')
    if (pending.controller) throw new Error('This import is already running.')

    // Claim the single-use token before the first await. Otherwise two start calls can
    // both pass the running check while the file metadata is being revalidated.
    const controller = new AbortController()
    pending.controller = controller

    try {
      const currentStats = await stat(pending.path)
      if (controller.signal.aborted) {
        const error = new Error('Import was aborted.')
        error.name = 'AbortError'
        throw error
      }
      if (
        !currentStats.isFile() ||
        currentStats.size !== pending.size ||
        currentStats.mtimeMs !== pending.modifiedAtMs
      ) {
        throw new Error('The selected file changed after review. Choose it again before importing.')
      }

      this.reportProgress(pending, pending.latestProgress, true)

      const summary = await this.service.importData(
        pending.connectionId,
        pending.objectId,
        createReadStream(pending.path, { highWaterMark: 64 * 1024 }),
        {
          format: pending.format,
          hasHeader: request.hasHeader,
          signal: controller.signal,
          onProgress: (progress) => this.reportProgress(pending, progress)
        }
      )
      this.reportProgress(pending, {
        ...summary,
        bytes: pending.size
      }, true)
      return summary
    } catch (error) {
      if (!controller.signal.aborted) {
        this.reportProgress(pending, pending.latestProgress, true)
      }
      throw safeImportError(error)
    } finally {
      this.pending.delete(request.token)
    }
  }

  cancel(token: string): void {
    const pending = this.pending.get(token)
    if (!pending) return
    if (pending.controller) pending.controller.abort()
    else this.pending.delete(token)
  }

  close(): void {
    for (const item of this.pending.values()) item.controller?.abort()
    this.pending.clear()
  }

  private cleanupExpired(): void {
    const cutoff = Date.now() - SELECTION_TTL_MS
    for (const item of this.pending.values()) {
      if (item.createdAtMs < cutoff && !item.controller) this.pending.delete(item.token)
    }
  }

  private reportProgress(
    pending: PendingImport,
    progress: ImportProgress,
    force = false
  ): void {
    if (this.pending.get(pending.token) !== pending || pending.controller?.signal.aborted) return
    const bytes = progress.bytes ?? 0
    const values = [progress.processed, progress.inserted, progress.failed, bytes]
    if (values.some((value) => !Number.isSafeInteger(value) || value < 0)) return

    pending.latestProgress = {
      processed: progress.processed,
      inserted: progress.inserted,
      failed: progress.failed,
      bytes: Math.min(bytes, pending.size)
    }

    const now = Date.now()
    if (
      !force &&
      pending.lastProgressSentAtMs !== undefined &&
      now - pending.lastProgressSentAtMs < PROGRESS_INTERVAL_MS
    ) {
      return
    }
    pending.lastProgressSentAtMs = now

    try {
      const result = pending.publishProgress?.({
        token: pending.token,
        ...pending.latestProgress,
        totalBytes: pending.size
      })
      if (result) void Promise.resolve(result).catch(() => undefined)
    } catch {
      // Progress is best-effort and must never turn a successful database batch into a failure.
    }
  }
}
