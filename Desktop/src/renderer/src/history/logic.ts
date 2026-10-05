// Pure logic of the History page (port of MacHistoryModel / MacHistoryProgress / MacHistoryExitStrip numbers):
// one row type for trainings and recordings, filtering, sorting, the progress figures and the chart's scales.
// No React, no window: unit-tested in test/history.test.ts.
import { ExitResult, type TrainingRecord } from '@core/sessionLog'
import { formatDate } from '@core/localization'

const DAY = 86_400_000
const HOUR = 3_600_000

// MARK: - Rows

export type HistoryKind = 'record' | 'clip'
export type Scope = 'all' | 'trainings' | 'clips'
export type Period = 'fourWeeks' | 'threeMonths' | 'all'

/// A recording without a training (as `history.list` returns it).
export interface ClipFile {
  fileName: string
  date: number
  size: number
}

/// What is known about a video file. `exists: null` — not checked yet; sizes and lengths arrive later.
export interface VideoInfo {
  fileName: string
  exists: boolean | null
  bytes: number | null
  /// Seconds; `null` until the file's metadata is read.
  duration: number | null
}

/// One line of the table: a training (its log, maybe with a video) or a recording made without one.
export interface HistoryRow {
  kind: HistoryKind
  /// Record id or clip file name (what `historySelection.id` holds).
  id: string
  record: TrainingRecord | null
  clip: ClipFile | null
  /// The video, if its file is (or may be) on disk.
  video: VideoInfo | null
  date: number
  title: string
  trainers: string
}

export function rowKey(kind: HistoryKind, id: string): string {
  return `${kind}:${id}`
}

export function keyOf(row: Pick<HistoryRow, 'kind' | 'id'>): string {
  return rowKey(row.kind, row.id)
}

// MARK: - Record numbers

/// Longest successful stay behind the door, seconds (false starts don't count).
export function longestStay(record: TrainingRecord): number {
  let best = 0
  for (const result of record.results) if (!result.falseStart) best = Math.max(best, ExitResult.awayDuration(result))
  return best
}

/// Longest exit in the trainer's plan, seconds.
export function longestPlanned(record: TrainingRecord): number {
  return record.plan.exits.reduce((best, exit) => Math.max(best, exit.duration), 0)
}

export function completedExits(record: TrainingRecord): number {
  return record.results.filter((result) => !result.falseStart).length
}

export function falseStarts(record: TrainingRecord): number {
  return record.results.filter((result) => result.falseStart).length
}

/// Seconds.
export function recordDuration(record: TrainingRecord): number {
  return (record.finishedAt - record.startedAt) / 1000
}

/// When the recording of this training began: its «Запись включена» event (the one naming its file, else the
/// first), else the start of the training. Offsets into the video are `time − recordingStart`.
export function recordingStart(record: TrainingRecord): number {
  const starts = record.events.filter((event) => event.kind === 'recordingStarted')
  const own = starts.find((event) => event.detail !== null && event.detail === record.recordingFileName) ?? starts[0]
  return own?.time ?? record.startedAt
}

/// Seconds into the recording where an exit begins (never negative).
export function exitOffset(record: TrainingRecord, result: ExitResult): number {
  return Math.max(0, (result.startedAt - recordingStart(record)) / 1000)
}

// MARK: - Building rows

/// Every training and recording, unsorted. A training's video is listed only once its file is known to exist
/// (or while that is still being checked); clips are files by definition.
export function buildRows(records: readonly TrainingRecord[], clips: readonly ClipFile[], videos: ReadonlyMap<string, VideoInfo>, untitled: string): HistoryRow[] {
  const rows: HistoryRow[] = []
  for (const record of records) {
    const name = record.recordingFileName
    const info = name ? videos.get(name) ?? { fileName: name, exists: null, bytes: null, duration: null } : null
    rows.push({
      kind: 'record',
      id: record.id,
      record,
      clip: null,
      video: info && info.exists !== false ? info : null,
      date: record.startedAt,
      title: record.plan.title.trim(),
      trainers: record.plan.trainers,
    })
  }
  for (const clip of clips) {
    const info = videos.get(clip.fileName)
    rows.push({
      kind: 'clip',
      id: clip.fileName,
      record: null,
      clip,
      video: { fileName: clip.fileName, exists: true, bytes: info?.bytes ?? clip.size, duration: info?.duration ?? null },
      date: clip.date,
      title: untitled,
      trainers: '',
    })
  }
  return rows
}

