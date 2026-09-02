// @vitest-environment node
import { Buffer } from 'node:buffer'
import { Writable } from 'node:stream'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { BrowserWindow } from 'electron'
import type { DocumentResult, RowResult } from '../../shared/database'

const systemMocks = vi.hoisted(() => ({
  randomUUID: vi.fn(),
  createWriteStream: vi.fn(),
  rename: vi.fn(),
  unlink: vi.fn(),
  showSaveDialog: vi.fn()
}))

vi.mock('node:crypto', () => ({ randomUUID: systemMocks.randomUUID }))
vi.mock('node:fs', () => ({ createWriteStream: systemMocks.createWriteStream }))
vi.mock('node:fs/promises', () => ({
  rename: systemMocks.rename,
  unlink: systemMocks.unlink
}))
vi.mock('electron', () => ({ dialog: { showSaveDialog: systemMocks.showSaveDialog } }))

import {
  parseExportResultRequest,
  showResultExportDialog
} from './result-export-service'

const FINAL_PATH = '/exports/report.csv'
const TEMPORARY_PATH = '/exports/.report.csv.test-export-uuid.dbbbb-export'
const windowStub = {} as BrowserWindow

let writtenChunks: Buffer[] = []

function rowResult(rows: RowResult['rows']): RowResult {
  return {
    kind: 'rows',
    columns: [
      { key: 'id', label: 'ID', dataType: 'int4' },
      { key: 'name', label: 'Name', dataType: 'text' }
    ],
    rows,
    meta: { elapsedMs: 1, count: rows.length, truncated: false, source: 'database' }
  }
}

function documentResult(documents: DocumentResult['documents']): DocumentResult {
  return {
    kind: 'documents',
    documents,
    meta: {
      elapsedMs: 1,
      count: documents.length,
      truncated: false,
      source: 'database'
    }
  }
}

function errnoError(code: string): Error {
  const error = new Error(`${code}: simulated filesystem failure`)
  ;(error as NodeJS.ErrnoException).code = code
  return error
}

beforeEach(() => {
  writtenChunks = []
  systemMocks.randomUUID.mockReset().mockReturnValue('test-export-uuid')
  systemMocks.createWriteStream.mockReset().mockImplementation(
    () => new Writable({
      write(chunk: Buffer, _encoding, callback) {
        writtenChunks.push(Buffer.from(chunk))
        callback()
      }
    })
  )
  systemMocks.rename.mockReset().mockResolvedValue(undefined)
  systemMocks.unlink.mockReset().mockResolvedValue(undefined)
  systemMocks.showSaveDialog.mockReset().mockResolvedValue({
    canceled: false,
    filePath: FINAL_PATH
  })
})

