// Finished recordings that could not replace the original (the file was held open) and were kept as
// `<name>.finalizing-<ms>.mp4`: put in place at the next launch, or removed with their recording.
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { removeKeptFiles, removeRecordingParts, restoreKeptFiles } from '../src/main/files'

function box(type: string, body: number, size = 8 + body): Buffer {
  const data = Buffer.alloc(8 + body)
  data.writeUInt32BE(size, 0)
  data.write(type, 4, 'latin1')
  return data
}

/// A regular MP4 as the finalizer writes it: `ftyp`, `mdat`, then `moov`.
const finished = (media: number) => Buffer.concat([box('ftyp', 16), box('mdat', media), box('moov', 200)])
/// One the app ended while writing: `mdat` still has its reserved 64-bit size, no `moov` yet.
const cutShort = () => {
  const mdat = Buffer.alloc(16 + 500)
  mdat.writeUInt32BE(1, 0)
  mdat.write('mdat', 4, 'latin1')
  mdat.writeBigUInt64BE(16n, 8)
  return Buffer.concat([box('ftyp', 16), mdat])
}

describe('kept finished recordings', () => {
  let directory: string
  const path = (name: string) => join(directory, name)
  const kept = () => readdirSync(directory).filter((name) => name.includes('.finalizing-')).sort()

  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), 'wp-kept-'))
  })
  afterEach(() => rmSync(directory, { recursive: true, force: true }))

  it('puts the largest complete one in place and removes the rest', async () => {
    writeFileSync(path('a.mp4'), 'fragmented first part')
    writeFileSync(path('a.finalizing-100.mp4'), finished(1000))
    writeFileSync(path('a.finalizing-200.mp4'), finished(100))
    writeFileSync(path('a.finalizing-300.mp4'), cutShort())
    await restoreKeptFiles(directory)
    expect(readFileSync(path('a.mp4'))).toEqual(finished(1000))
    expect(kept()).toEqual([])
  })

  it('puts one in place of a missing recording too', async () => {
    writeFileSync(path('b.finalizing-100.mp4'), finished(100))
    await restoreKeptFiles(directory)
    expect(readFileSync(path('b.mp4'))).toEqual(finished(100))
  })

  it('removes one cut short and leaves the recording alone', async () => {
    writeFileSync(path('c.mp4'), 'recording')
    writeFileSync(path('c.finalizing-100.mp4'), cutShort())
    writeFileSync(path('d.finalizing-100.mp4'), Buffer.concat([box('ftyp', 16), box('mdat', 100, 0)]))
    await restoreKeptFiles(directory)
    expect(readFileSync(path('c.mp4'), 'utf8')).toBe('recording')
    expect(existsSync(path('d.mp4'))).toBe(false)
    expect(kept()).toEqual([])
  })

  it('keeps one that still cannot replace the recording', async () => {
    // A folder in the recording's place: nothing can be moved over it.
    mkdirSync(path('e.mp4'))
    writeFileSync(path('e.finalizing-100.mp4'), finished(100))
    await restoreKeptFiles(directory)
    expect(kept()).toEqual(['e.finalizing-100.mp4'])
  })

  it('removes the kept files of a deleted recording only', async () => {
    writeFileSync(path('f.finalizing-100.mp4'), finished(100))
    writeFileSync(path('ff.finalizing-100.mp4'), finished(100))
    removeKeptFiles(directory, 'f.mp4')
    expect(kept()).toEqual(['ff.finalizing-100.mp4'])
  })

  it('removes the parts of a deleted recording only', () => {
    mkdirSync(path('.parts'))
    for (const name of ['g-part2.mp4', 'g-part3.mp4', 'g-2-part2.mp4', 'g-party.mp4']) writeFileSync(path(join('.parts', name)), 'part')
    removeRecordingParts(directory, 'g.mp4')
    expect(readdirSync(path('.parts')).sort()).toEqual(['g-2-part2.mp4', 'g-party.mp4'])
    // No `.parts` at all: nothing to do.
    removeRecordingParts(join(directory, 'missing'), 'g.mp4')
  })
})