/// Seconds: the training's, else the video's length; −1 when unknown (sorts after everything).
export function rowDuration(row: HistoryRow): number {
  if (row.record) return recordDuration(row.record)
  return row.video?.duration ?? -1
}

/// End of the training or of the recording (for "19:12–19:30"); null while a recording's length is unknown.
export function rowEnd(row: HistoryRow): number | null {
  if (row.record) return row.record.finishedAt
  const duration = row.video?.duration
  return duration !== null && duration !== undefined && Number.isFinite(duration) ? row.date + duration * 1000 : null
}

// MARK: - Filtering

/// Case- and diacritic-insensitive text for search (`localizedStandardContains`): «ё» matches «е».
export function foldForSearch(text: string): string {
  return text.normalize('NFD').replace(/\p{M}+/gu, '').toLocaleLowerCase()
}

/// Everything the search field looks at: title, trainers, file name and the date in several spellings.
export function searchText(row: HistoryRow): string {
  return [
    row.title,
    row.trainers,
    row.video?.fileName ?? '',
    formatDate(row.date, 'EEdMMM'),
    formatDate(row.date, 'EEEEdMMMM'),
    formatDate(row.date, 'ddMMyyyy'),
    formatDate(row.date, 'jmm'),
  ].join(' ')
}

export function filterRows(rows: readonly HistoryRow[], scope: Scope, query: string): HistoryRow[] {
  const needle = foldForSearch(query.trim())
  return rows.filter((row) => {
    if (scope === 'trainings' && row.kind !== 'record') return false
    if (scope === 'clips' && row.kind !== 'clip') return false
    return needle === '' || foldForSearch(searchText(row)).includes(needle)
  })
}

// MARK: - Sorting

export type SortKey = 'date' | 'start' | 'title' | 'trainers' | 'exits' | 'falseStarts' | 'longest' | 'plan' | 'duration' | 'video'

export interface Sort {
  key: SortKey
  descending: boolean
}

export const defaultSort: Sort = { key: 'date', descending: true }

/// Text columns start A→Z, numbers and dates start with the biggest (the longest stay, the newest training).
export function nextSort(current: Sort, key: SortKey): Sort {
  if (current.key === key) return { key, descending: !current.descending }
  return { key, descending: key !== 'title' && key !== 'trainers' }
}

/// Minutes since midnight (sorting by the start time of day).
function startMinute(ms: number): number {
  const date = new Date(ms)
  return date.getHours() * 60 + date.getMinutes()
}

/// Sort value of a row; −1 puts recordings without a log after the trainings (as on the Mac).
export function sortValue(row: HistoryRow, key: SortKey): number | string {
  const record = row.record
  switch (key) {
    case 'date':
      return row.date
    case 'start':
      return startMinute(row.date)
    case 'title':
      return row.title
    case 'trainers':
      return row.trainers
    case 'exits':
      return record ? completedExits(record) : -1
    case 'falseStarts':
      return record ? falseStarts(record) : -1
    case 'longest':
      return record ? longestStay(record) : -1
    case 'plan':
      return record ? longestPlanned(record) : -1
    case 'duration':
      return rowDuration(row)
    case 'video':
      return row.video ? row.video.bytes ?? 0 : -1
  }
}

