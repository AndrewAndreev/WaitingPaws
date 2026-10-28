// The bundled go2rtc's restart after a crash (EmbeddedGo2RTC), with Node standing in for go2rtc.exe: it refuses
// go2rtc's arguments and exits at once, as a go2rtc that crashes right after starting.
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { EmbeddedGo2RTC } from '../src/main/go2rtc'

const root = mkdtempSync(join(tmpdir(), 'wp-go2rtc-'))
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

function until(condition: () => boolean, timeout = 4000): Promise<void> {
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

/// A go2rtc that crashes on every start, and the LAN passwords it was started with.
function crashingGo2RTC(): { go2rtc: EmbeddedGo2RTC; passwords: (string | null)[] } {
  const go2rtc = new EmbeddedGo2RTC(process.execPath, join(root, 'go2rtc.yaml'))
  const passwords: (string | null)[] = []
  const overrides = go2rtc.overrides.bind(go2rtc)
  go2rtc.overrides = (password) => {
    passwords.push(password)
    return overrides(password)
  }
  return { go2rtc, passwords }
}

describe('EmbeddedGo2RTC after a crash', () => {
  afterAll(() => rmSync(root, { recursive: true, force: true }))

  it('a stop while the restart waits keeps it stopped', async () => {
    const { go2rtc, passwords } = crashingGo2RTC()
    await go2rtc.start('old')
    await until(() => go2rtc.status.kind === 'idle')
    // The restart is a second away: the API still counts as open to the LAN (a forgotten iPhone restarts it).
    expect(go2rtc.isOpenToLAN).toBe(true)
    await go2rtc.stop()
    expect(go2rtc.isOpenToLAN).toBe(false)
    await sleep(1300)
    expect(passwords).toEqual(['old'])
    expect(go2rtc.status.kind).toBe('idle')
  })

  it('a restart while it waits uses the new password, and so do the next tries', async () => {
    const { go2rtc, passwords } = crashingGo2RTC()
    await go2rtc.start('old')
    await until(() => go2rtc.status.kind === 'idle')
    await go2rtc.restart('new')
    expect(passwords).toEqual(['old', 'new'])
    // That one crashes too: the next try, 2 s later, is the only one (the first wait was cancelled).
    await until(() => passwords.length === 3, 5000)
    await go2rtc.stop()
    expect(passwords).toEqual(['old', 'new', 'new'])
  })
})
