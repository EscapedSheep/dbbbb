// @vitest-environment node
import { Buffer } from 'node:buffer'
import { PassThrough, Readable } from 'node:stream'
import { describe, expect, it, vi } from 'vitest'
import {
  ImportRunnerError,
  runCsvImport,
  runJsonLinesImport
} from './import-runner'

describe('CSV import runner', () => {
  it('validates and maps headers before inserting null-prototype records', async () => {
    const csv = 'id,display_name,legacy,__proto__\r\n1,Ada,old,hidden\r\n'
    const inserted: Array<Record<string, string>> = []
    const unknownColumns: string[] = []
    const dangerousColumns: string[] = []
    const contexts: Array<{ firstSourceNumber: number; lastSourceNumber: number }> = []

    const summary = await runCsvImport(Readable.from([csv]), {
      knownColumns: ['id', 'name'],
      onUnknownColumn(issue) {
        unknownColumns.push(issue.column)
        return issue.column === 'display_name'
          ? { action: 'map', column: 'name' }
          : { action: 'skip' }
      },
      onDangerousColumn(issue) {
        dangerousColumns.push(issue.column)
        return { action: 'skip' }
      },
      async insertRows(rows, context) {
        inserted.push(...rows)
        contexts.push(context)
      }
    })

    expect(unknownColumns).toEqual(['display_name', 'legacy'])
    expect(dangerousColumns).toEqual(['__proto__'])
    expect(summary.columns).toEqual(['id', 'name'])
    expect(summary.progress).toEqual({
      processed: 1,
      inserted: 1,
      failed: 0,
      bytes: Buffer.byteLength(csv)
    })
    expect(inserted).toHaveLength(1)
    expect(Object.getPrototypeOf(inserted[0])).toBeNull()
    expect(inserted[0]).toEqual({ id: '1', name: 'Ada' })
    expect(contexts).toEqual([{ firstSourceNumber: 2, lastSourceNumber: 2 }])
  })

  it.each([
    ['id,id\n1,2\n', /duplicates/i],
    ['id,  \n1,2\n', /empty/i]
  ])('rejects an invalid header without invoking the sink', async (csv, sampleMessage) => {
    const insertRows = vi.fn(async () => undefined)
    const failure = runCsvImport(Readable.from([csv]), { insertRows })

    await expect(failure).rejects.toBeInstanceOf(ImportRunnerError)
    await expect(failure).rejects.toMatchObject({
      code: 'HEADER_INVALID',
      progress: { processed: 0, inserted: 0, failed: 0 }
    })
    await expect(failure).rejects.toSatisfy((error: ImportRunnerError) =>
      sampleMessage.test(error.errorSamples[0]?.message ?? '')
    )
    expect(insertRows).not.toHaveBeenCalled()
  })

  it('continues past strict column-count errors and caps safe error samples', async () => {
    const batches: Array<Array<Record<string, string>>> = []
    const summary = await runCsvImport(
      Readable.from(['a,b\n1,2\nshort\n3,4,extra\n5,6\n']),
      {
        batchSize: 2,
        errorMode: 'continue',
        maxErrorSamples: 1,
        async insertRows(rows) {
          batches.push([...rows])
        }
      }
    )

    expect(batches).toEqual([[
      { a: '1', b: '2' },
      { a: '5', b: '6' }
    ]])
    expect(summary.progress).toMatchObject({ processed: 4, inserted: 2, failed: 2 })
    expect(summary.errorSamples).toHaveLength(1)
    expect(summary.errorSamples[0]).toMatchObject({
      code: 'COLUMN_COUNT',
      sourceNumber: 3,
      count: 1
    })
    expect(JSON.stringify(summary.errorSamples)).not.toContain('short')
  })

  it('stops by default on an insert error without exposing row contents', async () => {
    const secret = 'TOP_SECRET_VALUE'
    const failure = runCsvImport(Readable.from([`id,note\n1,${secret}\n2,later\n`]), {
      batchSize: 1,
      async insertRows() {
        throw new Error(`database rejected ${secret}`)
      }
    })

    await expect(failure).rejects.toMatchObject({
      code: 'INSERT_FAILED',
      progress: { processed: 1, inserted: 0, failed: 1 }
    })
    await expect(failure).rejects.toSatisfy((error: ImportRunnerError) => {
      expect(error.errorSamples[0]).toMatchObject({
        code: 'INSERT_FAILED',
        sourceNumber: 2,
        count: 1
      })
      return !JSON.stringify(error).includes(secret)
    })
  })

  it('flushes configured batch sizes and fails rather than silently truncating at maxRows', async () => {
    const sizes: number[] = []
    const summary = await runCsvImport(Readable.from(['id\n1\n2\n3\n4\n5\n']), {
      batchSize: 2,
      async insertRows(rows) {
        sizes.push(rows.length)
      }
    })
    expect(sizes).toEqual([2, 2, 1])
    expect(summary.progress.inserted).toBe(5)

    const limitedSizes: number[] = []
    const limited = runCsvImport(Readable.from(['id\n1\n2\n3\n']), {
      batchSize: 2,
      maxRows: 2,
      async insertRows(rows) {
        limitedSizes.push(rows.length)
      }
    })
    await expect(limited).rejects.toMatchObject({
      code: 'ROW_LIMIT',
      progress: { processed: 2, inserted: 2, failed: 0 }
    })
    expect(limitedSizes).toEqual([2])
  })

  it('uses an explicit header without consuming the first record', async () => {
    const rows: Array<Record<string, string>> = []
    const summary = await runCsvImport(Readable.from(['1,Ada\n2,Lin\n']), {
      explicitHeader: ['id', 'name'],
      batchSize: 1,
      async insertRows(batch, context) {
        rows.push(...batch)
        expect(context.firstSourceNumber).toBe(rows.length)
      }
    })

    expect(rows).toEqual([
      { id: '1', name: 'Ada' },
      { id: '2', name: 'Lin' }
    ])
    expect(summary.progress).toMatchObject({ processed: 2, inserted: 2, failed: 0 })

    const empty = await runCsvImport(Readable.from([]), {
      explicitHeader: ['id', 'name'],
      async insertRows() {}
    })
    expect(empty.progress).toMatchObject({ processed: 0, inserted: 0, failed: 0 })
  })

  it('propagates AbortSignal while a partial batch waits for more input', async () => {
    const input = new PassThrough()
    const controller = new AbortController()
    const insertRows = vi.fn(async () => undefined)
    const running = runCsvImport(input, {
      batchSize: 10,
      signal: controller.signal,
      insertRows
    })

    input.write('id\n1\n')
    await new Promise((resolve) => setImmediate(resolve))
    controller.abort()

    await expect(running).rejects.toMatchObject({ name: 'AbortError' })
    expect(insertRows).not.toHaveBeenCalled()
    input.destroy()
  })
})