export function sortRows(rows: readonly HistoryRow[], sort: Sort, locale?: string): HistoryRow[] {
  const collator = new Intl.Collator(locale, { sensitivity: 'base', numeric: true })
  const direction = sort.descending ? -1 : 1
  return [...rows].sort((a, b) => {
    const x = sortValue(a, sort.key)
    const y = sortValue(b, sort.key)
    const order = typeof x === 'string' && typeof y === 'string' ? collator.compare(x, y) : (x as number) - (y as number)
    // Ties: newest first, whatever the column.
    return order !== 0 ? order * direction : b.date - a.date
  })
}

/// The row that takes over the selection when `removed` goes away: the next one, or the previous at the end.
export function neighbourAfterRemoval(visible: readonly HistoryRow[], removedKey: string): HistoryRow | null {
  const index = visible.findIndex((row) => keyOf(row) === removedKey)
  if (index < 0) return null
  const rest = visible.filter((row) => keyOf(row) !== removedKey)
  return rest.length ? rest[Math.min(index, rest.length - 1)] : null
}

// MARK: - Columns

export interface ColumnSpec<K extends string = string> {
  key: K
  /// Fixed width, px.
  width?: number
  /// Minimum width of a flexible column, px.
  min?: number
  /// Share of the remaining width.
  flex?: number
  /// 0 always stays; higher numbers are hidden first when the table is narrow.
  priority: number
}

/// The columns that fit `width` (dropping the least important ones first), in their order.
export function fitColumns<C extends ColumnSpec>(columns: readonly C[], width: number): C[] {
  let visible = [...columns]
  const need = (list: readonly C[]) => list.reduce((sum, column) => sum + (column.width ?? column.min ?? 0), 0)
  while (need(visible) > width) {
    const candidates = visible.filter((column) => column.priority > 0)
    if (!candidates.length) break
    const drop = candidates.reduce((a, b) => (b.priority >= a.priority ? b : a))
    visible = visible.filter((column) => column !== drop)
  }
  return visible
}

/// CSS `grid-template-columns` for the visible columns.
export function gridTemplate(columns: readonly ColumnSpec[]): string {
  return columns.map((column) => (column.width ? `${column.width}px` : `minmax(${column.min ?? 0}px, ${column.flex ?? 1}fr)`)).join(' ')
}

// MARK: - Progress (figures and chart)

export const PERIOD_DAYS: Record<Period, number | null> = { fourWeeks: 28, threeMonths: 91, all: null }

export function startOfDay(ms: number): number {
  const date = new Date(ms)
  date.setHours(0, 0, 0, 0)
  return date.getTime()
}

function addDays(ms: number, days: number): number {
  const date = new Date(ms)
  date.setDate(date.getDate() + days)
  return date.getTime()
}

function addMonths(ms: number, months: number): number {
  const date = new Date(ms)
  date.setMonth(date.getMonth() + months)
  return date.getTime()
}

export interface Progress {
  /// Trainings of the period, oldest first.
  sessions: TrainingRecord[]
  /// The all-time best stay behind the door (null before the first exit).
  best: TrainingRecord | null
  domain: [number, number]
  includesFirstTraining: boolean
  first: TrainingRecord | null
  /// Best of the period.
  periodBest: TrainingRecord | null
  cleanCount: number
  falseStartTotal: number
  /// How much longer the dog stays behind the door now than at the start of the period (whole seconds).
  gain: number | null
}

