import { Buffer } from 'node:buffer'
import {
  DelimitedStreamError,
  parseCsv,
  parseJsonLines
} from './delimited'
import type {
  ByteChunk,
  ByteSource,
  CsvParseOptions,
  JsonLinesOptions
} from './delimited'

export type ImportErrorMode = 'all-or-stop' | 'continue'
export type ImportErrorCode =
  | 'HEADER_INVALID'
  | 'COLUMN_COUNT'
  | 'DOCUMENT_TYPE'
  | 'INSERT_FAILED'
  | 'ROW_LIMIT'
  | 'PARSE_ERROR'

export interface ImportProgress {
  processed: number
  inserted: number
  failed: number
  bytes?: number
}

export interface ImportErrorSample {
  code: ImportErrorCode
  sourceNumber: number
  count: number
  message: string
}

export interface ImportSummary {
  progress: ImportProgress
  errorSamples: ImportErrorSample[]
}

export interface CsvImportSummary extends ImportSummary {
  columns: string[]
}

export interface InsertBatchContext {
  firstSourceNumber: number
  lastSourceNumber: number
  signal?: AbortSignal
}

export type InsertBatch<T> = (
  values: readonly T[],
  context: InsertBatchContext
) => Promise<number | void>

interface CommonImportOptions {
  batchSize?: number
  maxRows?: number
  maxErrorSamples?: number
  errorMode?: ImportErrorMode
  signal?: AbortSignal
  onProgress?: (progress: ImportProgress) => void | Promise<void>
}

export type CsvColumnIssueKind = 'dangerous' | 'unknown'

export interface CsvColumnIssue {
  kind: CsvColumnIssueKind
  column: string
  index: number
}

export type CsvColumnDecision =
  | { action: 'map'; column?: string }
  | { action: 'skip' }
  | { action: 'reject' }

export interface CsvImportOptions extends CommonImportOptions {
  insertRows: InsertBatch<Record<string, string>>
  parserOptions?: Omit<CsvParseOptions, 'signal'>
  /** Uses these columns without consuming the first CSV record as a header. */
  explicitHeader?: readonly string[]
  knownColumns?: Iterable<string>
  trimHeaders?: boolean
  strictColumnCount?: boolean
  isDangerousColumn?: (column: string, index: number) => boolean | Promise<boolean>
  onDangerousColumn?: (
    issue: CsvColumnIssue
  ) => CsvColumnDecision | Promise<CsvColumnDecision>
  onUnknownColumn?: (
    issue: CsvColumnIssue
  ) => CsvColumnDecision | Promise<CsvColumnDecision>
}

export interface JsonLinesImportOptions extends CommonImportOptions {
  insertDocuments: InsertBatch<Record<string, unknown>>
  parserOptions?: Omit<JsonLinesOptions, 'signal'>
}

export class ImportRunnerError extends Error {
  readonly code: ImportErrorCode
  readonly progress: ImportProgress
  readonly errorSamples: ImportErrorSample[]

  constructor(
    code: ImportErrorCode,
    message: string,
    progress: ImportProgress,
    errorSamples: ImportErrorSample[],
    cause?: unknown
  ) {
    super(message, cause === undefined ? undefined : { cause })
    this.name = 'ImportRunnerError'
    this.code = code
    this.progress = { ...progress }
    this.errorSamples = errorSamples.map((sample) => ({ ...sample }))
  }
}

interface ResolvedRunnerOptions {
  batchSize: number
  maxRows: number
  maxErrorSamples: number
  errorMode: ImportErrorMode
  signal?: AbortSignal
  onProgress?: (progress: ImportProgress) => void | Promise<void>
}

interface RunnerState {
  progress: Required<ImportProgress>
  errorSamples: ImportErrorSample[]
}

interface PendingValue<T> {
  sourceNumber: number
  value: T
}

interface CsvColumnMapping {
  sourceIndex: number
  target: string
}

const DANGEROUS_COLUMNS = new Set(['__proto__', 'prototype', 'constructor'])
const DEFAULT_BATCH_SIZE = 500
const DEFAULT_MAX_ROWS = 1_000_000
const DEFAULT_MAX_ERROR_SAMPLES = 20

