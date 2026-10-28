import { closeSync, existsSync, fstatSync, openSync, readdirSync, readSync, renameSync, statSync, unlinkSync } from 'node:fs'
import { join } from 'node:path'
import { write as log } from './log'

/// Moves `source` over `target` in one step: Windows replaces an existing file too, so there is never a moment
/// without either of them. A player, Explorer's preview or an antivirus holding the target makes Windows refuse for a
/// while, so that is tried again for a few seconds. Throws the last error, leaving `source` where it is.
export async function replaceFile(source: string, target: string, attempts = 8): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    try {
      renameSync(source, target)
      return
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code
      if (attempt >= attempts || !['EBUSY', 'EPERM', 'EACCES'].includes(code ?? '')) throw error
      await new Promise((resolve) => setTimeout(resolve, 250 * attempt))
    }
  }
}

/// `MediaFinalizer.write` writes `<name>.finalizing-<ms>.mp4` next to `<name>.mp4`, and keeps it when it can't
/// replace the recording.
const KEPT = /^(.+)\.finalizing-\d+\.mp4$/i

/// The kept files of each recording in `directory`: recording file name → paths.
function keptFiles(directory: string): Map<string, string[]> {
  const kept = new Map<string, string[]>()
  let names: string[]
  try {
    names = readdirSync(directory)
  } catch {
    return kept
  }
  for (const name of names) {
    const match = KEPT.exec(name)
    if (!match) continue
    const target = `${match[1]}.mp4`
    kept.set(target, [...(kept.get(target) ?? []), join(directory, name)])
  }
  return kept
}

/// At launch, before the history lists the folder: finished files that could not replace their recording (held open
/// too long) go in now. Of several, the largest (a join is larger than a finalize of its first part). One cut short
/// (the app ended while writing it) is removed: the recording itself was never touched. A file that still can't be
/// moved stays for the next launch.
export async function restoreKeptFiles(directory: string): Promise<void> {
  for (const [target, paths] of keptFiles(directory)) {
    const complete = paths.filter(isCompleteMP4).sort((a, b) => statSync(b).size - statSync(a).size)
    for (const path of paths) if (!complete.includes(path)) removeQuietly(path)
    const [best, ...others] = complete
    if (!best) continue
    try {
      await replaceFile(best, join(directory, target), 3)
      log(`[rec] put the finished file kept as ${best} in place of ${target}`)
      for (const path of others) removeQuietly(path)
    } catch (error) {
      log(`[rec] the finished file kept as ${best} still can't replace ${target}: ${(error as Error).message}`)
    }
  }
}

/// A deleted recording's kept files go with it (else the next launch would put it back).
export function removeKeptFiles(directory: string, fileName: string): void {
  for (const path of keptFiles(directory).get(fileName) ?? []) removeQuietly(path)
}

/// A deleted recording's parts in `.parts` (`<name>-part<N>.mp4`: one left out of a join, or a join cut short).
export function removeRecordingParts(directory: string, fileName: string): void {
  const prefix = `${fileName.replace(/\.mp4$/i, '')}-part`
  let names: string[]
  try {
    names = readdirSync(join(directory, '.parts'))
  } catch {
    return
  }
  for (const name of names) {
    if (name.startsWith(prefix) && /^\d+\.mp4$/i.test(name.slice(prefix.length))) removeQuietly(join(directory, '.parts', name))
  }
}

/// Whether `path` is a whole MP4: its top-level boxes fill the file exactly and one of them is `moov` (which the
/// finalizer writes last). A file cut short is not.
function isCompleteMP4(path: string): boolean {
  let fd: number
  try {
    fd = openSync(path, 'r')
  } catch {
    return false
  }
  try {
    const size = fstatSync(fd).size
    const header = Buffer.alloc(16)
    let movie = false
    let position = 0
    while (position < size) {
      const read = readSync(fd, header, 0, 16, position)
      if (read < 8) return false
      let length = header.readUInt32BE(0)
      if (length === 1) length = read < 16 ? 0 : Number(header.readBigUInt64BE(8))
      // 0 is "up to the end of the file": a box never closed.
      if (length < 8) return false
      if (header.toString('latin1', 4, 8) === 'moov') movie = true
      position += length
    }
    return movie && position === size
  } catch {
    return false
  } finally {
    closeSync(fd)
  }
}

function removeQuietly(path: string): void {
  try {
    if (existsSync(path)) unlinkSync(path)
  } catch (error) {
    log(`[files] could not remove ${path}: ${(error as Error).message}`)
  }
}
