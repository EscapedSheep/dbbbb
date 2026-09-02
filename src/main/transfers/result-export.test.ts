// @vitest-environment node
import { Buffer } from 'node:buffer'
import { Readable, Writable } from 'node:stream'
import { setTimeout as delay } from 'node:timers/promises'
import { describe, expect, it, vi } from 'vitest'
import type { DocumentResult, RowResult } from '../../shared/database'
import { parseCsv } from './delimited'
import {
  ResultExportError,
  canonicalJson,
  exportResult
} from './result-export'

function rowResult(rows: RowResult['rows']): RowResult {
  return {
    kind: 'rows',
    columns: [
      { key: 'zero', label: 'Zero', dataType: 'int4' },
      { key: 'disabled', label: 'Disabled', dataType: 'bool' },
      { key: 'empty', label: 'Empty', dataType: 'text' },
      { key: 'nested', label: 'Nested', dataType: 'jsonb' }
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

function collectingWritable(chunks: Buffer[]): Writable {
  return new Writable({
    write(chunk: Buffer, _encoding, callback) {
      chunks.push(Buffer.from(chunk))
      callback()
    }
  })
}

async function collect<T>(source: AsyncIterable<T>): Promise<T[]> {
  const values: T[] = []
  for await (const value of source) values.push(value)
  return values
}

describe('bounded result export', () => {
  it('exports RowResult labels and values as CSV without losing 0, false, or null', async () => {
    const chunks: Buffer[] = []
    const summary = await exportResult(
      rowResult([[0, false, null, { b: 1, a: ['雪'] }]]),
      collectingWritable(chunks),
      { maxBytes: 4096 }
    )
    const output = Buffer.concat(chunks)

    expect(summary).toEqual({ rows: 1, bytes: output.byteLength })
    expect(await collect(parseCsv(Readable.from([output])))).toEqual([
      ['Zero', 'Disabled', 'Empty', 'Nested'],
      ['0', 'false', '', '{"a":["雪"],"b":1}']
    ])
  })

  it('exports deterministic compact JSONL with one document per LF-terminated line', async () => {
    const chunks: Buffer[] = []
    const summary = await exportResult(documentResult([
      { z: 0, a: false, nested: { z: null, a: ['雪'] } },
      { id: 2, enabled: true }
    ]), collectingWritable(chunks), { maxBytes: 4096 })
    const output = Buffer.concat(chunks)

    expect(output.toString('utf8')).toBe(
      '{"a":false,"nested":{"a":["雪"],"z":null},"z":0}\n' +
      '{"enabled":true,"id":2}\n'
    )
    expect(summary).toEqual({ rows: 2, bytes: output.byteLength })
  })

  it('waits for a backpressured destination before completing', async () => {
    const chunks: Buffer[] = []
    let pendingWrites = 0
    let maximumPendingWrites = 0
    const slowDestination = new Writable({
      highWaterMark: 1,
      write(chunk: Buffer, _encoding, callback) {
        pendingWrites += 1
        maximumPendingWrites = Math.max(maximumPendingWrites, pendingWrites)
        setTimeout(() => {
          chunks.push(Buffer.from(chunk))
          pendingWrites -= 1
          callback()
        }, 5)
      }
    })

    const summary = await exportResult(documentResult([
      { id: 1 },
      { id: 2 },
      { id: 3 }
    ]), slowDestination, { maxBytes: 4096 })

    expect(summary.rows).toBe(3)
    expect(maximumPendingWrites).toBe(1)
    expect(Buffer.concat(chunks).toString('utf8')).toContain('{"id":3}\n')
  })

  it('enforces the total UTF-8 byte limit before yielding an oversized record', async () => {
    const firstLine = `${canonicalJson({ id: 1 })}\n`
    const chunks: Buffer[] = []
    const exported = exportResult(documentResult([
      { id: 1 },
      { secret: 'must-not-appear-in-the-error' }
    ]), collectingWritable(chunks), {
      maxBytes: Buffer.byteLength(firstLine, 'utf8')
    })

    await expect(exported).rejects.toMatchObject({
      name: 'ResultExportError',
      code: 'LIMIT_EXCEEDED',
      maximumBytes: Buffer.byteLength(firstLine, 'utf8')
    })
    const error = await exported.catch((caught: unknown) => caught)
    expect((error as Error).message).not.toContain('must-not-appear')
    expect(Buffer.concat(chunks).toString('utf8')).toBe(firstLine)
  })

  it('aborts during a slow write without exposing a custom abort reason', async () => {
    const controller = new AbortController()
    const destination = new Writable({
      highWaterMark: 1,
      write(_chunk: Buffer, _encoding, callback) {
        setTimeout(callback, 40)
      }
    })
    const exported = exportResult(documentResult([
      { id: 1 },
      { id: 2 }
    ]), destination, { maxBytes: 4096, signal: controller.signal })

    await delay(5)
    controller.abort(new Error('private document contents'))
    const error = await exported.catch((caught: unknown) => caught)

    expect(error).toBeInstanceOf(ResultExportError)
    expect(error).toMatchObject({ code: 'ABORTED' })
    expect((error as Error).message).toBe('Result export was aborted.')
    expect((error as Error).message).not.toContain('private document contents')
  })

  it('normalizes invalid result and destination errors without echoing content', async () => {
    const circular: Record<string, never> = {}
    Object.defineProperty(circular, 'private-value', {
      enumerable: true,
      value: circular
    })
    const invalid = exportResult(
      documentResult([circular]),
      collectingWritable([]),
      { maxBytes: 4096 }
    )
    const invalidError = await invalid.catch((caught: unknown) => caught)
    expect(invalidError).toMatchObject({ code: 'INVALID_RESULT' })
    expect((invalidError as Error).message).not.toContain('private-value')

    const sink = new Writable({
      write(chunk: Buffer, _encoding, callback) {
        callback(new Error(`failed while writing ${chunk.toString('utf8')}`))
      }
    })
    const failed = exportResult(documentResult([
      { private: 'sink must not echo this' }
    ]), sink, { maxBytes: 4096 })
    const sinkError = await failed.catch((caught: unknown) => caught)
    expect(sinkError).toMatchObject({ code: 'WRITE_FAILED' })
    expect((sinkError as Error).message).toBe('Result export could not be written.')
    expect((sinkError as Error).message).not.toContain('sink must not echo this')
  })

  it('rejects malformed row alignment and invalid byte options', async () => {
    await expect(exportResult(
      rowResult([[1]]),
      collectingWritable([]),
      { maxBytes: 4096 }
    )).rejects.toMatchObject({ code: 'INVALID_RESULT' })

    await expect(exportResult(
      rowResult([[0, false, null, Number.NaN]]),
      collectingWritable([]),
      { maxBytes: 4096 }
    )).rejects.toMatchObject({ code: 'INVALID_RESULT' })

    await expect(exportResult(
      documentResult([]),
      collectingWritable([]),
      { maxBytes: 0 }
    )).rejects.toMatchObject({ code: 'INVALID_OPTIONS' })
  })
})