function positiveInteger(value: number | undefined, fallback: number, name: string): number {
  const resolved = value ?? fallback
  if (!Number.isSafeInteger(resolved) || resolved < 1) {
    throw new TypeError(`${name} must be a positive safe integer.`)
  }
  return resolved
}

function nonNegativeInteger(value: number | undefined, fallback: number, name: string): number {
  const resolved = value ?? fallback
  if (!Number.isSafeInteger(resolved) || resolved < 0) {
    throw new TypeError(`${name} must be a non-negative safe integer.`)
  }
  return resolved
}

function resolveRunnerOptions(options: CommonImportOptions): ResolvedRunnerOptions {
  const errorMode = options.errorMode ?? 'all-or-stop'
  if (errorMode !== 'all-or-stop' && errorMode !== 'continue') {
    throw new TypeError('errorMode must be all-or-stop or continue.')
  }
  return {
    batchSize: positiveInteger(options.batchSize, DEFAULT_BATCH_SIZE, 'batchSize'),
    maxRows: positiveInteger(options.maxRows, DEFAULT_MAX_ROWS, 'maxRows'),
    maxErrorSamples: nonNegativeInteger(
      options.maxErrorSamples,
      DEFAULT_MAX_ERROR_SAMPLES,
      'maxErrorSamples'
    ),
    errorMode,
    signal: options.signal,
    onProgress: options.onProgress
  }
}

function abortReason(signal: AbortSignal): Error {
  if (signal.reason instanceof Error) return signal.reason
  const error = new Error('The import was aborted.')
  error.name = 'AbortError'
  return error
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw abortReason(signal)
}

function isAbort(error: unknown, signal?: AbortSignal): boolean {
  return Boolean(
    signal?.aborted ||
    (error instanceof Error && error.name === 'AbortError')
  )
}

function propagatedAbort(error: unknown, signal?: AbortSignal): Error {
  if (signal?.aborted) return abortReason(signal)
  if (error instanceof Error) return error
  const fallback = new Error('The import was aborted.')
  fallback.name = 'AbortError'
  return fallback
}

function createState(): RunnerState {
  return {
    progress: { processed: 0, inserted: 0, failed: 0, bytes: 0 },
    errorSamples: []
  }
}

function progressSnapshot(state: RunnerState): ImportProgress {
  return { ...state.progress }
}

async function reportProgress(
  state: RunnerState,
  options: ResolvedRunnerOptions
): Promise<void> {
  await options.onProgress?.(progressSnapshot(state))
}

function addErrorSample(
  state: RunnerState,
  options: ResolvedRunnerOptions,
  sample: ImportErrorSample
): void {
  if (state.errorSamples.length < options.maxErrorSamples) {
    state.errorSamples.push({ ...sample })
  }
}

function runnerError(
  code: ImportErrorCode,
  message: string,
  state: RunnerState,
  cause?: unknown
): ImportRunnerError {
  return new ImportRunnerError(
    code,
    message,
    progressSnapshot(state),
    state.errorSamples,
    cause
  )
}

async function* countedSource(source: ByteSource, state: RunnerState): AsyncGenerator<ByteChunk> {
  for await (const chunk of source) {
    state.progress.bytes += typeof chunk === 'string'
      ? Buffer.byteLength(chunk, 'utf8')
      : chunk.byteLength
    yield chunk
  }
}

/**
 * Reads the partial progress an insert callback reports on a thrown error.
 * The Mongo adapter attaches insertedCount to ordered-batch failures.
 */
function reportedInsertedCount(error: unknown, batchSize: number): number {
  if (!error || typeof error !== 'object') return 0
  const count = (error as { insertedCount?: unknown }).insertedCount
  if (typeof count !== 'number' || !Number.isSafeInteger(count) || count < 0 || count > batchSize) {
    return 0
  }
  return count
}

