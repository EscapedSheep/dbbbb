import { Buffer } from 'node:buffer'
import { Readable, Writable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { StringDecoder } from 'node:string_decoder'

export type ByteChunk = Uint8Array | string
export type ByteSource = AsyncIterable<ByteChunk>
export type CsvCell = string | number | bigint | boolean | null | undefined
export type CsvRow = readonly CsvCell[]

export interface TransferLimits {
  /** Decoded bytes in one field. For JSONL, the complete JSON value is one field. */
  maxFieldBytes?: number
  /** Bytes in one logical CSV record or one JSONL line, including its line ending. */
  maxLineBytes?: number
  /** Raw bytes consumed from the input, or serialized bytes produced by the writer. */
  maxTotalBytes?: number
}

export interface CsvParseOptions extends TransferLimits {
  delimiter?: string
  signal?: AbortSignal
}

export interface CsvWriteOptions extends TransferLimits {
  delimiter?: string
  lineEnding?: '\n' | '\r\n'
  includeBom?: boolean
  signal?: AbortSignal
}

export interface JsonLinesOptions extends TransferLimits {
  signal?: AbortSignal
  skipEmptyLines?: boolean
}

export interface JsonLine<T> {
  lineNumber: number
  value: T
}

export type DelimitedErrorCode = 'INVALID_CSV' | 'INVALID_JSONL' | 'LIMIT_EXCEEDED'
export type TransferLimitName = 'field' | 'line' | 'total'

interface ErrorLocation {
  lineNumber?: number
  recordNumber?: number
}

interface ResolvedLimits {
  maxFieldBytes: number
  maxLineBytes: number
  maxTotalBytes: number
}

const DEFAULT_LIMITS: ResolvedLimits = {
  maxFieldBytes: 8 * 1024 * 1024,
  maxLineBytes: 32 * 1024 * 1024,
  maxTotalBytes: 1024 * 1024 * 1024
}

export class DelimitedStreamError extends Error {
  readonly code: DelimitedErrorCode
  readonly lineNumber?: number
  readonly recordNumber?: number

  constructor(
    code: DelimitedErrorCode,
    message: string,
    location: ErrorLocation = {},
    cause?: unknown
  ) {
    super(message, cause === undefined ? undefined : { cause })
    this.name = 'DelimitedStreamError'
    this.code = code
    this.lineNumber = location.lineNumber
    this.recordNumber = location.recordNumber
  }
}

export class TransferLimitError extends DelimitedStreamError {
  readonly limit: TransferLimitName
  readonly maximumBytes: number

  constructor(limit: TransferLimitName, maximumBytes: number, location: ErrorLocation = {}) {
    const suffix = location.lineNumber === undefined ? '' : ` at line ${location.lineNumber}`
    super(
      'LIMIT_EXCEEDED',
      `Delimited transfer ${limit} limit of ${maximumBytes} bytes was exceeded${suffix}.`,
      location
    )
    this.name = 'TransferLimitError'
    this.limit = limit
    this.maximumBytes = maximumBytes
  }
}

function positiveLimit(value: number | undefined, fallback: number, name: string): number {
  const resolved = value ?? fallback
  if (!Number.isSafeInteger(resolved) || resolved < 1) {
    throw new TypeError(`${name} must be a positive safe integer.`)
  }
  return resolved
}

function resolveLimits(options: TransferLimits): ResolvedLimits {
  return {
    maxFieldBytes: positiveLimit(
      options.maxFieldBytes,
      DEFAULT_LIMITS.maxFieldBytes,
      'maxFieldBytes'
    ),
    maxLineBytes: positiveLimit(
      options.maxLineBytes,
      DEFAULT_LIMITS.maxLineBytes,
      'maxLineBytes'
    ),
    maxTotalBytes: positiveLimit(
      options.maxTotalBytes,
      DEFAULT_LIMITS.maxTotalBytes,
      'maxTotalBytes'
    )
  }
}

function resolveDelimiter(delimiter = ','): string {
  if (
    Array.from(delimiter).length !== 1 ||
    delimiter === '"' ||
    delimiter === '\r' ||
    delimiter === '\n'
  ) {
    throw new TypeError('CSV delimiter must be one character other than a quote or newline.')
  }
  return delimiter
}

/** Exact UTF-8 length of one code point; avoids a Buffer.byteLength call per character. */
function utf8Bytes(character: string): number {
  const codePoint = character.codePointAt(0) ?? 0
  if (codePoint < 0x80) return 1
  if (codePoint < 0x800) return 2
  if (codePoint < 0x10000) return 3
  return 4
}

function abortReason(signal: AbortSignal): Error {
  if (signal.reason instanceof Error) return signal.reason
  const error = new Error('The delimited transfer was aborted.')
  error.name = 'AbortError'
  return error
}

function throwIfAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw abortReason(signal)
}

