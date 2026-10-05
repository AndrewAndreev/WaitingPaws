import { appendFileSync, mkdirSync, readdirSync, statSync, unlinkSync } from 'node:fs'
import { join } from 'node:path'
import { format } from 'node:util'

/// The app's own log: everything printed by the main process and go2rtc goes to
/// `%APPDATA%\Waiting Paws\Logs\waitingpaws-<date>.log`; the last 5 runs are kept. Passwords in URLs
/// (`rtsp://user:pass@…`, `xiaomi://id:token@…`) are masked before anything reaches the file.
let logFile: string | null = null
const listeners = new Set<(line: string) => void>()

export function maskSecrets(text: string): string {
  return text
    .replace(/([a-z][a-z0-9+.-]*:\/\/[^/\s:@]+):[^@\s/]+@/gi, '$1:***@')
    .replace(/("?(?:password|token|ssecurity|passToken|serviceToken)"?\s*[:=]\s*"?)[^"\s,&}]+/gi, '$1***')
}

export function startLog(directory: string): string {
  mkdirSync(directory, { recursive: true })
  const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19)
  logFile = join(directory, `waitingpaws-${stamp}.log`)
  // Keep the newest 5 runs.
  try {
    const old = readdirSync(directory)
      .filter((name) => name.startsWith('waitingpaws-') && name.endsWith('.log'))
      .map((name) => ({ name, time: statSync(join(directory, name)).mtimeMs }))
      .sort((a, b) => b.time - a.time)
      .slice(4)
    for (const file of old) unlinkSync(join(directory, file.name))
  } catch {
    // A locked or vanished file is not worth failing the start over.
  }
  const original = { log: console.log, warn: console.warn, error: console.error }
  for (const level of ['log', 'warn', 'error'] as const) {
    console[level] = (...args: unknown[]) => {
      original[level](...args)
      write(format(...args))
    }
  }
  return logFile
}

export function write(text: string): void {
  const masked = maskSecrets(text)
  for (const listener of listeners) listener(masked)
  if (!logFile) return
  try {
    appendFileSync(logFile, masked.endsWith('\n') ? masked : masked + '\n')
  } catch {
    // The log must never take the app down.
  }
}

export function currentLogFile(): string | null {
  return logFile
}

export function onLogLine(listener: (line: string) => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/// "12:03:30" for log lines.
export function clock(date = new Date()): string {
  return date.toLocaleTimeString('en-GB', { hour12: false })
}
