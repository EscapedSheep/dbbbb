import { Buffer } from 'node:buffer'
import { Readable, type Writable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import type {
  DatabaseResult,
  DocumentResult,
  RowResult,
  WireValue
} from '../../shared/database'
import {
  TransferLimitError,
  serializeCsv,
  type CsvCell
} from './delimited'

export interface ResultExportOptions {
  /** Maximum UTF-8 bytes written, including the CSV header and all line endings. */
  maxBytes?: number
  signal?: AbortSignal
}

export interface ResultExportSummary {
  /** Data rows or documents written. A CSV header is not counted. */
  rows: number
  bytes: number
}

export type ResultExportErrorCode =
  | 'ABORTED'
  | 'INVALID_OPTIONS'
  | 'INVALID_RESULT'
  | 'LIMIT_EXCEEDED'
  | 'WRITE_FAILED'

const DEFAULT_MAX_BYTES = 100 * 1024 * 1024
const MAX_CANONICAL_DEPTH = 100

export class ResultExportError extends Error {
  readonly code: ResultExportErrorCode
  readonly maximumBytes?: number

  constructor(code: ResultExportErrorCode, maximumBytes?: number) {
    const message = (() => {
      switch (code) {
        case 'ABORTED':
          return 'Result export was aborted.'
        case 'INVALID_OPTIONS':
          return 'Result export options are invalid.'
        case 'INVALID_RESULT':
          return 'Result export contains an unsupported value or shape.'
        case 'LIMIT_EXCEEDED':
          return 'Result export exceeded the configured byte limit.'
        case 'WRITE_FAILED':
          return 'Result export could not be written.'
      }
    })()
    super(message)
    this.name = 'ResultExportError'
    this.code = code
    this.maximumBytes = maximumBytes
  }
}

function resolvedMaxBytes(value: number | undefined): number {
  const maximum = value ?? DEFAULT_MAX_BYTES
  if (!Number.isSafeInteger(maximum) || maximum < 1) {
    throw new ResultExportError('INVALID_OPTIONS')
  }
  return maximum
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw new ResultExportError('ABORTED')
}

function invalidResult(): never {
  throw new ResultExportError('INVALID_RESULT')
}

function canonicalValue(
  value: unknown,
  ancestors: WeakSet<object>,
  depth: number
): string {
  if (value === null) return 'null'
  if (typeof value === 'string') return JSON.stringify(value)
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return invalidResult()
    return JSON.stringify(value)
  }

  if (typeof value !== 'object' || depth > MAX_CANONICAL_DEPTH) return invalidResult()
  if (ancestors.has(value)) return invalidResult()
  ancestors.add(value)

  try {
    if (Array.isArray(value)) {
      const items: string[] = []
      for (let index = 0; index < value.length; index += 1) {
        if (!Object.prototype.hasOwnProperty.call(value, index)) return invalidResult()
        items.push(canonicalValue(value[index], ancestors, depth + 1))
      }
      return `[${items.join(',')}]`
    }

    const prototype = Object.getPrototypeOf(value)
    if (prototype !== Object.prototype && prototype !== null) return invalidResult()

    const ownKeys = Reflect.ownKeys(value)
    if (ownKeys.some((key) => typeof key !== 'string')) return invalidResult()
    const keys = ownKeys as string[]
    const properties: string[] = []
    for (const key of keys.sort()) {
      const descriptor = Object.getOwnPropertyDescriptor(value, key)
      if (!descriptor?.enumerable || !('value' in descriptor)) return invalidResult()
      properties.push(
        `${JSON.stringify(key)}:${canonicalValue(descriptor.value, ancestors, depth + 1)}`
      )
    }
    return `{${properties.join(',')}}`
  } finally {
    ancestors.delete(value)
  }
}

/** Stable, compact JSON for already-normalized WireValue data. */
export function canonicalJson(value: WireValue | Record<string, WireValue>): string {
  try {
    return canonicalValue(value, new WeakSet<object>(), 0)
  } catch (error) {
    if (error instanceof ResultExportError) throw error
    throw new ResultExportError('INVALID_RESULT')
  }
}

function csvCell(value: unknown): CsvCell {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return invalidResult()
    return value
  }
  if (typeof value === 'object') return canonicalJson(value as WireValue)
  return invalidResult()
}