function waitWithAbort<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
  if (!signal) return promise
  throwIfAborted(signal)

  return new Promise<T>((resolve, reject) => {
    const onAbort = (): void => {
      signal.removeEventListener('abort', onAbort)
      reject(abortReason(signal))
    }
    signal.addEventListener('abort', onAbort, { once: true })

    promise.then(
      (value) => {
        signal.removeEventListener('abort', onAbort)
        resolve(value)
      },
      (error: unknown) => {
        signal.removeEventListener('abort', onAbort)
        reject(error)
      }
    )
  })
}

async function* abortable<T>(source: AsyncIterable<T>, signal?: AbortSignal): AsyncGenerator<T> {
  const iterator = source[Symbol.asyncIterator]()
  let completed = false

  try {
    while (true) {
      const next = await waitWithAbort(iterator.next(), signal)
      if (next.done) {
        completed = true
        return
      }
      yield next.value
    }
  } finally {
    if (!completed && iterator.return) {
      try {
        const cleanup = iterator.return()
        void Promise.resolve(cleanup).catch(() => undefined)
      } catch {
        // Cleanup is best-effort; preserve the parser or abort error.
      }
    }
  }
}

function asAsyncIterable<T>(source: Iterable<T> | AsyncIterable<T>): AsyncIterable<T> {
  if (Symbol.asyncIterator in source) return source as AsyncIterable<T>
  return {
    async *[Symbol.asyncIterator](): AsyncGenerator<T> {
      yield* source as Iterable<T>
    }
  }
}

async function* decodedChunks(
  source: ByteSource,
  limits: ResolvedLimits,
  signal: AbortSignal | undefined,
  location: () => ErrorLocation
): AsyncGenerator<string> {
  const decoder = new StringDecoder('utf8')
  let totalBytes = 0

  for await (const chunk of abortable(source, signal)) {
    throwIfAborted(signal)
    const bytes = typeof chunk === 'string' ? Buffer.from(chunk, 'utf8') : Buffer.from(chunk)
    totalBytes += bytes.byteLength
    if (totalBytes > limits.maxTotalBytes) {
      throw new TransferLimitError('total', limits.maxTotalBytes, location())
    }
    const decoded = decoder.write(bytes)
    if (decoded.length > 0) yield decoded
  }

  throwIfAborted(signal)
  const trailing = decoder.end()
  if (trailing.length > 0) yield trailing
}

type CsvState = 'field-start' | 'unquoted' | 'quoted' | 'after-quote'

/**
 * Incrementally parses RFC4180-style records. CRLF and bare LF/CR are accepted as
 * record endings; CR/LF inside a quoted field are preserved verbatim.
 */
