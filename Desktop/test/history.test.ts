// History page logic (port of MacHistoryModel / MacHistoryProgress / MacHistoryExitStrip numbers).
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ExitResult, PlannedExit, SessionEvent, TrainingPlan, TrainingRecord, setCoreLanguage } from '@core/index'
import {
  buildRows,
  exitOffset,
  filterRows,
  fitColumns,
  foldForSearch,
  gridTemplate,
  keyOf,
  longestPlanned,
  longestStay,
  monotonePath,
  nearestIndex,
  neighbourAfterRemoval,
  nextSort,
  progress,
  recordingStart,
  rowDuration,
  rowEnd,
  scale,
  sortRows,
  stepPath,
  stripSegments,
  stripTicks,
  xAxisValues,
  yAxis,
  type ClipFile,
  type HistoryRow,
  type VideoInfo,
} from '../src/renderer/src/history/logic'

/// A training on `day` (local time) whose exits stayed `stays` seconds behind the door; `falseAt` adds a false
/// start before that exit.
function training(day: Date, stays: number[], options: { falseAt?: number; title?: string; trainers?: string; video?: string; recordingAt?: number } = {}): TrainingRecord {
  const start = day.getTime()
  const plan = TrainingPlan.make({
    title: options.title ?? 'Тренировка',
    trainers: options.trainers ?? '',
    exits: stays.map((duration, index) => PlannedExit.make({ number: index + 1, duration: Math.max(1, duration - 1) })),
  })
  let now = start
  const results: ExitResult[] = []
  stays.forEach((stay, index) => {
    if (options.falseAt === index) {
      results.push(ExitResult.make({ number: index + 1, attempt: 1, plannedDuration: stay, untilStanding: false, startedAt: now, leftAt: now + 5000, endedAt: now + 8000, falseStart: true, plannedBreak: 120, actualBreak: 60 }))
      now += 68_000
    }
    const attempt = options.falseAt === index ? 2 : 1
    results.push(ExitResult.make({ number: index + 1, attempt, plannedDuration: stay, untilStanding: false, startedAt: now, leftAt: now + 5000, endedAt: now + 5000 + stay * 1000, falseStart: false, plannedBreak: 120, actualBreak: 120 }))
    now += 5000 + stay * 1000 + 120_000
  })
  const events = options.recordingAt !== undefined ? [SessionEvent.make({ time: start + options.recordingAt * 1000, kind: 'recordingStarted', detail: options.video ?? null })] : []
  return TrainingRecord.make({ plan, startedAt: start, finishedAt: now, events, results, recordingFileName: options.video ?? null })
}

