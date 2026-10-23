// Port of SessionStoreTests.swift, plus the on-disk format shared with the Mac and iPhone apps.
import { beforeEach, describe, expect, it } from 'vitest'
import {
  PlannedExit,
  SessionStore,
  TrainingPlan,
  TrainingRecord,
  TrainingSession,
  setCoreLanguage,
} from '@core/index'
import { MemoryStorage } from './memoryStorage'

describe('SessionStore', () => {
  beforeEach(() => setCoreLanguage('ru'))

  it("recording names don't collide and standalone ones are listed", async () => {
    const storage = new MemoryStorage()
    const store = new SessionStore(storage, '/root')
    const plan = TrainingPlan.make({ title: 'Запись' })
    const date = 1_791_000_000_000

    const first = await store.newRecordingFile(plan, date)
    await storage.writeText(first.path, '\u0001')
    const second = await store.newRecordingFile(plan, date)
    expect(second.path).not.toBe(first.path)
    await storage.writeText(second.path, '\u0001')

    const record = TrainingRecord.make({
      plan,
      startedAt: date,
      finishedAt: date,
      events: [],
      results: [],
      recordingFileName: first.name,
    })
    expect((await store.standaloneRecordings([record])).map((file) => file.name)).toEqual([second.name])
  })

  it('names files like the Swift store', async () => {
    const storage = new MemoryStorage()
    const store = new SessionStore(storage, '/root')
    const start = new Date(2026, 8, 25, 18, 0, 59).getTime()
    const first = await store.newRecordingFile(TrainingPlan.make({ title: 'Тренировка на пятницу' }), start)
    expect(first.name).toBe('2026-09-25_18-00-trenirovka-na-patnicu.mp4')
    expect(first.path).toBe('/root/Recordings/2026-09-25_18-00-trenirovka-na-patnicu.mp4')
    await storage.writeText(first.path, '')
    expect((await store.newRecordingFile(TrainingPlan.make({ title: 'Тренировка на пятницу' }), start)).name).toBe(
      '2026-09-25_18-00-trenirovka-na-patnicu-2.mp4',
    )

    const record = TrainingRecord.make({
      id: '1f0c8a2b-0000-4000-8000-000000000000',
      plan: TrainingPlan.make(),
      startedAt: start,
      finishedAt: start,
      events: [],
      results: [],
    })
    expect(store.jsonPath(record)).toBe('/root/Sessions/2026-09-25_18-00-1F0C8A2B.json')
    expect(store.logPath(record)).toBe('/root/Sessions/2026-09-25_18-00-1F0C8A2B.txt')
  })

  it('saves, loads newest first, skips damaged files and deletes', async () => {
    const storage = new MemoryStorage()
    const store = new SessionStore(storage, '/root')
    await store.prepare()
    let now = 1_790_000_000_000
    const plan = TrainingPlan.make({ title: 'Тренировка', exits: [PlannedExit.make({ number: 1, duration: 5 })] })
    const records: TrainingRecord[] = []
    for (let i = 0; i < 2; i++) {
      const session = new TrainingSession(plan, { clock: () => now })
      session.startExit(); session.markBehindDoor(); now += 5_000; session.endExit(); session.finish()
      records.push(session.makeRecord(i === 0 ? 'a.mp4' : null))
      now += 3_600_000
    }
    for (const record of records) await store.save(record)
    await storage.writeText('/root/Sessions/broken.json', '{"id": 1}')
    await storage.writeText('/root/Recordings/a.mp4', '')

    const loaded = await store.loadAll()
    expect(loaded.map((r) => r.id)).toEqual([records[1].id, records[0].id])
    expect(loaded[1]).toEqual(records[0])
    expect(await storage.readText(store.logPath(records[0]))).toContain('1 выход — 5 с: за дверью 0:05 ✅')
    expect((await store.recordingFile(records[0]))?.path).toBe('/root/Recordings/a.mp4')

    await store.delete(records[0], true)
    expect(await storage.exists(store.jsonPath(records[0]))).toBe(false)
    expect(await storage.exists(store.logPath(records[0]))).toBe(false)
    expect(await storage.exists('/root/Recordings/a.mp4')).toBe(false)
    expect((await store.loadAll()).map((r) => r.id)).toEqual([records[1].id])
  })
})

