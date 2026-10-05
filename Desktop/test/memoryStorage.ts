// An in-memory `StorageBackend` for the tests ('/'-separated paths).
import type { StorageBackend } from '@core/index'

export class MemoryStorage implements StorageBackend {
  readonly files = new Map<string, { text: string; modified: number }>()
  readonly directories = new Set<string>()
  now = 0

  join(...segments: string[]): string {
    return segments.join('/').replace(/\/+/g, '/')
  }

  async readText(path: string): Promise<string> {
    const file = this.files.get(path)
    if (!file) throw new Error(`ENOENT: ${path}`)
    return file.text
  }

  async writeText(path: string, text: string): Promise<void> {
    this.files.set(path, { text, modified: this.now })
  }

  async list(directory: string): Promise<string[]> {
    const prefix = directory.endsWith('/') ? directory : directory + '/'
    const names = new Set<string>()
    for (const path of [...this.files.keys(), ...this.directories]) {
      if (path.startsWith(prefix)) names.add(path.slice(prefix.length).split('/')[0])
    }
    return [...names].sort()
  }

  async exists(path: string): Promise<boolean> {
    return this.files.has(path) || this.directories.has(path)
  }

  async remove(path: string): Promise<void> {
    if (!this.files.delete(path)) throw new Error(`ENOENT: ${path}`)
  }

  async makeDirectory(path: string): Promise<void> {
    this.directories.add(path)
  }

  async modifiedAt(path: string): Promise<number | null> {
    return this.files.get(path)?.modified ?? null
  }
}
