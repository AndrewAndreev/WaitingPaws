// The recording pieces of the main process: MP4FragmentScanner (port of MP4FragmentScannerTests.swift), the
// StreamRecorder against a local fake go2rtc, replacing a finalized file, and reading `xiaomi://` sources.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync, existsSync } from 'node:fs'
import { createServer, type Server, type ServerResponse } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MP4FragmentScanner, queryValue } from '@core/index'
import { StreamRecorder } from '../src/main/recorder'
import { replaceFile } from '../src/main/files'

function box(type: string, body: number): Uint8Array {
  const data = new Uint8Array(8 + body).fill(0x6d) // bytes that spell "moof" nowhere useful
  new DataView(data.buffer).setUint32(0, 8 + body)
  data.set(new TextEncoder().encode(type), 4)
  return data
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0))
  let offset = 0
  for (const part of parts) {
    out.set(part, offset)
    offset += part.length
  }
  return out
}

function until(condition: () => boolean, timeout = 3000): Promise<void> {
  const start = Date.now()
  return new Promise((resolve, reject) => {
    const check = () => {
      if (condition()) return resolve()
      if (Date.now() - start > timeout) return reject(new Error('timed out'))
      setTimeout(check, 10)
    }
    check()
  })
}

describe('MP4FragmentScanner', () => {
  it("doesn't take the init segment for a fragment", () => {
    const scanner = new MP4FragmentScanner()
    expect(scanner.feed(concat(box('ftyp', 16), box('moov', 700)))).toBe(false)
    expect(scanner.feed(concat(box('moof', 100), box('mdat', 5000)))).toBe(true)
    expect(scanner.sawFragment).toBe(true)
  })

  it('reads boxes (and their headers) cut anywhere by the network', () => {
    const stream = concat(box('ftyp', 16), box('moov', 1300), box('moof', 90))
    const fragmentStart = stream.length - 98
    for (const chunk of [1, 3, 7, 64, 1000]) {
      const scanner = new MP4FragmentScanner()
      let seenAt: number | null = null
      for (let offset = 0; offset < stream.length; offset += chunk) {
        if (scanner.feed(stream.subarray(offset, Math.min(offset + chunk, stream.length))) && seenAt === null) seenAt = offset
      }
      expect(seenAt, `chunk ${chunk}`).not.toBeNull()
      expect(seenAt!).toBeLessThanOrEqual(fragmentStart + 7)
      expect(seenAt! + chunk).toBeGreaterThan(fragmentStart)
    }
  })

  it('skips a box body that happens to contain "moof"', () => {
    const moov = concat(box('moov', 0), new TextEncoder().encode('....moof....'))
    moov[3] = 8 + 12
    expect(new MP4FragmentScanner().feed(concat(box('ftyp', 8), moov))).toBe(false)
  })

  it('reads a 64-bit box size', () => {
    const large = new Uint8Array(20)
    const view = new DataView(large.buffer)
    view.setUint32(0, 1)
    large.set(new TextEncoder().encode('free'), 4)
    view.setBigUint64(8, 20n)
    const scanner = new MP4FragmentScanner()
    expect(scanner.feed(large)).toBe(false)
    expect(scanner.feed(box('moof', 8))).toBe(true)
  })
})

describe('queryValue', () => {
  const source = 'xiaomi://123:cn@192.168.1.5?did=4567&model=chuangmi.camera.069a01&subtype=hd&token=a%3Db&extra=x+y#part'

  it('reads items as URLComponents.queryItems does', () => {
    expect(queryValue(source, 'did')).toBe('4567')
    expect(queryValue(source, 'model')).toBe('chuangmi.camera.069a01')
    expect(queryValue(source, 'subtype')).toBe('hd')
    // Percent-decoded, "+" stays, the value runs past a second "=", the fragment is not part of it.
    expect(queryValue(source, 'token')).toBe('a=b')
    expect(queryValue('xiaomi://h?k=a=b', 'k')).toBe('a=b')
    expect(queryValue(source, 'extra')).toBe('x+y')
    expect(queryValue(source, 'missing')).toBeNull()
    expect(queryValue('xiaomi://h?flag&k=1', 'flag')).toBeNull()
    expect(queryValue('xiaomi://host', 'did')).toBeNull()
  })

  it('gives null for a malformed escape instead of throwing', () => {
    expect(queryValue('xiaomi://h?model=%zz&did=1', 'model')).toBeNull()
    expect(queryValue('xiaomi://h?model=%zz&did=1', 'did')).toBe('1')
  })
})

/// A fake go2rtc `/api/stream.mp4`: the init segment at once, a fragment on `fragment()`, the end on `end()`.
class FakeStream {
  readonly server: Server
  response: ServerResponse | null = null
  port = 0