async function flushBatch<T>(
  batch: PendingValue<T>[],
  insert: InsertBatch<T>,
  state: RunnerState,
  options: ResolvedRunnerOptions
): Promise<void> {
  if (batch.length === 0) return
  throwIfAborted(options.signal)

  const pending = batch.splice(0, batch.length)
  const firstSourceNumber = pending[0].sourceNumber
  const lastSourceNumber = pending[pending.length - 1].sourceNumber
  let inserted: number

  try {
    const result = await insert(
      pending.map((item) => item.value),
      { firstSourceNumber, lastSourceNumber, signal: options.signal }
    )
    inserted = result === undefined ? pending.length : result
    if (!Number.isSafeInteger(inserted) || inserted < 0 || inserted > pending.length) {
      throw new TypeError('Insert callback returned an invalid inserted row count.')
    }
  } catch (error) {
    // Credit whatever the callback actually inserted so the summary matches the server.
    const reported = reportedInsertedCount(error, pending.length)
    state.progress.inserted += reported
    if (isAbort(error, options.signal)) {
      await reportProgress(state, options)
      throw propagatedAbort(error, options.signal)
    }
    const failed = pending.length - reported
    state.progress.failed += failed
    addErrorSample(state, options, {
      code: 'INSERT_FAILED',
      sourceNumber: firstSourceNumber,
      count: failed,
      message: 'A batch could not be inserted.'
    })
    await reportProgress(state, options)
    if (options.errorMode === 'all-or-stop') {
      throw runnerError(
        'INSERT_FAILED',
        'Import stopped because a batch could not be inserted.',
        state,
        error
      )
    }
    return
  }

  state.progress.inserted += inserted
  const failed = pending.length - inserted
  if (failed > 0) {
    state.progress.failed += failed
    addErrorSample(state, options, {
      code: 'INSERT_FAILED',
      sourceNumber: firstSourceNumber,
      count: failed,
      message: 'A batch was only partially inserted.'
    })
  }
  await reportProgress(state, options)

  // A cancellation that raced a completed batch still credits that batch first.
  throwIfAborted(options.signal)

  if (failed > 0 && options.errorMode === 'all-or-stop') {
    throw runnerError(
      'INSERT_FAILED',
      'Import stopped because a batch was only partially inserted.',
      state
    )
  }
}

async function failValue(
  code: Extract<ImportErrorCode, 'COLUMN_COUNT' | 'DOCUMENT_TYPE'>,
  sourceNumber: number,
  message: string,
  state: RunnerState,
  options: ResolvedRunnerOptions
): Promise<void> {
  state.progress.failed += 1
  addErrorSample(state, options, { code, sourceNumber, count: 1, message })
  await reportProgress(state, options)
  if (options.errorMode === 'all-or-stop') {
    throw runnerError(code, 'Import stopped because an input value was invalid.', state)
  }
}

async function parserFailure(
  error: unknown,
  fallbackSourceNumber: number,
  state: RunnerState,
  options: ResolvedRunnerOptions
): Promise<never> {
  if (error instanceof ImportRunnerError) throw error
  if (isAbort(error, options.signal)) throw propagatedAbort(error, options.signal)

  const sourceNumber = error instanceof DelimitedStreamError
    ? error.recordNumber ?? error.lineNumber ?? fallbackSourceNumber
    : fallbackSourceNumber
  if (
    error instanceof DelimitedStreamError &&
    (error.code === 'INVALID_CSV' || error.code === 'INVALID_JSONL')
  ) {
    state.progress.processed += 1
    state.progress.failed += 1
  }
  addErrorSample(state, options, {
    code: 'PARSE_ERROR',
    sourceNumber,
    count: 1,
    message: 'An input value could not be parsed.'
  })
  await reportProgress(state, options)
  throw runnerError('PARSE_ERROR', 'Import stopped because the input could not be parsed.', state, error)
}

function headerFailure(
  sourceIndex: number,
  message: string,
  state: RunnerState,
  options: ResolvedRunnerOptions,
  cause?: unknown
): never {
  addErrorSample(state, options, {
    code: 'HEADER_INVALID',
    sourceNumber: 1,
    count: 1,
    message: `CSV header column ${sourceIndex + 1} ${message}`
  })
  throw runnerError('HEADER_INVALID', 'CSV import stopped because its header is invalid.', state, cause)
}