export async function* parseCsv(
  source: ByteSource,
  options: CsvParseOptions = {}
): AsyncGenerator<string[]> {
  const delimiter = resolveDelimiter(options.delimiter)
  const limits = resolveLimits(options)
  let state: CsvState = 'field-start'
  let field = ''
  let fieldBytes = 0
  let fields: string[] = []
  let recordBytes = 0
  let recordTouched = false
  let recordNumber = 1
  let lineNumber = 1
  let previousPhysicalCharacterWasCr = false
  let skipLfAfterRecordCr = false
  let atFileStart = true

  const location = (): ErrorLocation => ({ lineNumber, recordNumber })

  const appendField = (character: string): void => {
    field += character
    fieldBytes += utf8Bytes(character)
    if (fieldBytes > limits.maxFieldBytes) {
      throw new TransferLimitError('field', limits.maxFieldBytes, location())
    }
  }

  const finishField = (): void => {
    fields.push(field)
    field = ''
    fieldBytes = 0
    state = 'field-start'
  }

  const takeRecord = (): string[] => {
    finishField()
    const record = fields
    fields = []
    recordBytes = 0
    recordTouched = false
    recordNumber += 1
    return record
  }

  const advancePhysicalLine = (character: string): void => {
    if (character === '\r') {
      lineNumber += 1
      previousPhysicalCharacterWasCr = true
    } else if (character === '\n') {
      if (!previousPhysicalCharacterWasCr) lineNumber += 1
      previousPhysicalCharacterWasCr = false
    } else {
      previousPhysicalCharacterWasCr = false
    }
  }

  for await (const decoded of decodedChunks(source, limits, options.signal, location)) {
    // Abort is checked per chunk; decodedChunks guards chunk reads as well.
    throwIfAborted(options.signal)
    for (const character of decoded) {
      if (atFileStart) {
        atFileStart = false
        if (character === '\uFEFF') continue
      }

      if (skipLfAfterRecordCr && character === '\n') {
        skipLfAfterRecordCr = false
        advancePhysicalLine(character)
        continue
      }
      skipLfAfterRecordCr = false

      recordBytes += utf8Bytes(character)
      if (recordBytes > limits.maxLineBytes) {
        throw new TransferLimitError('line', limits.maxLineBytes, location())
      }

      if (state === 'quoted') {
        recordTouched = true
        if (character === '"') {
          state = 'after-quote'
        } else {
          appendField(character)
        }
        advancePhysicalLine(character)
        continue
      }

      if (state === 'after-quote') {
        if (character === '"') {
          appendField('"')
          state = 'quoted'
        } else if (character === delimiter) {
          finishField()
          recordTouched = true
        } else if (character === '\r' || character === '\n') {
          yield takeRecord()
          if (character === '\r') skipLfAfterRecordCr = true
        } else {
          throw new DelimitedStreamError(
            'INVALID_CSV',
            `Invalid CSV at line ${lineNumber}: unexpected character after a closing quote.`,
            location()
          )
        }
        advancePhysicalLine(character)
        continue
      }

      if (character === delimiter) {
        finishField()
        recordTouched = true
      } else if (character === '\r' || character === '\n') {
        yield takeRecord()
        if (character === '\r') skipLfAfterRecordCr = true
      } else if (character === '"') {
        if (state !== 'field-start') {
          throw new DelimitedStreamError(
            'INVALID_CSV',
            `Invalid CSV at line ${lineNumber}: quote inside an unquoted field.`,
            location()
          )
        }
        state = 'quoted'
        recordTouched = true
      } else {
        appendField(character)
        state = 'unquoted'
        recordTouched = true
      }
      advancePhysicalLine(character)
    }
  }

  if (state === 'quoted') {
    throw new DelimitedStreamError(
      'INVALID_CSV',
      `Invalid CSV at line ${lineNumber}: quoted field was not closed.`,
      location()
    )
  }

  if (recordTouched || fields.length > 0 || state !== 'field-start') {
    yield takeRecord()
  }
}

function serializedCsvField(value: CsvCell, delimiter: string, limits: ResolvedLimits): string {
  const text = value === null || value === undefined ? '' : String(value)
  if (Buffer.byteLength(text, 'utf8') > limits.maxFieldBytes) {
    throw new TransferLimitError('field', limits.maxFieldBytes)
  }
  if (text.includes('"') || text.includes(delimiter) || text.includes('\r') || text.includes('\n')) {
    return `"${text.replaceAll('"', '""')}"`
  }
  return text
}