export function progress(records: readonly TrainingRecord[], period: Period): Progress {
  const all = [...records].sort((a, b) => a.startedAt - b.startedAt)
  let best: TrainingRecord | null = null
  for (const record of all) if (longestStay(record) > 0 && (!best || longestStay(record) > longestStay(best))) best = record
  const newest = all.length ? all[all.length - 1].startedAt : Date.now()
  const end = Math.max(startOfDay(newest) + 12 * HOUR, newest)
  const days = PERIOD_DAYS[period]
  const start = days !== null ? addDays(startOfDay(newest), -days) : startOfDay(all[0]?.startedAt ?? newest) - 12 * HOUR
  const sessions = all.filter((record) => record.startedAt >= start)
  const first = sessions[0] ?? null
  let periodBest: TrainingRecord | null = null
  for (const record of sessions) if (!periodBest || longestStay(record) > longestStay(periodBest)) periodBest = record
  const gain = sessions.length > 1 && first && periodBest ? Math.floor(longestStay(periodBest)) - Math.floor(longestStay(first)) : null
  return {
    sessions,
    best,
    domain: [start, end + 12 * HOUR],
    includesFirstTraining: first !== null && first.id === all[0]?.id,
    first,
    periodBest,
    cleanCount: sessions.filter((record) => falseStarts(record) === 0).length,
    falseStartTotal: sessions.reduce((sum, record) => sum + falseStarts(record), 0),
    gain,
  }
}

/// Top of the y axis and the step of its labels: round clock values, at most six of them.
export function yAxis(sessions: readonly TrainingRecord[]): { max: number; step: number } {
  const top = sessions.reduce((value, record) => Math.max(value, longestStay(record), longestPlanned(record)), 0)
  const steps = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
  const step = steps.find((candidate) => (top * 1.08) / candidate <= 6) ?? 7200
  return { max: Math.max(step * 2, Math.ceil((top * 1.08) / step) * step), step }
}

/// Date labels (left-aligned to their day): every few days for a month, every two weeks for a quarter, monthly
/// beyond; none so close to the right edge that it would be cut off.
export function xAxisValues(domain: [number, number]): number[] {
  const [lower, upper] = domain
  const days = (upper - lower) / DAY
  const first = startOfDay(lower + DAY - 1)
  const next =
    days <= 40 ? (ms: number) => addDays(ms, Math.max(1, Math.round(days / 7)))
    : days <= 120 ? (ms: number) => addDays(ms, 14)
    : (ms: number) => addMonths(ms, Math.max(1, Math.ceil(days / 30 / 7)))
  const lastAllowed = upper - days * DAY * 0.06
  const values: number[] = []
  for (let date = first; date <= lastAllowed && values.length < 100; date = next(date)) values.push(date)
  return values
}

/// Linear scale helper.
export function scale(domain: [number, number], range: [number, number]): (value: number) => number {
  const [d0, d1] = domain
  const [r0, r1] = range
  const span = d1 - d0 || 1
  return (value) => r0 + ((value - d0) / span) * (r1 - r0)
}

/// SVG path through points with monotone cubic interpolation in x (d3's `curveMonotoneX`): no overshoot above
/// the highest or below the lowest neighbour, as SwiftUI Charts' `.monotone`.
export function monotonePath(points: readonly [number, number][]): string {
  const n = points.length
  if (n === 0) return ''
  if (n === 1) return `M${points[0][0]},${points[0][1]}`
  if (n === 2) return `M${points[0][0]},${points[0][1]}L${points[1][0]},${points[1][1]}`
  const slopes: number[] = []
  for (let i = 0; i < n - 1; i++) {
    const dx = points[i + 1][0] - points[i][0]
    slopes.push(dx === 0 ? 0 : (points[i + 1][1] - points[i][1]) / dx)
  }
  const tangents: number[] = new Array(n)
  tangents[0] = slopes[0]
  tangents[n - 1] = slopes[n - 2]
  for (let i = 1; i < n - 1; i++) {
    const s0 = slopes[i - 1]
    const s1 = slopes[i]
    if (s0 * s1 <= 0) {
      tangents[i] = 0
    } else {
      const h0 = points[i][0] - points[i - 1][0]
      const h1 = points[i + 1][0] - points[i][0]
      const p = (s0 * h1 + s1 * h0) / (h0 + h1)
      tangents[i] = (Math.sign(s0) + Math.sign(s1)) * Math.min(Math.abs(s0), Math.abs(s1), 0.5 * Math.abs(p))
    }
  }
  let path = `M${round(points[0][0])},${round(points[0][1])}`
  for (let i = 0; i < n - 1; i++) {
    const [x0, y0] = points[i]
    const [x1, y1] = points[i + 1]
    const dx = (x1 - x0) / 3
    path += `C${round(x0 + dx)},${round(y0 + dx * tangents[i])},${round(x1 - dx)},${round(y1 - dx * tangents[i + 1])},${round(x1)},${round(y1)}`
  }
  return path
}