async function validateCsvHeader(
  rawHeader: string[],
  csvOptions: CsvImportOptions,
  state: RunnerState,
  options: ResolvedRunnerOptions
): Promise<CsvColumnMapping[]> {
  const trim = csvOptions.trimHeaders ?? true
  const header = rawHeader.map((column) => trim ? column.trim() : column)
  const knownColumns = csvOptions.knownColumns
    ? new Set(csvOptions.knownColumns)
    : undefined
  const sourceNames = new Set<string>()
  const targetNames = new Set<string>()
  const mappings: CsvColumnMapping[] = []

  for (let index = 0; index < header.length; index += 1) {
    throwIfAborted(options.signal)
    const source = header[index]
    if (source.length === 0) headerFailure(index, 'is empty.', state, options)
    if (sourceNames.has(source)) {
      headerFailure(index, 'duplicates an earlier column.', state, options)
    }
    sourceNames.add(source)

    let dangerous: boolean
    try {
      dangerous = DANGEROUS_COLUMNS.has(source.toLowerCase()) ||
        Boolean(await csvOptions.isDangerousColumn?.(source, index))
    } catch (error) {
      if (isAbort(error, options.signal)) throw propagatedAbort(error, options.signal)
      headerFailure(index, 'could not be checked safely.', state, options, error)
    }

    const kind: CsvColumnIssueKind | undefined = dangerous
      ? 'dangerous'
      : knownColumns && !knownColumns.has(source)
        ? 'unknown'
        : undefined
    let target = source

    if (kind) {
      const callback = kind === 'dangerous'
        ? csvOptions.onDangerousColumn
        : csvOptions.onUnknownColumn
      if (!callback) headerFailure(index, `is ${kind}.`, state, options)

      let decision: CsvColumnDecision
      try {
        decision = await callback({ kind, column: source, index })
      } catch (error) {
        if (isAbort(error, options.signal)) throw propagatedAbort(error, options.signal)
        headerFailure(index, `could not resolve a ${kind} mapping.`, state, options, error)
      }
      if (!decision || decision.action === 'reject') {
        headerFailure(index, `was rejected as ${kind}.`, state, options)
      }
      if (decision.action === 'skip') continue
      target = (decision.column ?? source).trim()
    }

    if (target.length === 0) headerFailure(index, 'maps to an empty column.', state, options)
    if (DANGEROUS_COLUMNS.has(target.toLowerCase())) {
      headerFailure(index, 'maps to a dangerous object key.', state, options)
    }
    if (targetNames.has(target)) {
      headerFailure(index, 'maps to a duplicate target column.', state, options)
    }
    targetNames.add(target)
    mappings.push({ sourceIndex: index, target })
  }

  if (mappings.length === 0) headerFailure(0, 'does not map any importable columns.', state, options)
  return mappings
}

