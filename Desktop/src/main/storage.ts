import { mkdir, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import { existsSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { SessionStore, type StorageBackend } from '@core/sessionStore'
import type { TrainingPlan } from '@core/models'
import type { TrainingRecord } from '@core/sessionLog'

/// node:fs for the core's `StorageBackend` (sessions, logs, MIoT spec cache).
export const nodeStorage: StorageBackend = {
  join: (...segments) => join(...segments),
  readText: (path) => readFile(path, 'utf8'),
  async writeText(path, text) {
    const temp = `${path}.${process.pid}.tmp`
    await writeFile(temp, text, 'utf8')
    await rename(temp, path)
  },
  async list(directory) {
    try {
      return await readdir(directory)
    } catch {
      return []
    }
  },
  exists: async (path) => existsSync(path),
  remove: (path) => rm(path, { force: true }),
  makeDirectory: async (path) => {
    await mkdir(path, { recursive: true })
  },
  async modifiedAt(path) {
    try {
      return (await stat(path)).mtimeMs
    } catch {
      return null
    }
  },
}

/// The history on disk: `Documents\Waiting Paws\Sessions` and `\Recordings`, same files as the Mac app.
export class RecordStore {
  readonly store: SessionStore

  constructor(root: string) {
    this.store = new SessionStore(nodeStorage, root)
    mkdirSync(this.store.sessionsDirectory, { recursive: true })
    mkdirSync(this.store.recordingsDirectory, { recursive: true })
  }

  get sessionsDirectory(): string {
    return this.store.sessionsDirectory
  }

  get recordingsDirectory(): string {
    return this.store.recordingsDirectory
  }

  loadAll(): Promise<TrainingRecord[]> {
    return this.store.loadAll()
  }

  save(record: TrainingRecord): Promise<void> {
    return this.store.save(record)
  }

  delete(record: TrainingRecord, includingRecording: boolean): Promise<void> {
    return this.store.delete(record, includingRecording)
  }

  async newRecordingPath(plan: TrainingPlan): Promise<string> {
    return (await this.store.newRecordingFile(plan)).path
  }

  /// Names of recordings no saved session refers to.
  async standaloneRecordings(records: readonly TrainingRecord[]): Promise<string[]> {
    return (await this.store.standaloneRecordings(records)).map((file) => file.name)
  }

  logPathFor(record: TrainingRecord | undefined): string | null {
    return record ? this.store.logPath(record) : null
  }
}
