// Port of Models/SessionLog.swift: session events, exit results, the saved record and the trainer's log text.

import {
  type DateEncoding,
  type JSONObject,
  DecodingError,
  ObjectReader,
  compact,
  encodeDate,
  expectString,
  newUUID,
} from './codable'
import { DurationText } from './durationText'
import { formatDate, tr } from './localization'
import { PlannedExit, TrainingPlan } from './models'
import { trimWhitespaces } from './text'

export type SessionEventKind =
  | 'sessionStarted'
  | 'exitStarted'
  | 'behindDoor'
  | 'exitEnded'
  | 'falseStart'
  | 'breakStarted'
  | 'breakEnded'
  | 'recordingStarted'
  | 'recordingStopped'
  | 'sessionFinished'
  | 'note'

export const SessionEventKind = {
  allCases: [
    'sessionStarted',
    'exitStarted',
    'behindDoor',
    'exitEnded',
    'falseStart',
    'breakStarted',
    'breakEnded',
    'recordingStarted',
    'recordingStopped',
    'sessionFinished',
    'note',
  ] as readonly SessionEventKind[],

  title(kind: SessionEventKind): string {
    switch (kind) {
      case 'sessionStarted':
        return tr('Тренировка начата', 'Training started')
      case 'exitStarted':
        return tr('Пошли к двери', 'Walking to the door')
      case 'behindDoor':
        return tr('За дверью', 'Outside')
      case 'exitEnded':
        return tr('Вернулись', 'Back inside')
      case 'falseStart':
        return tr('Фальстарт / сброс', 'False start / reset')
      case 'breakStarted':
        return tr('Перерыв', 'Break')
      case 'breakEnded':
        return tr('Перерыв окончен', 'Break over')
      case 'recordingStarted':
        return tr('Запись включена', 'Recording started')
      case 'recordingStopped':
        return tr('Запись остановлена', 'Recording stopped')
      case 'sessionFinished':
        return tr('Тренировка завершена', 'Training finished')
      case 'note':
        return tr('Заметка', 'Note')
    }
  },

  decode(value: unknown, path = ''): SessionEventKind {
    const raw = expectString(value, path)
    if (!(SessionEventKind.allCases as readonly string[]).includes(raw)) {
      throw new DecodingError(path, `unknown event kind ${raw}`)
    }
    return raw as SessionEventKind
  },
}

/** A single timestamped button press (or automatic transition) during a session. */
export interface SessionEvent {
  id: string
  /** Epoch ms. */
  time: number
  kind: SessionEventKind
  exitNumber: number | null
  attempt: number | null
  detail: string | null
}

export const SessionEvent = {
  make(fields: Pick<SessionEvent, 'time' | 'kind'> & Partial<SessionEvent>): SessionEvent {
    return {
      id: fields.id ?? newUUID(),
      time: fields.time,
      kind: fields.kind,
      exitNumber: fields.exitNumber ?? null,
      attempt: fields.attempt ?? null,
      detail: fields.detail ?? null,
    }
  },

  encode(event: SessionEvent, dates: DateEncoding): JSONObject {
    return compact({
      id: event.id,
      time: encodeDate(event.time, dates),
      kind: event.kind,
      exitNumber: event.exitNumber,
      attempt: event.attempt,
      detail: event.detail,
    })
  },

  decode(value: unknown, dates: DateEncoding, path = ''): SessionEvent {
    const json = new ObjectReader(value, path)
    return {
      id: json.uuid('id'),
      time: json.date('time', dates),
      kind: json.required('kind', SessionEventKind.decode),
      exitNumber: json.optionalInt('exitNumber'),
      attempt: json.optionalInt('attempt'),
      detail: json.optionalString('detail'),
    }
  },
}

/** Outcome of one attempt of one exit. Times are epoch ms, durations seconds. */
export interface ExitResult {
  id: string
  number: number
  attempt: number
  plannedDuration: number
  untilStanding: boolean
  startedAt: number
  leftAt: number | null
  endedAt: number
  falseStart: boolean
  plannedBreak: number
  actualBreak: number | null
  /** An extra exit without a planned time (after the schedule's last one). */
  isOpen: boolean
}