describe('JSONL import runner', () => {
  it('requires plain objects and continues with valid documents in batches', async () => {
    const batches: Array<Array<Record<string, unknown>>> = []
    const summary = await runJsonLinesImport(
      Readable.from(['{"id":1}\n[2]\nnull\n{"id":3}\n']),
      {
        batchSize: 2,
        errorMode: 'continue',
        async insertDocuments(documents) {
          batches.push([...documents])
        }
      }
    )

    expect(batches).toEqual([[{ id: 1 }, { id: 3 }]])
    expect(summary.progress).toMatchObject({ processed: 4, inserted: 2, failed: 2 })
    expect(summary.errorSamples).toEqual([
      {
        code: 'DOCUMENT_TYPE',
        sourceNumber: 2,
        count: 1,
        message: 'JSONL line 2 must contain one plain object.'
      },
      {
        code: 'DOCUMENT_TYPE',
        sourceNumber: 3,
        count: 1,
        message: 'JSONL line 3 must contain one plain object.'
      }
    ])
  })

  it('stops on an unrecoverable JSONL parse error with its line number and no row text', async () => {
    const secret = 'VERY_PRIVATE_CONTENT'
    const inserted: Array<Record<string, unknown>> = []
    const failure = runJsonLinesImport(
      Readable.from([`{"ok":1}\n{"secret":"${secret}",}\n{"later":3}\n`]),
      {
        batchSize: 1,
        errorMode: 'continue',
        async insertDocuments(documents) {
          inserted.push(...documents)
        }
      }
    )

    await expect(failure).rejects.toMatchObject({
      code: 'PARSE_ERROR',
      progress: { processed: 2, inserted: 1, failed: 1 },
      errorSamples: [{ code: 'PARSE_ERROR', sourceNumber: 2, count: 1 }]
    })
    await expect(failure).rejects.toSatisfy((error: ImportRunnerError) =>
      !JSON.stringify(error).includes(secret)
    )
    expect(inserted).toEqual([{ ok: 1 }])
  })

  it('rejects dangerous object keys at any document depth without exposing them to the sink', async () => {
    const inserted: Array<Record<string, unknown>> = []
    const summary = await runJsonLinesImport(
      Readable.from([
        '{"safe":1}\n',
        '{"nested":{"__proto__":{"polluted":true}}}\n',
        '{"safe":2}\n'
      ]),
      {
        errorMode: 'continue',
        async insertDocuments(documents) {
          inserted.push(...documents)
        }
      }
    )

    expect(inserted).toEqual([{ safe: 1 }, { safe: 2 }])
    expect(summary.progress).toMatchObject({ processed: 3, inserted: 2, failed: 1 })
    expect(summary.errorSamples).toEqual([{
      code: 'DOCUMENT_TYPE',
      sourceNumber: 2,
      count: 1,
      message: 'JSONL line 2 contains an unsafe object key.'
    }])
  })

  it('counts only the uninserted remainder as failed when a batch error reports partial progress', async () => {
    const summary = await runJsonLinesImport(
      Readable.from(['{"id":1}\n{"id":2}\n{"id":3}\n']),
      {
        batchSize: 3,
        errorMode: 'continue',
        async insertDocuments() {
          const error = new Error('duplicate key')
          ;(error as { insertedCount?: number }).insertedCount = 1
          throw error
        }
      }
    )

    expect(summary.progress).toMatchObject({ processed: 3, inserted: 1, failed: 2 })
    expect(summary.errorSamples).toEqual([
      expect.objectContaining({ code: 'INSERT_FAILED', sourceNumber: 1, count: 2 })
    ])
  })

  it('stops on a partially inserted batch failure with counts that match the server', async () => {
    const failure = runJsonLinesImport(
      Readable.from(['{"id":1}\n{"id":2}\n{"id":3}\n']),
      {
        batchSize: 3,
        async insertDocuments() {
          const error = new Error('duplicate key')
          ;(error as { insertedCount?: number }).insertedCount = 2
          throw error
        }
      }
    )

    await expect(failure).rejects.toMatchObject({
      code: 'INSERT_FAILED',
      progress: { processed: 3, inserted: 2, failed: 1 },
      errorSamples: [expect.objectContaining({ code: 'INSERT_FAILED', count: 1 })]
    })
  })

  it('credits a partially inserted batch before propagating an abort', async () => {
    const controller = new AbortController()
    const progressUpdates: Array<{ processed: number; inserted: number; failed: number }> = []
    const running = runJsonLinesImport(Readable.from(['{"id":1}\n{"id":2}\n']), {
      batchSize: 2,
      signal: controller.signal,
      onProgress(update) {
        progressUpdates.push({ ...update })
      },
      async insertDocuments() {
        controller.abort()
        const error = new Error('insert aborted midway')
        error.name = 'AbortError'
        ;(error as { insertedCount?: number }).insertedCount = 1
        throw error
      }
    })

    await expect(running).rejects.toMatchObject({ name: 'AbortError' })
    expect(progressUpdates.at(-1)).toMatchObject({ processed: 2, inserted: 1, failed: 0 })
  })

  it('credits a completed batch when a cancellation races its successful insert', async () => {
    const controller = new AbortController()
    const progressUpdates: Array<{ processed: number; inserted: number; failed: number }> = []
    const running = runJsonLinesImport(Readable.from(['{"id":1}\n{"id":2}\n']), {
      batchSize: 2,
      signal: controller.signal,
      onProgress(update) {
        progressUpdates.push({ ...update })
      },
      async insertDocuments() {
        controller.abort()
        return 2
      }
    })

    await expect(running).rejects.toMatchObject({ name: 'AbortError' })
    expect(progressUpdates.at(-1)).toMatchObject({ processed: 2, inserted: 2, failed: 0 })
  })
})