function assertRowResult(result: RowResult): void {
  if (!Array.isArray(result.columns) || !Array.isArray(result.rows)) invalidResult()
  for (const column of result.columns) {
    if (!column || typeof column.label !== 'string') invalidResult()
  }
}

async function* csvChunks(
  result: RowResult,
  summary: ResultExportSummary,
  maxBytes: number,
  signal?: AbortSignal
): AsyncGenerator<string> {
  assertRowResult(result)

  async function* rows(): AsyncGenerator<readonly CsvCell[]> {
    throwIfAborted(signal)
    yield result.columns.map((column) => column.label)

    for (const row of result.rows) {
      throwIfAborted(signal)
      if (!Array.isArray(row) || row.length !== result.columns.length) invalidResult()
      const cells: CsvCell[] = []
      for (let index = 0; index < row.length; index += 1) {
        const descriptor = Object.getOwnPropertyDescriptor(row, String(index))
        if (!descriptor?.enumerable || !('value' in descriptor)) invalidResult()
        cells.push(csvCell(descriptor.value))
      }
      yield cells
      summary.rows += 1
    }
  }

  for await (const chunk of serializeCsv(rows(), {
    maxFieldBytes: maxBytes,
    maxLineBytes: maxBytes,
    maxTotalBytes: maxBytes,
    signal
  })) {
    summary.bytes += Buffer.byteLength(chunk, 'utf8')
    yield chunk
  }
}

function assertDocumentResult(result: DocumentResult): void {
  if (!Array.isArray(result.documents)) invalidResult()
}

async function* jsonLinesChunks(
  result: DocumentResult,
  summary: ResultExportSummary,
  maxBytes: number,
  signal?: AbortSignal
): AsyncGenerator<string> {
  assertDocumentResult(result)

  for (const document of result.documents) {
    throwIfAborted(signal)
    if (document === null || typeof document !== 'object' || Array.isArray(document)) {
      invalidResult()
    }
    const line = `${canonicalJson(document)}\n`
    const lineBytes = Buffer.byteLength(line, 'utf8')
    if (summary.bytes + lineBytes > maxBytes) {
      throw new ResultExportError('LIMIT_EXCEEDED', maxBytes)
    }
    summary.bytes += lineBytes
    summary.rows += 1
    yield line
  }
}

function exportChunks(
  result: DatabaseResult,
  summary: ResultExportSummary,
  maxBytes: number,
  signal?: AbortSignal
): AsyncIterable<string> {
  if (result.kind === 'rows') return csvChunks(result, summary, maxBytes, signal)
  if (result.kind === 'documents') return jsonLinesChunks(result, summary, maxBytes, signal)
  return {
    async *[Symbol.asyncIterator](): AsyncGenerator<string> {
      invalidResult()
    }
  }
}

function safeExportError(error: unknown, signal?: AbortSignal): ResultExportError {
  if (signal?.aborted) return new ResultExportError('ABORTED')
  if (error instanceof ResultExportError) return error
  if (error instanceof TransferLimitError) {
    return new ResultExportError('LIMIT_EXCEEDED', error.maximumBytes)
  }
  if (error && typeof error === 'object' && (error as { name?: unknown }).name === 'AbortError') {
    return new ResultExportError('ABORTED')
  }
  return new ResultExportError('WRITE_FAILED')
}

/**
 * Streams a RowResult as CSV or a DocumentResult as canonical JSONL. The
 * destination is closed on success and destroyed by pipeline on failure.
 */
export async function exportResult(
  result: DatabaseResult,
  destination: Writable,
  options: ResultExportOptions = {}
): Promise<ResultExportSummary> {
  const maxBytes = resolvedMaxBytes(options.maxBytes)
  throwIfAborted(options.signal)
  const summary: ResultExportSummary = { rows: 0, bytes: 0 }

  try {
    const source = Readable.from(
      exportChunks(result, summary, maxBytes, options.signal),
      { encoding: 'utf8' }
    )
    if (options.signal) {
      await pipeline(source, destination, { signal: options.signal })
    } else {
      await pipeline(source, destination)
    }
    return { ...summary }
  } catch (error) {
    throw safeExportError(error, options.signal)
  }
}