export const ExitResult = {
  make(
    fields: Omit<ExitResult, 'id' | 'actualBreak' | 'isOpen'> & Partial<Pick<ExitResult, 'id' | 'actualBreak' | 'isOpen'>>,
  ): ExitResult {
    return { ...fields, id: fields.id ?? newUUID(), actualBreak: fields.actualBreak ?? null, isOpen: fields.isOpen ?? false }
  },

  /** Time actually spent behind the door ("За дверью" → "Вернулись"), in seconds. */
  awayDuration(result: ExitResult): number {
    return result.leftAt === null ? 0 : (result.endedAt - result.leftAt) / 1000
  },

  /** Whole exit from "Начать выход" to "Вернулись", in seconds. */
  totalDuration(result: ExitResult): number {
    return (result.endedAt - result.startedAt) / 1000
  },

  encode(result: ExitResult, dates: DateEncoding): JSONObject {
    return compact({
      id: result.id,
      number: result.number,
      attempt: result.attempt,
      plannedDuration: result.plannedDuration,
      untilStanding: result.untilStanding,
      startedAt: encodeDate(result.startedAt, dates),
      leftAt: result.leftAt === null ? null : encodeDate(result.leftAt, dates),
      endedAt: encodeDate(result.endedAt, dates),
      falseStart: result.falseStart,
      plannedBreak: result.plannedBreak,
      actualBreak: result.actualBreak,
      isOpen: result.isOpen,
    })
  },

  /** Results of builds before extra exits decode as planned ones. */
  decode(value: unknown, dates: DateEncoding, path = ''): ExitResult {
    const json = new ObjectReader(value, path)
    return {
      id: json.uuid('id'),
      number: json.int('number'),
      attempt: json.int('attempt'),
      plannedDuration: json.number('plannedDuration'),
      untilStanding: json.bool('untilStanding'),
      startedAt: json.date('startedAt', dates),
      leftAt: json.optionalDate('leftAt', dates),
      endedAt: json.date('endedAt', dates),
      falseStart: json.bool('falseStart'),
      plannedBreak: json.number('plannedBreak'),
      actualBreak: json.optionalNumber('actualBreak'),
      isOpen: json.optionalBool('isOpen') ?? false,
    }
  },
}

/** Everything worth keeping after a session: the plan, the log and the recording file name. */
export interface TrainingRecord {
  id: string
  plan: TrainingPlan
  startedAt: number
  finishedAt: number
  events: SessionEvent[]
  results: ExitResult[]
  recordingFileName: string | null
}

export const TrainingRecord = {
  make(
    fields: Omit<TrainingRecord, 'id' | 'recordingFileName'> & Partial<Pick<TrainingRecord, 'id' | 'recordingFileName'>>,
  ): TrainingRecord {
    return { ...fields, id: fields.id ?? newUUID(), recordingFileName: fields.recordingFileName ?? null }
  },

  /** Seconds. */
  duration(record: TrainingRecord): number {
    return (record.finishedAt - record.startedAt) / 1000
  },

  completedExits(record: TrainingRecord): number {
    return record.results.filter((result) => !result.falseStart).length
  },

  falseStarts(record: TrainingRecord): number {
    return record.results.filter((result) => result.falseStart).length
  },

  encode(record: TrainingRecord, dates: DateEncoding): JSONObject {
    return compact({
      id: record.id,
      plan: TrainingPlan.encode(record.plan, dates),
      startedAt: encodeDate(record.startedAt, dates),
      finishedAt: encodeDate(record.finishedAt, dates),
      events: record.events.map((event) => SessionEvent.encode(event, dates)),
      results: record.results.map((result) => ExitResult.encode(result, dates)),
      recordingFileName: record.recordingFileName,
    })
  },

  decode(value: unknown, dates: DateEncoding, path = ''): TrainingRecord {
    const json = new ObjectReader(value, path)
    return {
      id: json.uuid('id'),
      plan: json.required('plan', (item, itemPath) => TrainingPlan.decode(item, dates, itemPath)),
      startedAt: json.date('startedAt', dates),
      finishedAt: json.date('finishedAt', dates),
      events: json.array('events', (item, itemPath) => SessionEvent.decode(item, dates, itemPath)),
      results: json.array('results', (item, itemPath) => ExitResult.decode(item, dates, itemPath)),
      recordingFileName: json.optionalString('recordingFileName'),
    }
  },
}

