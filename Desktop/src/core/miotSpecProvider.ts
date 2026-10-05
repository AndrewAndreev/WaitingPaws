// Port of `MiotSpecProvider` (Xiaomi/CameraModes.swift), split out because it does IO.
//
// Downloads device specs from miot-spec.org (public, no account) and keeps them on disk:
// a model's settings never change, the 2 MB model index is refreshed monthly.

import { type CameraModeOption, MiotSpec } from './cameraModes'
import { Go2RTCError } from './go2rtcClient'
import { type StorageBackend } from './sessionStore'

const maxAge = 30 * 24 * 3600 * 1000
const base = 'https://miot-spec.org/miot-spec-v2/'

export interface MiotSpecProviderOptions {
  /** Where specs are cached (`Caches/MiotSpec` on the Mac). */
  cacheDirectory: string
  storage: StorageBackend
  fetch?: typeof globalThis.fetch
  /** Epoch ms; for tests. */
  now?: () => number
}

export class MiotSpecProvider {
  private readonly memory = new Map<string, CameraModeOption[]>()
  /** Swift's actor serialises calls; here concurrent requests for one model share the download. */
  private readonly pending = new Map<string, Promise<CameraModeOption[]>>()
  private readonly fetchImpl: typeof globalThis.fetch
  private readonly now: () => number

  constructor(private readonly options: MiotSpecProviderOptions) {
    this.fetchImpl = options.fetch ?? ((input, init) => globalThis.fetch(input, init))
    this.now = options.now ?? Date.now
  }

  /** Camera settings `model` (e.g. `xiaomi.camera.c302n`) declares; empty when the model has no published spec. */
  cameraModes(model: string): Promise<CameraModeOption[]> {
    const cached = this.memory.get(model)
    if (cached) return Promise.resolve(cached)
    let task = this.pending.get(model)
    if (!task) {
      task = this.load(model).finally(() => this.pending.delete(model))
      this.pending.set(model, task)
    }
    return task
  }

  private async load(model: string): Promise<CameraModeOption[]> {
    const { storage, cacheDirectory } = this.options
    const file = storage.join(cacheDirectory, MiotSpecProvider.fileName(model) + '.json')
    const cachedText = await this.readQuietly(file)
    if (cachedText !== null) {
      try {
        const options = MiotSpec.cameraModes(cachedText)
        this.memory.set(model, options)
        return options
      } catch {
        // Damaged cache: download again.
      }
    }
    const type = await this.specType(model)
    if (type === null) {
      this.memory.set(model, [])
      return []
    }
    const text = await this.download(`${base}instance?type=${encodeURIComponent(type)}`)
    const options = MiotSpec.cameraModes(text)
    await this.writeQuietly(file, text)
    this.memory.set(model, options)
    return options
  }

  private async specType(model: string): Promise<string | null> {
    const { storage, cacheDirectory } = this.options
    const file = storage.join(cacheDirectory, 'instances.json')
    const cached = await this.readQuietly(file)
    let age = Infinity
    if (cached !== null && storage.modifiedAt) {
      const modified = await storage.modifiedAt(file).catch(() => null)
      if (modified !== null) age = this.now() - modified
    }
    const fromCache = (): string | null => {
      try {
        return cached === null ? null : MiotSpec.specType(model, cached)
      } catch {
        return null
      }
    }
    // A fresh index that knows the model; a new model may need a newer index, but not more than daily.
    if (cached !== null && age < maxAge) {
      const type = fromCache()
      if (type !== null) return type
    }
    if (cached !== null && age < 24 * 3600 * 1000) return null
    try {
      const text = await this.download(`${base}instances?status=released`)
      const type = MiotSpec.specType(model, text)
      await this.writeQuietly(file, text)
      return type
    } catch (error) {
      const type = fromCache()
      if (type !== null) return type
      throw error
    }
  }

  private async download(url: string): Promise<string> {
    let response: Response
    try {
      response = await this.fetchImpl(url)
    } catch (error) {
      throw Go2RTCError.network(error instanceof Error ? error.message : String(error), error)
    }
    if (response.status < 200 || response.status >= 300) throw Go2RTCError.http(response.status, 'miot-spec.org')
    return response.text()
  }

  private async readQuietly(path: string): Promise<string | null> {
    try {
      return await this.options.storage.readText(path)
    } catch {
      return null
    }
  }

  private async writeQuietly(path: string, text: string): Promise<void> {
    try {
      await this.options.storage.makeDirectory(this.options.cacheDirectory)
      await this.options.storage.writeText(path, text)
    } catch {
      // A cache only.
    }
  }

  /** Cache file name of a model: letters, digits, "." and "-" stay, the rest becomes "_". */
  static fileName(model: string): string {
    return Array.from(model, (char) => (/^[\p{L}\p{N}.-]$/u.test(char) ? char : '_')).join('')
  }
}