/// Step line that holds each value until the next point (`.stepEnd`).
export function stepPath(points: readonly [number, number][]): string {
  if (!points.length) return ''
  let path = `M${round(points[0][0])},${round(points[0][1])}`
  for (let i = 1; i < points.length; i++) path += `H${round(points[i][0])}V${round(points[i][1])}`
  return path
}

function round(value: number): number {
  return Math.round(value * 10) / 10
}

/// Index of the point closest to `x` horizontally, within `radius` pixels.
export function nearestIndex(xs: readonly number[], x: number, radius = 24): number | null {
  let best: number | null = null
  let distance = Infinity
  xs.forEach((value, index) => {
    const d = Math.abs(value - x)
    if (d < distance) {
      distance = d
      best = index
    }
  })
  return best !== null && distance <= radius ? best : null
}

// MARK: - Exit strip

export type StripKind = 'walk' | 'away' | 'falseStart' | 'rest'

export interface StripSegment {
  id: string
  /// Seconds from the strip's start.
  start: number
  end: number
  kind: StripKind
  exit: number
  attempt: number
  /// Where "jump to this exit" seeks: the exit's start.
  jump: number
}

/// The training laid along its recording (or along itself without one): walks to the door, time behind it,
/// false starts, breaks. `base` is the clock time of offset 0, `total` the strip's length in seconds.
export function stripSegments(record: TrainingRecord, base: number, total: number): StripSegment[] {
  const segments: StripSegment[] = []
  for (const result of record.results) {
    const start = (result.startedAt - base) / 1000
    const left = ((result.leftAt ?? result.endedAt) - base) / 1000
    const end = (result.endedAt - base) / 1000
    const common = { exit: result.number, attempt: result.attempt, jump: Math.max(0, start) }
    segments.push({ id: result.id + 'w', start, end: left, kind: 'walk', ...common })
    if (result.leftAt !== null || result.falseStart) {
      segments.push({ id: result.id + 'a', start: left, end, kind: result.falseStart ? 'falseStart' : 'away', ...common })
    }
    if (result.actualBreak !== null) segments.push({ id: result.id + 'r', start: end, end: end + result.actualBreak, kind: 'rest', ...common })
  }
  return segments.filter((segment) => segment.end > 0 && segment.start < total)
}

/// Clock labels on round minutes, at least `minGap` px apart: offsets in seconds from `base`.
export function stripTicks(base: number, total: number, width: number, minGap = 56): number[] {
  if (total <= 0 || width <= 0) return []
  const steps = [60, 120, 300, 600, 900, 1800, 3600]
  const step = steps.find((candidate) => width * (candidate / Math.max(1, total)) >= minGap) ?? 7200
  const baseSeconds = base / 1000
  const first = Math.ceil(baseSeconds / step) * step - baseSeconds
  const ticks: number[] = []
  for (let offset = first; offset <= total; offset += step) {
    if (offset > step * 0.3 && total - offset > step * 0.3) ticks.push(offset)
  }
  return ticks
}

/// "0:31" behind the door, or null for an exit that never got past the door.
export function awayText(result: ExitResult, clock: (seconds: number) => string): string | null {
  return result.leftAt === null ? null : clock(ExitResult.awayDuration(result))
}

/// A break worth highlighting: more than 15 s off the plan (as the log text does).
export function breakIsOff(result: ExitResult): boolean {
  return result.actualBreak !== null && Math.abs(result.actualBreak - result.plannedBreak) > 15
}
