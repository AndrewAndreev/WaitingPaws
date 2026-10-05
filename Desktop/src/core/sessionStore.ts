// Port of Storage/SessionStore.swift: persists finished sessions (JSON + text log) and hands out file
// locations for recordings.
//
// The folder layout and file formats are the ones the Mac and iPhone apps use, so a history folder can be
// shared both ways:
//
//     <root>/Sessions/2026-09-25_18-00-1F0C8A2B.json   (record, pretty-printed, sorted keys, ISO 8601 dates)
//     <root>/Sessions/2026-09-25_18-00-1F0C8A2B.txt    (the trainer's log, `SessionLogFormatter.text`)
//     <root>/Recordings/2026-09-25_18-00-trenirovka-na-patnicu.mp4  (a second one in that minute: …-2.mp4)
//
// The stamp is the local time of the start, the 8 characters are the start of the record's upper-case UUID.
// On the Mac and iPhone `<root>` is `Documents/Waiting Paws` (`SessionStore.folderName`).
//
// File IO goes through a `StorageBackend`: the Electron main process passes a node:fs implementation, a web
// build could pass one over IndexedDB/OPFS. All methods are async (Swift's are synchronous).

import { DISK_DATES, swiftJSONString } from './codable'
import { Go2RTCClient } from './go2rtcClient'
import { type TrainingPlan } from './models'
import { SessionLogFormatter, TrainingRecord } from './sessionLog'
import { pad2 } from './text'

/** The file system as the core needs it. Paths are whatever `join` makes of the root the store was given. */
export interface StorageBackend {
  /** Joins path segments with the platform's separator. */
  join(...segments: string[]): string
  /** Reads a UTF-8 file; rejects when it is missing. */
  readText(path: string): Promise<string>
  /** Writes a UTF-8 file (no BOM) atomically (temporary file + rename), replacing it. The directory exists. */
  writeText(path: string, text: string): Promise<void>
  /** Names (not paths) of the entries in `directory`, files and folders; `[]` when it does not exist. */
  list(directory: string): Promise<string[]>
  exists(path: string): Promise<boolean>
  /** Removes a file; may reject when it is missing (the store ignores that). */
  remove(path: string): Promise<void>
  /** Creates the directory and its parents; succeeds when it already exists. */
  makeDirectory(path: string): Promise<void>
  /** Last modification time (epoch ms), `null` when missing. Optional: used by the MIoT spec cache. */
  modifiedAt?(path: string): Promise<number | null>
}

/** A file the store named: `name` is what records keep (`recordingFileName`), `path` is where it is. */
export interface StoredFile {
  name: string
  path: string
}

export class SessionStore {
  /** `Documents/<folderName>` on the Mac and iPhone. */
  static readonly folderName = 'Waiting Paws'
  static readonly sessionsFolderName = 'Sessions'
  static readonly recordingsFolderName = 'Recordings'

  constructor(
    readonly storage: StorageBackend,
    readonly rootDirectory: string,
  ) {}

  get sessionsDirectory(): string {
    return this.storage.join(this.rootDirectory, SessionStore.sessionsFolderName)
  }

  get recordingsDirectory(): string {
    return this.storage.join(this.rootDirectory, SessionStore.recordingsFolderName)
  }

  /** Creates `Sessions` and `Recordings` (Swift does it in `init`). */
  async prepare(): Promise<void> {
    await this.storage.makeDirectory(this.sessionsDirectory)
    await this.storage.makeDirectory(this.recordingsDirectory)
  }

  /** A new file name; a second recording within the same minute gets a "-2" suffix instead of overwriting. */
  async newRecordingFile(plan: TrainingPlan, at: number = Date.now()): Promise<StoredFile> {
    await this.storage.makeDirectory(this.recordingsDirectory)
    const base = `${SessionStore.fileStamp(at)}-${Go2RTCClient.streamName(plan.title)}`
    let name = `${base}.mp4`
    let counter = 2
    while (await this.storage.exists(this.storage.join(this.recordingsDirectory, name))) {
      name = `${base}-${counter}.mp4`
      counter += 1
    }
    return { name, path: this.storage.join(this.recordingsDirectory, name) }
  }