/** Produces bounded CSV chunks, one BOM or logical record per chunk. */
export async function* serializeCsv(
  rows: Iterable<CsvRow> | AsyncIterable<CsvRow>,
  options: CsvWriteOptions = {}
): AsyncGenerator<string> {
  const delimiter = resolveDelimiter(options.delimiter)
  const limits = resolveLimits(options)
  const lineEnding = options.lineEnding ?? '\r\n'
  if (lineEnding !== '\n' && lineEnding !== '\r\n') {
    throw new TypeError('CSV lineEnding must be LF or CRLF.')
  }

  let totalBytes = 0
  const account = (bytes: number, limit: TransferLimitName, maximum: number): void => {
    if (bytes > maximum) throw new TransferLimitError(limit, maximum)
  }

  if (options.includeBom) {
    const bom = '\uFEFF'
    totalBytes += Buffer.byteLength(bom, 'utf8')
    account(totalBytes, 'total', limits.maxTotalBytes)
    yield bom
  }

  for await (const row of abortable(asAsyncIterable(rows), options.signal)) {
    throwIfAborted(options.signal)
    const line = `${row.map((value) => serializedCsvField(value, delimiter, limits)).join(delimiter)}${lineEnding}`
    const lineBytes = Buffer.byteLength(line, 'utf8')
    account(lineBytes, 'line', limits.maxLineBytes)
    totalBytes += lineBytes
    account(totalBytes, 'total', limits.maxTotalBytes)
    yield line
  }
}

/** Returns a Node Readable so callers can pipe CSV to a file, HTTP response, or adapter sink. */
export function createCsvStream(
  rows: Iterable<CsvRow> | AsyncIterable<CsvRow>,
  options: CsvWriteOptions = {}
): Readable {
  return Readable.from(serializeCsv(rows, options), { encoding: 'utf8' })
}

/** Writes with Node stream backpressure and closes the destination on completion. */
export async function writeCsv(
  rows: Iterable<CsvRow> | AsyncIterable<CsvRow>,
  destination: Writable,
  options: CsvWriteOptions = {}
): Promise<void> {
  const source = createCsvStream(rows, options)
  if (options.signal) {
    await pipeline(source, destination, { signal: options.signal })
  } else {
    await pipeline(source, destination)
  }
}

/** Incrementally parses one JSON value per LF/CRLF-delimited line. */
export async function* parseJsonLines<T = unknown>(
  source: ByteSource,
  options: JsonLinesOptions = {}
): AsyncGenerator<JsonLine<T>> {
  const limits = resolveLimits(options)
  let line = ''
  let lineBytes = 0
  let fieldBytes = 0
  let lineNumber = 1
  let atFileStart = true
  const location = (): ErrorLocation => ({ lineNumber })

  const parseLine = (rawLine: string, number: number): JsonLine<T> | undefined => {
    const content = rawLine.endsWith('\r') ? rawLine.slice(0, -1) : rawLine
    if (content.trim().length === 0 && options.skipEmptyLines) return undefined
    try {
      return { lineNumber: number, value: JSON.parse(content) as T }
    } catch (error) {
      throw new DelimitedStreamError(
        'INVALID_JSONL',
        `Invalid JSON on JSONL line ${number}.`,
        { lineNumber: number },
        error
      )
    }
  }

  for await (const decoded of decodedChunks(source, limits, options.signal, location)) {
    // Abort is checked per chunk; decodedChunks guards chunk reads as well.
    throwIfAborted(options.signal)
    for (const character of decoded) {
      if (atFileStart) {
        atFileStart = false
        if (character === '\uFEFF') continue
      }

      const characterBytes = utf8Bytes(character)
      lineBytes += characterBytes
      if (lineBytes > limits.maxLineBytes) {
        throw new TransferLimitError('line', limits.maxLineBytes, location())
      }

      if (character === '\n') {
        const parsed = parseLine(line, lineNumber)
        if (parsed) yield parsed
        line = ''
        lineBytes = 0
        fieldBytes = 0
        lineNumber += 1
      } else {
        fieldBytes += characterBytes
        if (fieldBytes > limits.maxFieldBytes) {
          throw new TransferLimitError('field', limits.maxFieldBytes, location())
        }
        line += character
      }
    }
  }

  if (line.length > 0) {
    const parsed = parseLine(line, lineNumber)
    if (parsed) yield parsed
  }
}