function csvRecord(row: string[], mappings: CsvColumnMapping[]): Record<string, string> {
  const record = Object.create(null) as Record<string, string>
  for (const mapping of mappings) {
    record[mapping.target] = row[mapping.sourceIndex] ?? ''
  }
  return record
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function hasDangerousObjectKey(document: Record<string, unknown>): boolean {
  const pending: unknown[] = [document]
  while (pending.length > 0) {
    const value = pending.pop()
    if (value === null || typeof value !== 'object') continue
    if (Array.isArray(value)) {
      pending.push(...value)
      continue
    }

    for (const [key, nestedValue] of Object.entries(value)) {
      if (DANGEROUS_COLUMNS.has(key.toLowerCase())) return true
      pending.push(nestedValue)
    }
  }
  return false
}

function checkRowLimit(
  sourceNumber: number,
  state: RunnerState,
  options: ResolvedRunnerOptions
): void {
  if (state.progress.processed < options.maxRows) return
  addErrorSample(state, options, {
    code: 'ROW_LIMIT',
    sourceNumber,
    count: 1,
    message: `The configured import row limit of ${options.maxRows} was exceeded.`
  })
  throw runnerError('ROW_LIMIT', 'Import stopped at its configured row limit.', state)
}

export async function runCsvImport(
  source: ByteSource,
  csvOptions: CsvImportOptions
): Promise<CsvImportSummary> {
  const options = resolveRunnerOptions(csvOptions)
  const state = createState()
  const parser = parseCsv(countedSource(source, state), {
    ...csvOptions.parserOptions,
    signal: options.signal
  })
  let sourceNumber = csvOptions.explicitHeader ? 0 : 1
  let columns: string[] = []
  const batch: PendingValue<Record<string, string>>[] = []

  try {
    throwIfAborted(options.signal)
    let header: string[]
    if (csvOptions.explicitHeader) {
      header = [...csvOptions.explicitHeader]
      if (header.length === 0) headerFailure(0, 'is missing.', state, options)
    } else {
      const parsedHeader = await parser.next()
      if (parsedHeader.done) headerFailure(0, 'is missing.', state, options)
      header = parsedHeader.value
    }
    const mappings = await validateCsvHeader(header, csvOptions, state, options)
    columns = mappings.map((mapping) => mapping.target)
    const strictColumnCount = csvOptions.strictColumnCount ?? true
    const expectedColumnCount = header.length

    for await (const row of parser) {
      sourceNumber += 1
      throwIfAborted(options.signal)
      checkRowLimit(sourceNumber, state, options)
      state.progress.processed += 1

      if (strictColumnCount && row.length !== expectedColumnCount) {
        await failValue(
          'COLUMN_COUNT',
          sourceNumber,
          `CSV record ${sourceNumber} has ${row.length} columns; ${expectedColumnCount} were expected.`,
          state,
          options
        )
        continue
      }

      batch.push({ sourceNumber, value: csvRecord(row, mappings) })
      if (batch.length >= options.batchSize) {
        await flushBatch(batch, csvOptions.insertRows, state, options)
      }
    }

    await flushBatch(batch, csvOptions.insertRows, state, options)
    await reportProgress(state, options)
    return {
      columns,
      progress: progressSnapshot(state),
      errorSamples: state.errorSamples.map((sample) => ({ ...sample }))
    }
  } catch (error) {
    return parserFailure(error, sourceNumber, state, options)
  }
}

export async function runJsonLinesImport(
  source: ByteSource,
  jsonOptions: JsonLinesImportOptions
): Promise<ImportSummary> {
  const options = resolveRunnerOptions(jsonOptions)
  const state = createState()
  const parser = parseJsonLines<unknown>(countedSource(source, state), {
    ...jsonOptions.parserOptions,
    signal: options.signal
  })
  let sourceNumber = 1
  const batch: PendingValue<Record<string, unknown>>[] = []

  try {
    for await (const item of parser) {
      sourceNumber = item.lineNumber
      throwIfAborted(options.signal)
      checkRowLimit(sourceNumber, state, options)
      state.progress.processed += 1

      if (!isPlainObject(item.value)) {
        await failValue(
          'DOCUMENT_TYPE',
          sourceNumber,
          `JSONL line ${sourceNumber} must contain one plain object.`,
          state,
          options
        )
        continue
      }

      if (hasDangerousObjectKey(item.value)) {
        await failValue(
          'DOCUMENT_TYPE',
          sourceNumber,
          `JSONL line ${sourceNumber} contains an unsafe object key.`,
          state,
          options
        )
        continue
      }

      batch.push({ sourceNumber, value: item.value })
      if (batch.length >= options.batchSize) {
        await flushBatch(batch, jsonOptions.insertDocuments, state, options)
      }
    }

    await flushBatch(batch, jsonOptions.insertDocuments, state, options)
    await reportProgress(state, options)
    return {
      progress: progressSnapshot(state),
      errorSamples: state.errorSamples.map((sample) => ({ ...sample }))
    }
  } catch (error) {
    return parserFailure(error, sourceNumber, state, options)
  }
}