  constructor(status = 200) {
    this.server = createServer((request, response) => {
      response.writeHead(status, { 'Content-Type': 'video/mp4' })
      if (status !== 200) return response.end('no stream')
      this.response = response
      response.write(concat(box('ftyp', 16), box('moov', 200)))
    })
  }

  async start(): Promise<string> {
    await new Promise<void>((resolve) => this.server.listen(0, '127.0.0.1', resolve))
    const address = this.server.address()
    this.port = typeof address === 'object' && address ? address.port : 0
    return `http://127.0.0.1:${this.port}/api/stream.mp4?src=cam`
  }

  fragment(): void {
    this.response?.write(concat(box('moof', 100), box('mdat', 4000)))
  }

  end(): void {
    this.response?.end()
  }

  close(): void {
    this.server.closeAllConnections()
    this.server.close()
  }
}

describe('StreamRecorder', () => {
  let directory: string
  let fake: FakeStream

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), 'wp-rec-'))
  })

  afterEach(() => {
    fake?.close()
    rmSync(directory, { recursive: true, force: true })
  })

  it('notes when the video began to arrive, apart from the request', async () => {
    fake = new FakeStream()
    const url = await fake.start()
    const recorder = new StreamRecorder()
    let fragments = 0
    recorder.onFirstFragment = () => (fragments += 1)
    const path = join(directory, 'a.mp4')
    recorder.start(url, null, path)
    await until(() => recorder.bytesWritten > 0)
    await new Promise((resolve) => setTimeout(resolve, 60))
    expect(recorder.firstFragmentAt).toBeNull()
    fake.fragment()
    await until(() => recorder.firstFragmentAt !== null)
    expect(recorder.firstFragmentAt! - recorder.startedAt!).toBeGreaterThanOrEqual(50)
    fake.fragment()
    await recorder.stop()
    expect(fragments).toBe(1)
    expect(statSync(path).size).toBe(recorder.bytesWritten)
  })

  it('ends with the reason when the stream ends or is refused, not after stop()', async () => {
    fake = new FakeStream()
    const url = await fake.start()
    const recorder = new StreamRecorder()
    const ended: (string | null)[] = []
    recorder.onEnded = (reason) => ended.push(reason)
    recorder.start(url, null, join(directory, 'a.mp4'))
    await until(() => recorder.bytesWritten > 0)
    fake.end()
    await until(() => ended.length === 1)
    expect(recorder.isRecording).toBe(false)
    expect(recorder.writeFailed).toBe(false)

    const refused = new FakeStream(404)
    const refusedURL = await refused.start()
    try {
      recorder.start(refusedURL, null, join(directory, 'b.mp4'))
      await until(() => ended.length === 2)
      expect(ended[1]).toBe('HTTP 404')
    } finally {
      refused.close()
    }

    recorder.start(url, null, join(directory, 'c.mp4'))
    await recorder.stop()
    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(ended).toHaveLength(2)
  })

  it("survives a file it can't write: the recording ends with the reason, stop() still resolves", async () => {
    fake = new FakeStream()
    const url = await fake.start()
    const recorder = new StreamRecorder()
    const ended: (string | null)[] = []
    recorder.onEnded = (reason) => ended.push(reason)
    // A folder where the file should be: opening it fails as a locked or protected file does.
    const path = join(directory, 'taken.mp4')
    mkdirSync(path)
    recorder.start(url, null, path)
    await until(() => ended.length === 1)
    expect(recorder.writeFailed).toBe(true)
    expect(recorder.lastError).toMatch(/EISDIR|EPERM|EACCES/)
    await recorder.stop()

    // Stopped while the error comes in: stop() resolves too.
    const second = join(directory, 'taken2.mp4')
    mkdirSync(second)
    recorder.start(url, null, second)
    await recorder.stop()
    expect(ended).toHaveLength(1)
  })
})

describe('replaceFile', () => {
  let directory: string

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), 'wp-files-'))
  })

  afterEach(() => {
    rmSync(directory, { recursive: true, force: true })
  })

  it('puts the new file in place of the old one', async () => {
    const target = join(directory, 'a.mp4')
    const temp = join(directory, 'a.finalizing-1.mp4')
    writeFileSync(target, 'old')
    writeFileSync(temp, 'new')
    await replaceFile(temp, target)
    expect(readFileSync(target, 'utf8')).toBe('new')
    expect(existsSync(temp)).toBe(false)
  })

  it('keeps both files when it cannot', async () => {
    const target = join(directory, 'a.mp4')
    const temp = join(directory, 'a.finalizing-1.mp4')
    mkdirSync(target)
    writeFileSync(join(target, 'inside'), 'x')
    writeFileSync(temp, 'new')
    await expect(replaceFile(temp, target, 2)).rejects.toThrow()
    expect(readFileSync(temp, 'utf8')).toBe('new')
    expect(existsSync(join(target, 'inside'))).toBe(true)
  })
})