describe('History', () => {
  beforeEach(() => setCoreLanguage('ru'))
  afterEach(() => setCoreLanguage('ru'))

  it('counts the longest stay without false starts and the plan', () => {
    const record = training(new Date(2026, 8, 6, 18, 4), [10, 30, 15], { falseAt: 1 })
    expect(longestStay(record)).toBe(30)
    expect(longestPlanned(record)).toBe(29)
    // The false start (3 s away) is not a record.
    const onlyFalse = training(new Date(2026, 8, 6, 18, 4), [0], { falseAt: 0 })
    expect(longestStay(onlyFalse)).toBe(0)
  })

  it('offsets exits from the start of the recording', () => {
    const record = training(new Date(2026, 9, 2, 18, 36), [10, 20], { video: 'a.mp4', recordingAt: 3 })
    expect(recordingStart(record)).toBe(record.startedAt + 3000)
    expect(exitOffset(record, record.results[0])).toBe(0)
    expect(exitOffset(record, record.results[1])).toBe((record.results[1].startedAt - record.startedAt - 3000) / 1000)
    // Without a «Запись включена» event the training's start is the video's.
    expect(recordingStart(training(new Date(2026, 9, 2), [5]))).toBe(new Date(2026, 9, 2).getTime())
  })

  it('builds rows for trainings and clips, hiding missing videos', () => {
    const withVideo = training(new Date(2026, 9, 2, 18, 0), [10], { video: 'a.mp4' })
    const gone = training(new Date(2026, 9, 1, 18, 0), [10], { video: 'gone.mp4' })
    const clip: ClipFile = { fileName: 'clip.mp4', date: new Date(2026, 9, 3, 12, 0).getTime(), size: 1000 }
    const videos = new Map<string, VideoInfo>([
      ['gone.mp4', { fileName: 'gone.mp4', exists: false, bytes: null, duration: null }],
      ['clip.mp4', { fileName: 'clip.mp4', exists: true, bytes: 2000, duration: 65 }],
    ])
    const rows = buildRows([withVideo, gone], [clip], videos, 'Запись без тренировки')
    expect(rows.map((row) => row.kind)).toEqual(['record', 'record', 'clip'])
    expect(rows[0].video?.fileName).toBe('a.mp4')
    expect(rows[1].video).toBeNull()
    expect(rows[2].title).toBe('Запись без тренировки')
    expect(rows[2].video?.bytes).toBe(2000)
    expect(rowDuration(rows[2])).toBe(65)
    expect(rowEnd(rows[2])).toBe(clip.date + 65_000)
    expect(keyOf(rows[2])).toBe('clip:clip.mp4')
  })

  it('filters by scope and searches title, trainers, file and date', () => {
    const rows = buildRows(
      [training(new Date(2026, 9, 2, 18, 36), [10], { title: 'Тренировка на пятницу', trainers: 'Таня / Андрей' }), training(new Date(2026, 8, 30, 19, 12), [10], { title: 'Тренировка на среду', trainers: 'Андрей' })],
      [{ fileName: '2026-10-04_19-53.mp4', date: new Date(2026, 9, 4, 19, 53).getTime(), size: 1 }],
      new Map(),
      'Запись без тренировки',
    )
    expect(filterRows(rows, 'all', '').length).toBe(3)
    expect(filterRows(rows, 'trainings', '').length).toBe(2)
    expect(filterRows(rows, 'clips', '').map((row) => row.kind)).toEqual(['clip'])
    expect(filterRows(rows, 'all', 'таня').length).toBe(1)
    expect(filterRows(rows, 'all', '  ПЯТНИЦ ').length).toBe(1)
    expect(filterRows(rows, 'all', '19-53').length).toBe(1)
    expect(filterRows(rows, 'all', 'сент').length).toBe(1)
    expect(filterRows(rows, 'trainings', '19-53').length).toBe(0)
    expect(foldForSearch('Ёлка')).toBe('елка')
  })

  it('sorts by any column, trainings before recordings without a log', () => {
    const a = training(new Date(2026, 9, 2, 18, 36), [150], { title: 'Б' })
    const b = training(new Date(2026, 8, 30, 9, 12), [30, 60], { title: 'а', falseAt: 0 })
    const rows = buildRows([a, b], [{ fileName: 'c.mp4', date: new Date(2026, 9, 4).getTime(), size: 5 }], new Map(), 'Запись')
    const order = (key: Parameters<typeof nextSort>[1], descending: boolean) => sortRows(rows, { key, descending }).map((row) => row.id)
    expect(order('date', true)).toEqual(['c.mp4', a.id, b.id])
    expect(order('longest', true)).toEqual([a.id, b.id, 'c.mp4'])
    expect(order('falseStarts', true)).toEqual([b.id, a.id, 'c.mp4'])
    expect(order('start', false)).toEqual(['c.mp4', b.id, a.id])
    expect(sortRows(rows, { key: 'title', descending: false }, 'ru').map((row) => row.title)).toEqual(['а', 'Б', 'Запись'])
    expect(nextSort({ key: 'date', descending: true }, 'date')).toEqual({ key: 'date', descending: false })
    expect(nextSort({ key: 'date', descending: true }, 'longest')).toEqual({ key: 'longest', descending: true })
    expect(nextSort({ key: 'date', descending: true }, 'title')).toEqual({ key: 'title', descending: false })
  })

  it('hands the selection to the next row after a delete', () => {
    const rows = [1, 2, 3].map((n) => ({ kind: 'clip', id: String(n) }) as HistoryRow)
    expect(neighbourAfterRemoval(rows, 'clip:2')?.id).toBe('3')
    expect(neighbourAfterRemoval(rows, 'clip:3')?.id).toBe('2')
    expect(neighbourAfterRemoval([rows[0]], 'clip:1')).toBeNull()
    expect(neighbourAfterRemoval(rows, 'clip:9')).toBeNull()
  })

  it('computes the progress figures of a period', () => {
    const records = [
      training(new Date(2026, 8, 6, 18, 4), [5, 7], { falseAt: 1 }),
      training(new Date(2026, 8, 20, 12, 30), [30, 46]),
      training(new Date(2026, 9, 2, 18, 36), [60, 152], { falseAt: 0 }),
    ]
    const all = progress(records, 'all')
    expect(all.sessions.map((record) => record.id)).toEqual(records.map((record) => record.id))
    expect(all.best?.id).toBe(records[2].id)
    expect(all.includesFirstTraining).toBe(true)
    expect(all.gain).toBe(152 - 7)
    expect(all.cleanCount).toBe(1)
    expect(all.falseStartTotal).toBe(2)

    // Four weeks back from the newest training's day: Sep 4 onwards.
    const month = progress(records, 'fourWeeks')
    expect(month.sessions.length).toBe(3)
    expect(month.domain[0]).toBe(new Date(2026, 8, 4).getTime())
    // Half a day past the newest training (Oct 2, 18:36).
    expect(month.domain[1]).toBe(new Date(2026, 9, 3, 6, 36).getTime())

    const later = [...records, training(new Date(2026, 10, 15, 10, 0), [100])]
    const recent = progress(later, 'fourWeeks')
    expect(recent.sessions.length).toBe(1)
    expect(recent.includesFirstTraining).toBe(false)
    expect(recent.gain).toBeNull()
    expect(recent.best?.id).toBe(records[2].id)

    const empty = progress([], 'all')
    expect(empty.sessions).toEqual([])
    expect(empty.best).toBeNull()
    expect(empty.gain).toBeNull()
  })

  it('picks round steps for the y axis', () => {
    expect(yAxis([training(new Date(2026, 9, 2), [152])])).toEqual({ max: 180, step: 30 })
    expect(yAxis([training(new Date(2026, 9, 2), [11])])).toEqual({ max: 15, step: 5 })
    expect(yAxis([])).toEqual({ max: 10, step: 5 })
    expect(yAxis([training(new Date(2026, 9, 2), [3000])])).toEqual({ max: 3600, step: 600 })
  })

  it('places date labels by the length of the range', () => {
    const start = new Date(2026, 8, 4).getTime()
    const end = new Date(2026, 9, 3).getTime()
    const values = xAxisValues([start, end])
    expect(values[0]).toBe(new Date(2026, 8, 4).getTime())
    expect(new Date(values[1]).getDate()).toBe(8)
    expect(values.every((value) => value <= end - 29 * 86_400_000 * 0.06)).toBe(true)
    const quarter = xAxisValues([new Date(2026, 6, 1).getTime(), new Date(2026, 9, 1).getTime()])
    expect(new Date(quarter[1]).getTime() - new Date(quarter[0]).getTime()).toBe(14 * 86_400_000)
    const year = xAxisValues([new Date(2025, 9, 1).getTime(), new Date(2026, 9, 1).getTime()])
    expect(new Date(year[1]).getMonth() - new Date(year[0]).getMonth()).toBe(2)
  })

  it('scales and draws lines without overshooting', () => {
    const x = scale([0, 10], [100, 200])
    expect(x(5)).toBe(150)
    expect(scale([5, 5], [0, 10])(5)).toBe(0)
    expect(monotonePath([])).toBe('')
    expect(monotonePath([[0, 10]])).toBe('M0,10')
    expect(monotonePath([[0, 10], [10, 0]])).toBe('M0,10L10,0')
    const path = monotonePath([[0, 100], [10, 50], [20, 50], [30, 0]])
    // Control points never go above the flat middle part (no bump between equal values).
    const numbers = path.match(/-?\d+(\.\d+)?/g)!.map(Number)
    const ys = numbers.filter((_, index) => index % 2 === 1)
    expect(Math.min(...ys)).toBeGreaterThanOrEqual(0)
    expect(path.split('C').length - 1).toBe(3)
    expect(path).toContain('C13.3,50,16.7,50,20,50')
    expect(stepPath([[0, 5], [10, 3], [20, 4]])).toBe('M0,5H10V3H20V4')
    expect(nearestIndex([10, 50, 90], 55)).toBe(1)
    expect(nearestIndex([10, 50, 90], 72)).toBe(2)
    expect(nearestIndex([10, 50, 90], 120)).toBeNull()
    expect(nearestIndex([], 5)).toBeNull()
  })

  it('lays exits along the recording', () => {
    const record = training(new Date(2026, 9, 2, 18, 0), [10, 20], { falseAt: 1, video: 'a.mp4', recordingAt: 2 })
    const base = recordingStart(record)
    const segments = stripSegments(record, base, 1000)
    expect(segments.filter((segment) => segment.kind === 'away').map((segment) => segment.exit)).toEqual([1, 2])
    expect(segments.filter((segment) => segment.kind === 'falseStart').length).toBe(1)
    const first = segments[0]
    expect(first.kind).toBe('walk')
    expect(first.start).toBe(-2)
    expect(first.jump).toBe(0)
    const away = segments.find((segment) => segment.kind === 'falseStart')!
    expect(away.jump).toBe(exitOffset(record, record.results[1]))
    // A video that ends early cuts the strip.
    expect(stripSegments(record, base, 10).every((segment) => segment.start < 10)).toBe(true)
  })

  it('labels the strip on round minutes', () => {
    const base = new Date(2026, 9, 2, 18, 36, 20).getTime()
    const ticks = stripTicks(base, 26 * 60, 330)
    expect(ticks.length).toBeGreaterThan(2)
    for (const offset of ticks) expect(new Date(base + offset * 1000).getMinutes() % 5).toBe(0)
    expect(stripTicks(base, 8, 330)).toEqual([])
    expect(stripTicks(base, 0, 330)).toEqual([])
  })

  it('drops the least important columns first', () => {
    const columns = [
      { key: 'date', width: 100, priority: 0 },
      { key: 'start', width: 50, priority: 6 },
      { key: 'title', min: 100, flex: 2, priority: 0 },
      { key: 'trainers', min: 80, flex: 1, priority: 5 },
      { key: 'plan', width: 50, priority: 3 },
      { key: 'video', width: 50, priority: 3 },
    ]
    expect(fitColumns(columns, 1000).length).toBe(6)
    expect(fitColumns(columns, 400).map((column) => column.key)).toEqual(['date', 'title', 'trainers', 'plan', 'video'])
    expect(fitColumns(columns, 300).map((column) => column.key)).toEqual(['date', 'title', 'plan', 'video'])
    expect(fitColumns(columns, 299).map((column) => column.key)).toEqual(['date', 'title', 'plan'])
    expect(fitColumns(columns, 10).map((column) => column.key)).toEqual(['date', 'title'])
    expect(gridTemplate(fitColumns(columns, 299))).toBe('100px minmax(100px, 2fr) 50px')
  })

})
