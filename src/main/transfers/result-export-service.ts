import { randomUUID } from 'node:crypto'
import { createWriteStream } from 'node:fs'
import { rename, unlink } from 'node:fs/promises'
import { basename, dirname, join } from 'node:path'
import { dialog, type BrowserWindow } from 'electron'
import type {
  DatabaseResult,
  ExportResultRequest,
  ExportResultResponse
} from '../../shared/database'
import { exportResult } from './result-export'

const MAX_EXPORT_PAYLOAD_BYTES = 12 * 1024 * 1024
const MAX_EXPORT_ITEMS = 1_000
const MAX_EXPORT_COLUMNS = 2_000

function invalidExportRequest(): never {
  throw new Error('Export request is invalid or too large.')
}

function safeBaseName(value: string): string {
  const clean = value
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, '-')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^\.+/, '')
    .slice(0, 120)
  return clean || 'dbbbb-export'
}

/**
 * Renames the finished temporary file into place. Windows refuses to rename
 * over an existing target (EEXIST/EPERM), so the confirmed target is removed
 * first and the rename retried once.
 */
async function moveIntoPlace(temporaryPath: string, finalPath: string): Promise<void> {
  try {
    await rename(temporaryPath, finalPath)
  } catch (error) {
    const code = (error as NodeJS.ErrnoException | undefined)?.code
    if (code !== 'EEXIST' && code !== 'EPERM') throw error
    await unlink(finalPath)
    await rename(temporaryPath, finalPath)
  }
}

function validateResult(result: unknown): DatabaseResult {
  if (!result || typeof result !== 'object' || Array.isArray(result)) invalidExportRequest()
  const candidate = result as Partial<DatabaseResult>

  let serialized: string
  try {
    serialized = JSON.stringify(candidate)
  } catch {
    return invalidExportRequest()
  }
  if (Buffer.byteLength(serialized, 'utf8') > MAX_EXPORT_PAYLOAD_BYTES) invalidExportRequest()

  if (candidate.kind === 'rows') {
    if (
      !Array.isArray(candidate.columns) ||
      candidate.columns.length > MAX_EXPORT_COLUMNS ||
      !Array.isArray(candidate.rows) ||
      candidate.rows.length > MAX_EXPORT_ITEMS ||
      candidate.columns.some(
        (column) =>
          !column ||
          typeof column !== 'object' ||
          typeof column.label !== 'string' ||
          column.label.length > 512
      ) ||
      candidate.rows.some(
        (row) => !Array.isArray(row) || row.length !== candidate.columns!.length
      )
    ) {
      invalidExportRequest()
    }
    return candidate as DatabaseResult
  }

  if (candidate.kind === 'documents') {
    if (
      !Array.isArray(candidate.documents) ||
      candidate.documents.length > MAX_EXPORT_ITEMS ||
      candidate.documents.some(
        (document) => !document || typeof document !== 'object' || Array.isArray(document)
      )
    ) {
      invalidExportRequest()
    }
    return candidate as DatabaseResult
  }

  return invalidExportRequest()
}

export function parseExportResultRequest(value: unknown): ExportResultRequest {
  if (!value || typeof value !== 'object' || Array.isArray(value)) invalidExportRequest()
  const candidate = value as Partial<ExportResultRequest>
  if (
    typeof candidate.suggestedBaseName !== 'string' ||
    candidate.suggestedBaseName.length === 0 ||
    candidate.suggestedBaseName.length > 240
  ) {
    invalidExportRequest()
  }
  return {
    result: validateResult(candidate.result),
    suggestedBaseName: safeBaseName(candidate.suggestedBaseName)
  }
}

export async function showResultExportDialog(
  window: BrowserWindow,
  request: ExportResultRequest
): Promise<ExportResultResponse> {
  const relational = request.result.kind === 'rows'
  const extension = relational ? 'csv' : 'jsonl'
  const selection = await dialog.showSaveDialog(window, {
    title: relational ? 'Export result as CSV' : 'Export result as JSON Lines',
    defaultPath: `${safeBaseName(request.suggestedBaseName)}.${extension}`,
    filters: relational
      ? [{ name: 'CSV', extensions: ['csv'] }]
      : [{ name: 'JSON Lines', extensions: ['jsonl', 'ndjson'] }],
    properties: ['createDirectory', 'showOverwriteConfirmation']
  })
  if (selection.canceled || !selection.filePath) return { canceled: true }

  const finalPath = selection.filePath
  const temporaryPath = join(
    dirname(finalPath),
    `.${basename(finalPath)}.${randomUUID()}.dbbbb-export`
  )
  try {
    const summary = await exportResult(request.result, createWriteStream(temporaryPath, {
      flags: 'wx',
      mode: 0o600
    }))
    await moveIntoPlace(temporaryPath, finalPath)
    return { canceled: false, ...summary }
  } catch (error) {
    await unlink(temporaryPath).catch(() => undefined)
    throw error
  }
}