/**
 * Renders a record as a short plain-text report, one line per exit in the trainer's own notation
 * (in the app's language, `coreLanguage()`):
 *
 *     Тренировка на пятницу · Марк
 *     25.09.2026, 18:00–18:41 (41 мин) · выходов 9 из 9 · фальстартов 1
 *
 *     1 выход — 2 с: за дверью 0:03 ✅ · перерыв 2:10
 *     2 выход — 5 с: фальстарт, за дверью 0:01 ❌ · перерыв 1:00 (план 5 мин)
 *     2 выход — 5 с, попытка 2: за дверью 0:06 ✅ · перерыв 5:05
 *
 *     Exit 2 — 5 s, attempt 2: outside 0:06 ✅ · break 5:05
 *
 * Every press is still kept in `TrainingRecord.events` (JSON); the text leaves out what the exit lines already say.
 */
export const SessionLogFormatter = {
  text(record: TrainingRecord): string {
    const lines: string[] = []
    const title = trimWhitespaces(record.plan.title)
    lines.push(record.plan.trainers === '' ? title : `${title} · ${record.plan.trainers}`)

    const { day, time } = SessionLogFormatter
    let summary = `${day(record.startedAt)}, ${time(record.startedAt)}–${time(record.finishedAt)}`
    summary += ` (${DurationText.short(TrainingRecord.duration(record))})`
    const completed = TrainingRecord.completedExits(record)
    const planned = record.plan.exits.length
    summary += tr(` · выходов ${completed} из ${planned}`, ` · exits ${completed} of ${planned}`)
    const falseStarts = TrainingRecord.falseStarts(record)
    if (falseStarts > 0) summary += tr(` · фальстартов ${falseStarts}`, ` · false starts ${falseStarts}`)
    lines.push(summary)
    lines.push('')

    record.results.forEach((result, index) => {
      let line =
        `${SessionLogFormatter.exitName(result.number)} — ` +
        (result.isOpen ? PlannedExit.openText() : DurationText.short(result.plannedDuration))
      if (result.untilStanding) line += ' ' + PlannedExit.untilStandingText()
      if (result.attempt > 1) line += tr(`, попытка ${result.attempt}`, `, attempt ${result.attempt}`)
      line += `: ${SessionLogFormatter.outcome(result)} ${result.falseStart ? '❌' : '✅'}`
      // The break after the last exit only ends the session.
      if (index < record.results.length - 1) {
        const text = SessionLogFormatter.breakText(result)
        if (text !== null) line += ` · ${text}`
      }
      lines.push(line)
    })

    const notes = record.events.filter((event) => event.kind === 'note' && (event.detail ?? '') !== '')
    if (notes.length > 0) {
      lines.push('')
      for (const note of notes) {
        const exit = note.exitNumber === null ? '' : tr(` (выход ${note.exitNumber})`, ` (exit ${note.exitNumber})`)
        lines.push(`${time(note.time)}${exit}: ${note.detail ?? ''}`)
      }
    }

    return lines.join('\n')
  },

  /** "3 выход" / "Exit 3": how the trainer's schedule names an exit. */
  exitName(number: number): string {
    return tr(`${number} выход`, `Exit ${number}`)
  },

  /** "за дверью 0:03", "фальстарт, за дверью 0:01", "фальстарт до двери". */
  outcome(result: ExitResult): string {
    const awayClock = DurationText.clock(ExitResult.awayDuration(result))
    const away = result.leftAt === null ? null : tr(`за дверью ${awayClock}`, `outside ${awayClock}`)
    if (result.falseStart) {
      return away !== null
        ? tr(`фальстарт, ${away}`, `false start, ${away}`)
        : tr('фальстарт до двери', 'false start before the door')
    }
    return away ?? tr('не выходили за дверь', "didn't go outside")
  },

  /** "перерыв 2:10", with the plan only when the break was noticeably different from it. */
  breakText(result: ExitResult): string | null {
    const actual = result.actualBreak
    if (actual === null) return null
    let text = tr(`перерыв ${DurationText.clock(actual)}`, `break ${DurationText.clock(actual)}`)
    if (Math.abs(actual - result.plannedBreak) > 15) {
      const plan = DurationText.short(result.plannedBreak)
      text += tr(` (план ${plan})`, ` (plan ${plan})`)
    }
    return text
  },

  /** "25.09.2026, 18:00:05" / "09/25/2026, 6:00:05 PM" (the date order of the device's region, the clock of the app's language). */
  dateTime(ms: number): string {
    return formatDate(ms, 'ddMMyyyy jmmss')
  },

  /** "18:00" / "6:00 PM". */
  time(ms: number): string {
    return formatDate(ms, 'jmm')
  },

  /** "25.09.2026" / "09/25/2026". */
  day(ms: number): string {
    return formatDate(ms, 'ddMMyyyy')
  },
}
