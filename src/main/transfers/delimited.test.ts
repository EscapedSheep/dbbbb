// @vitest-environment node
import { Buffer } from 'node:buffer'
import { PassThrough, Readable, Writable } from 'node:stream'
import { describe, expect, it } from 'vitest'
import {
  DelimitedStreamError,
  TransferLimitError,
  parseCsv,
  parseJsonLines,
  writeCsv
} from './delimited'

function splitBytes(value: string, sizes: number[]): Buffer[] {
  const bytes = Buffer.from(value, 'utf8')
  const chunks: Buffer[] = []
  let offset = 0
  let sizeIndex = 0
  while (offset < bytes.length) {
    const size = sizes[sizeIndex % sizes.length]
    chunks.push(bytes.subarray(offset, Math.min(bytes.length, offset + size)))
    offset += size
    sizeIndex += 1
  }
  return chunks
}

async function collect<T>(source: AsyncIterable<T>): Promise<T[]> {
  const values: T[] = []
  for await (const value of source) values.push(value)
  return values
}

describe('streaming CSV transfers', () => {
  it('parses BOM, CRLF, chunk boundaries, escaped quotes, and multiline fields', async () => {
    const csv = '\uFEFFname,note\r\n"Ada","hello,\r\nworld"\r\n"雪","a ""quoted"" value"\r\n'
    const rows = await collect(parseCsv(Readable.from(splitBytes(csv, [1, 2, 5, 3]))))

    expect(rows).toEqual([
      ['name', 'note'],
      ['Ada', 'hello,\r\nworld'],
      ['雪', 'a "quoted" value']
    ])
  })

  it('writes through a Node stream and round-trips quoted values', async () => {
    const expected = [
      ['plain', 'comma,value', 'quote"value', 'line one\nline two', 'crlf\r\nvalue', ''],
      ['雪', '', '42', 'true', '', 'tail']
    ]
    const output: Buffer[] = []
    const destination = new Writable({
      write(chunk: Buffer, _encoding, callback) {
        output.push(Buffer.from(chunk))
        callback()
      }
    })

    await writeCsv(
      [
        expected[0],
        ['雪', null, 42, true, undefined, 'tail']
      ],
      destination,
      { includeBom: true }
    )

    const serialized = Buffer.concat(output).toString('utf8')
    expect(serialized.startsWith('\uFEFF')).toBe(true)
    const parsed = await collect(parseCsv(Readable.from(splitBytes(serialized, [2, 1, 4]))))
    expect(parsed).toEqual(expected)
  })

  it('reports the physical line for malformed CSV', async () => {
    const consume = collect(parseCsv(Readable.from(['a,b\r\nx"y,z\r\n'])))
    await expect(consume).rejects.toMatchObject({
      code: 'INVALID_CSV',
      lineNumber: 2,
      recordNumber: 2
    })
  })

  it('enforces field, line, and total byte limits', async () => {
    await expect(
      collect(parseCsv(Readable.from(['abcd\n']), { maxFieldBytes: 3 }))
    ).rejects.toMatchObject({ limit: 'field', maximumBytes: 3 })

    await expect(
      collect(parseCsv(Readable.from(['a,b,c\n']), { maxLineBytes: 5 }))
    ).rejects.toMatchObject({ limit: 'line', maximumBytes: 5 })

    await expect(
      collect(parseCsv(Readable.from(['a,b\n']), { maxTotalBytes: 3 }))
    ).rejects.toMatchObject({ limit: 'total', maximumBytes: 3 })
  })

  it('aborts while waiting for another stream chunk', async () => {
    const input = new PassThrough()
    const controller = new AbortController()
    const rows = parseCsv(input, { signal: controller.signal })[Symbol.asyncIterator]()

    input.write('a,b\r\n')
    await expect(rows.next()).resolves.toEqual({ done: false, value: ['a', 'b'] })

    const waiting = rows.next()
    controller.abort()
    await expect(waiting).rejects.toMatchObject({ name: 'AbortError' })
  })
})

describe('streaming JSON Lines transfers', () => {
  it('parses BOM and UTF-8 values split across chunks', async () => {
    const jsonl = '\uFEFF{"id":1,"name":"雪"}\r\n{"id":2}\n'
    const lines = await collect(
      parseJsonLines<{ id: number; name?: string }>(
        Readable.from(splitBytes(jsonl, [1, 1, 2, 3]))
      )
    )

    expect(lines).toEqual([
      { lineNumber: 1, value: { id: 1, name: '雪' } },
      { lineNumber: 2, value: { id: 2 } }
    ])
  })

  it('reports a JSON error at the exact input line', async () => {
    const iterator = parseJsonLines(Readable.from(['{"ok":1}\n{"bad":}\n{"later":3}\n']))
    await expect(iterator.next()).resolves.toEqual({
      done: false,
      value: { lineNumber: 1, value: { ok: 1 } }
    })

    const failed = iterator.next()
    await expect(failed).rejects.toBeInstanceOf(DelimitedStreamError)
    await expect(failed).rejects.toMatchObject({ code: 'INVALID_JSONL', lineNumber: 2 })
  })

  it('rejects oversized lines without buffering the rest of the source', async () => {
    const consume = collect(
      parseJsonLines(Readable.from(['{"value":"long"}\n{"unread":true}\n']), {
        maxLineBytes: 8
      })
    )

    await expect(consume).rejects.toBeInstanceOf(TransferLimitError)
    await expect(consume).rejects.toMatchObject({ limit: 'line', lineNumber: 1 })
  })
})