describe('parseExportResultRequest validation', () => {
  it.each([
    ['a non-object request', null],
    ['a missing result', { suggestedBaseName: 'report' }],
    ['an unknown result kind', { result: { kind: 'blob' }, suggestedBaseName: 'report' }],
    [
      'a row misaligned with its columns',
      { result: rowResult([[1]]), suggestedBaseName: 'report' }
    ],
    [
      'a document list containing an array',
      { result: documentResult([[1]] as never), suggestedBaseName: 'report' }
    ],
    [
      'more rows than the export item cap',
      {
        result: rowResult(Array.from({ length: 1_001 }, () => [1, 'x'])),
        suggestedBaseName: 'report'
      }
    ],
    ['an empty suggested name', { result: rowResult([]), suggestedBaseName: '' }],
    [
      'an overlong suggested name',
      { result: rowResult([]), suggestedBaseName: 'a'.repeat(241) }
    ]
  ])('rejects %s', (_label, request) => {
    expect(() => parseExportResultRequest(request)).toThrow(/invalid or too large/i)
    expect(systemMocks.showSaveDialog).not.toHaveBeenCalled()
  })

  it('rejects a serialized payload above the byte cap', () => {
    const oversized = documentResult([{ data: 'x'.repeat(13 * 1024 * 1024) }])

    expect(() => parseExportResultRequest({
      result: oversized,
      suggestedBaseName: 'report'
    })).toThrow(/invalid or too large/i)
  })

  it('sanitizes control characters, path separators, and leading dots from the base name', () => {
    const request = parseExportResultRequest({
      result: rowResult([]),
      suggestedBaseName: '../..\\report \u0007/final'
    })

    expect(request.suggestedBaseName).toBe('-..-report --final')
    expect(request.suggestedBaseName).not.toMatch(/[<>:"/\\|?*\x00-\x1f]/)
    expect(request.suggestedBaseName.startsWith('.')).toBe(false)
  })

  it('truncates long base names and falls back when nothing safe remains', () => {
    const long = parseExportResultRequest({
      result: rowResult([]),
      suggestedBaseName: 'a'.repeat(200)
    })
    expect(long.suggestedBaseName).toBe('a'.repeat(120))

    const empty = parseExportResultRequest({
      result: rowResult([]),
      suggestedBaseName: '...'
    })
    expect(empty.suggestedBaseName).toBe('dbbbb-export')
  })
})

describe('showResultExportDialog', () => {
  it('returns a cancelled response without touching the filesystem', async () => {
    systemMocks.showSaveDialog.mockResolvedValueOnce({ canceled: true, filePath: '' })

    await expect(showResultExportDialog(windowStub, {
      result: rowResult([[1, 'Ada']]),
      suggestedBaseName: 'report'
    })).resolves.toEqual({ canceled: true })
    expect(systemMocks.createWriteStream).not.toHaveBeenCalled()
    expect(systemMocks.rename).not.toHaveBeenCalled()
    expect(systemMocks.unlink).not.toHaveBeenCalled()
  })

  it('writes rows to a private temporary file and renames it into place', async () => {
    const response = await showResultExportDialog(windowStub, {
      result: rowResult([[1, 'Ada'], [2, 'Lin']]),
      suggestedBaseName: 'My Report'
    })

    expect(systemMocks.showSaveDialog).toHaveBeenCalledWith(
      windowStub,
      expect.objectContaining({
        title: 'Export result as CSV',
        defaultPath: 'My Report.csv',
        properties: expect.arrayContaining(['showOverwriteConfirmation'])
      })
    )
    expect(systemMocks.createWriteStream).toHaveBeenCalledWith(TEMPORARY_PATH, {
      flags: 'wx',
      mode: 0o600
    })
    expect(systemMocks.rename).toHaveBeenCalledWith(TEMPORARY_PATH, FINAL_PATH)
    const output = Buffer.concat(writtenChunks).toString('utf8')
    expect(output).toBe('ID,Name\r\n1,Ada\r\n2,Lin\r\n')
    expect(response).toEqual({ canceled: false, rows: 2, bytes: Buffer.byteLength(output) })
    expect(systemMocks.unlink).not.toHaveBeenCalled()
  })

  it('exports documents as JSON Lines with the matching dialog filters', async () => {
    systemMocks.showSaveDialog.mockResolvedValueOnce({
      canceled: false,
      filePath: '/exports/report.jsonl'
    })

    const response = await showResultExportDialog(windowStub, {
      result: documentResult([{ id: 1 }]),
      suggestedBaseName: 'report'
    })

    expect(systemMocks.showSaveDialog).toHaveBeenCalledWith(
      windowStub,
      expect.objectContaining({
        title: 'Export result as JSON Lines',
        defaultPath: 'report.jsonl'
      })
    )
    expect(Buffer.concat(writtenChunks).toString('utf8')).toBe('{"id":1}\n')
    expect(response).toMatchObject({ canceled: false, rows: 1 })
  })

  it('deletes the temporary file when the export itself fails', async () => {
    const failure = showResultExportDialog(windowStub, {
      result: rowResult([[1, undefined as never]]),
      suggestedBaseName: 'report'
    })

    await expect(failure).rejects.toMatchObject({ code: 'INVALID_RESULT' })
    expect(systemMocks.rename).not.toHaveBeenCalled()
    expect(systemMocks.unlink).toHaveBeenCalledWith(TEMPORARY_PATH)
  })

  it('does not retry or remove the target when rename fails for another reason', async () => {
    systemMocks.rename.mockRejectedValueOnce(errnoError('EACCES'))

    const failure = showResultExportDialog(windowStub, {
      result: rowResult([[1, 'Ada']]),
      suggestedBaseName: 'report'
    })

    await expect(failure).rejects.toMatchObject({ code: 'EACCES' })
    expect(systemMocks.rename).toHaveBeenCalledTimes(1)
    expect(systemMocks.unlink).toHaveBeenCalledWith(TEMPORARY_PATH)
    expect(systemMocks.unlink).not.toHaveBeenCalledWith(FINAL_PATH)
  })

  it.each(['EEXIST', 'EPERM'])(
    'removes the confirmed target and retries the rename after %s',
    async (code) => {
      systemMocks.rename
        .mockRejectedValueOnce(errnoError(code))
        .mockResolvedValueOnce(undefined)

      const response = await showResultExportDialog(windowStub, {
        result: rowResult([[1, 'Ada']]),
        suggestedBaseName: 'report'
      })

      expect(systemMocks.unlink).toHaveBeenCalledWith(FINAL_PATH)
      expect(systemMocks.rename).toHaveBeenCalledTimes(2)
      expect(systemMocks.rename).toHaveBeenNthCalledWith(2, TEMPORARY_PATH, FINAL_PATH)
      expect(systemMocks.unlink).not.toHaveBeenCalledWith(TEMPORARY_PATH)
      expect(response).toMatchObject({ canceled: false, rows: 1 })
    }
  )

  it('cleans up the temporary file when the overwrite retry also fails', async () => {
    systemMocks.rename
      .mockRejectedValueOnce(errnoError('EEXIST'))
      .mockRejectedValueOnce(errnoError('EEXIST'))

    const failure = showResultExportDialog(windowStub, {
      result: rowResult([[1, 'Ada']]),
      suggestedBaseName: 'report'
    })

    await expect(failure).rejects.toMatchObject({ code: 'EEXIST' })
    expect(systemMocks.unlink).toHaveBeenCalledWith(FINAL_PATH)
    expect(systemMocks.unlink).toHaveBeenCalledWith(TEMPORARY_PATH)
  })
})