  /** Recordings no saved session refers to: made without a training, or kept after deleting only the log. */
  async standaloneRecordings(besides: readonly TrainingRecord[]): Promise<StoredFile[]> {
    const referenced = new Set(besides.flatMap((record) => (record.recordingFileName ? [record.recordingFileName] : [])))
    const names = await this.listOrEmpty(this.recordingsDirectory)
    return names
      .filter((name) => pathExtension(name) === 'mp4' && !referenced.has(name))
      .map((name) => ({ name, path: this.storage.join(this.recordingsDirectory, name) }))
  }

  /** The record's video, when it has one and the file is still there. */
  async recordingFile(record: TrainingRecord): Promise<StoredFile | null> {
    const name = record.recordingFileName
    if (name === null) return null
    const path = this.storage.join(this.recordingsDirectory, name)
    return (await this.storage.exists(path)) ? { name, path } : null
  }

  logPath(record: TrainingRecord): string {
    return this.storage.join(this.sessionsDirectory, `${SessionStore.baseName(record)}.txt`)
  }

  jsonPath(record: TrainingRecord): string {
    return this.storage.join(this.sessionsDirectory, `${SessionStore.baseName(record)}.json`)
  }

  async save(record: TrainingRecord): Promise<void> {
    await this.storage.makeDirectory(this.sessionsDirectory)
    await this.storage.writeText(this.jsonPath(record), SessionStore.encodeRecord(record))
    await this.storage.writeText(this.logPath(record), SessionLogFormatter.text(record))
  }

  /** Every readable record, newest first; files that do not decode are skipped. */
  async loadAll(): Promise<TrainingRecord[]> {
    const names = (await this.listOrEmpty(this.sessionsDirectory)).filter((name) => pathExtension(name) === 'json')
    const records: TrainingRecord[] = []
    for (const name of names) {
      try {
        records.push(SessionStore.decodeRecord(await this.storage.readText(this.storage.join(this.sessionsDirectory, name))))
      } catch {
        // Not a record (or damaged): Swift's `try?` skips it too.
      }
    }
    return records.sort((a, b) => b.startedAt - a.startedAt)
  }

  async delete(record: TrainingRecord, includingRecording: boolean): Promise<void> {
    await this.removeQuietly(this.jsonPath(record))
    await this.removeQuietly(this.logPath(record))
    if (includingRecording) {
      const video = await this.recordingFile(record)
      if (video) await this.removeQuietly(video.path)
    }
  }

  // MARK: - Formats

  /** `JSONEncoder` with `[.prettyPrinted, .sortedKeys]` and `.iso8601` dates, as `save` writes it. */
  static encodeRecord(record: TrainingRecord): string {
    return swiftJSONString(TrainingRecord.encode(record, DISK_DATES), { pretty: true, sortedKeys: true })
  }

  /** Reads a `Sessions/*.json` file (throws `DecodingError` or `SyntaxError`). */
  static decodeRecord(text: string): TrainingRecord {
    return TrainingRecord.decode(JSON.parse(text), DISK_DATES)
  }

  /** "2026-09-25_18-00-1F0C8A2B": the file name of a record without the extension. */
  static baseName(record: TrainingRecord): string {
    return `${SessionStore.fileStamp(record.startedAt)}-${record.id.toUpperCase().slice(0, 8)}`
  }

  /** "yyyy-MM-dd_HH-mm" in local time (`en_US_POSIX`, the device's time zone). */
  static fileStamp(ms: number): string {
    const date = new Date(ms)
    const year = String(date.getFullYear()).padStart(4, '0')
    return `${year}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}_${pad2(date.getHours())}-${pad2(date.getMinutes())}`
  }

  // MARK: - Internals

  private async listOrEmpty(directory: string): Promise<string[]> {
    try {
      return await this.storage.list(directory)
    } catch {
      return []
    }
  }

  private async removeQuietly(path: string): Promise<void> {
    try {
      await this.storage.remove(path)
    } catch {
      // Already gone.
    }
  }
}

/** `URL.pathExtension`: the part after the last dot of the name ("" for ".hidden" and "name."). */
function pathExtension(name: string): string {
  const dot = name.lastIndexOf('.')
  return dot <= 0 ? '' : name.slice(dot + 1)
}