// A record as the Swift app writes it: JSONEncoder, [.prettyPrinted, .sortedKeys], .iso8601 dates.
const swiftRecord = `{
  "events" : [
    {
      "id" : "0A3C7C55-6E7F-4B39-9F0B-6E2D0B2F1A10",
      "kind" : "sessionStarted",
      "time" : "2026-09-25T15:00:00Z"
    },
    {
      "attempt" : 1,
      "detail" : "план 2 с",
      "exitNumber" : 1,
      "id" : "5B1E2C1D-3A44-4F0E-8C55-7D1A2B3C4D5E",
      "kind" : "exitStarted",
      "time" : "2026-09-25T15:00:00Z"
    },
    {
      "detail" : "video\\/a.mp4",
      "id" : "6C2F3D2E-4B55-4011-9D66-8E2B3C4D5E6F",
      "kind" : "recordingStarted",
      "time" : "2026-09-25T15:00:01Z"
    }
  ],
  "finishedAt" : "2026-09-25T15:13:00Z",
  "id" : "1F0C8A2B-9E4D-4C3B-A2F1-0E9D8C7B6A59",
  "plan" : {
    "commonEarlyEntries" : [
      {
        "delay" : 30,
        "detail" : "от укладки",
        "event" : "Легла",
        "id" : "B17E8273-9AAA-4566-82BB-D3708192A3B4",
        "tone" : "green"
      }
    ],
    "date" : "2026-09-25T09:00:00Z",
    "defaultBreak" : 120,
    "exits" : [
      {
        "duration" : 2,
        "earlyEntries" : [],
        "id" : "7D3A4E3F-5C66-4122-AE77-9F3C4D5E6F70",
        "isOpen" : false,
        "number" : 1,
        "triggers" : [],
        "untilStanding" : false,
        "usesCommonEarlyEntries" : true
      },
      {
        "breakAfter" : 300,
        "duration" : 20,
        "earlyEntries" : [
          {
            "event" : "Встала",
            "id" : "C28F9384-ABBB-4677-93CC-E48192A3B4C5",
            "tone" : "yellow"
          }
        ],
        "id" : "8E4B5F40-6D77-4233-BF88-A04D5E6F7081",
        "isOpen" : false,
        "note" : "выйти и сразу вернуться",
        "number" : 2,
        "triggers" : [
          "куртка"
        ],
        "untilStanding" : true,
        "usesCommonEarlyEntries" : false
      }
    ],
    "id" : "9F5C6051-7E88-4344-8099-B15E6F708192",
    "notes" : [
      "Все перерывы 2 минуты"
    ],
    "rawText" : "1 выход - 2 секунды\\n2 выход - 20 секунд",
    "title" : "Тренировка на пятницу",
    "trainers" : "Андрей"
  },
  "recordingFileName" : "2026-09-25_18-00-trenirovka-na-patnicu.mp4",
  "results" : [
    {
      "actualBreak" : 128.5,
      "attempt" : 1,
      "endedAt" : "2026-09-25T15:00:04Z",
      "falseStart" : false,
      "id" : "A06D7162-8F99-4455-91AA-C26F708192A3",
      "isOpen" : false,
      "leftAt" : "2026-09-25T15:00:01Z",
      "number" : 1,
      "plannedBreak" : 120,
      "plannedDuration" : 2,
      "startedAt" : "2026-09-25T15:00:00Z",
      "untilStanding" : false
    }
  ],
  "startedAt" : "2026-09-25T15:00:00Z"
}`

describe('Sessions/*.json compatibility', () => {
  it('reads a record written by the Swift app', () => {
    const record = SessionStore.decodeRecord(swiftRecord)
    expect(record.id).toBe('1F0C8A2B-9E4D-4C3B-A2F1-0E9D8C7B6A59')
    expect(record.startedAt).toBe(Date.UTC(2026, 8, 25, 15, 0, 0))
    expect(record.plan.date).toBe(Date.UTC(2026, 8, 25, 9, 0, 0))
    expect(record.plan.exits[1]).toMatchObject({ breakAfter: 300, note: 'выйти и сразу вернуться', untilStanding: true })
    expect(record.plan.exits[0]).toMatchObject({ breakAfter: null, note: null })
    expect(record.plan.exits[1]).toMatchObject({ triggers: ['куртка'], usesCommonEarlyEntries: false })
    expect(record.plan.exits[1].earlyEntries[0]).toMatchObject({ event: 'Встала', delay: null, detail: null, tone: 'yellow' })
    expect(record.plan.commonEarlyEntries[0]).toMatchObject({ event: 'Легла', delay: 30, detail: 'от укладки', tone: 'green' })
    expect(record.events[1]).toMatchObject({ kind: 'exitStarted', exitNumber: 1, attempt: 1, detail: 'план 2 с' })
    expect(record.events[0]).toMatchObject({ exitNumber: null, attempt: null, detail: null })
    expect(record.events[2].detail).toBe('video/a.mp4')
    expect(record.results[0]).toMatchObject({ leftAt: Date.UTC(2026, 8, 25, 15, 0, 1), actualBreak: 128.5 })
    expect(record.plan.rawText).toBe('1 выход - 2 секунды\n2 выход - 20 секунд')
  })

  it('round-trips a Swift-style file byte for byte', () => {
    expect(SessionStore.encodeRecord(SessionStore.decodeRecord(swiftRecord))).toBe(swiftRecord)
  })

  it('writes whole seconds in UTC and upper-case ids', () => {
    const record = TrainingRecord.make({
      id: 'abcdef01-2345-4678-89ab-cdef01234567',
      plan: TrainingPlan.make({ id: '00000000-0000-4000-8000-000000000001' }),
      startedAt: Date.UTC(2026, 0, 2, 3, 4, 5) + 999,
      finishedAt: Date.UTC(2026, 0, 2, 3, 4, 6),
      events: [],
      results: [],
    })
    const json = JSON.parse(SessionStore.encodeRecord(TrainingRecord.decode(TrainingRecord.encode(record, 'iso8601'), 'iso8601')))
    expect(json.startedAt).toBe('2026-01-02T03:04:05Z')
    expect(json.id).toBe('ABCDEF01-2345-4678-89AB-CDEF01234567')
    expect('recordingFileName' in json).toBe(false)
    expect('date' in json.plan).toBe(false)
  })

  it('rejects records Swift would not decode', () => {
    const json = JSON.parse(swiftRecord)
    delete json.plan.rawText
    expect(() => SessionStore.decodeRecord(JSON.stringify(json))).toThrow(/plan\.rawText: missing key/)
    const badDate = JSON.parse(swiftRecord)
    badDate.startedAt = 1790000000
    expect(() => SessionStore.decodeRecord(JSON.stringify(badDate))).toThrow(/startedAt/)
  })
})
