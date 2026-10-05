// Port of Models/TrainingPlan.swift.
//
// Models are plain, immutable-by-convention objects (safe to put in a React store or send over IPC);
// the functions Swift has as members live in companion objects of the same name
// (`TrainingPlan.breakAfter(plan, index)` for `plan.breakAfter(exitAt: index)`).

import {
  type DateEncoding,
  type JSONObject,
  ObjectReader,
  compact,
  encodeDate,
  expectString,
  newUUID,
} from './codable'
import { DurationText } from './durationText'
import { formatDate, tr } from './localization'
import { trimWhitespaces } from './text'

/** One planned exit from the apartment. */
export interface PlannedExit {
  id: string
  /** 1-based number as written in the schedule. */
  number: number
  /** Planned time behind the door, in seconds. */
  duration: number
  /** "ИЛИ до вставания" — come back as soon as the dog stands up. */
  untilStanding: boolean
  /** Free-form remark, e.g. "выйти и сразу вернуться". */
  note: string | null
  /** Explicit break after this exit, in seconds. `null` means the plan's default break. */
  breakAfter: number | null
}

export const PlannedExit = {
  make(fields: Pick<PlannedExit, 'number' | 'duration'> & Partial<PlannedExit>): PlannedExit {
    return {
      id: fields.id ?? newUUID(),
      number: fields.number,
      duration: fields.duration,
      untilStanding: fields.untilStanding ?? false,
      note: fields.note ?? null,
      breakAfter: fields.breakAfter ?? null,
    }
  },

  /** Human readable planned duration, e.g. "30 с или до вставания" / "30 s or until the dog stands". */
  durationDescription(exit: PlannedExit): string {
    let text = DurationText.short(exit.duration)
    if (exit.untilStanding) text += ' ' + PlannedExit.untilStandingText()
    return text
  },

  /** "или до вставания": come back as soon as the dog stands up. */
  untilStandingText(): string {
    return tr('или до вставания', 'or until the dog stands')
  },

  encode(exit: PlannedExit): JSONObject {
    return compact({
      id: exit.id,
      number: exit.number,
      duration: exit.duration,
      untilStanding: exit.untilStanding,
      note: exit.note,
      breakAfter: exit.breakAfter,
    })
  },

  decode(value: unknown, path = ''): PlannedExit {
    const json = new ObjectReader(value, path)
    return {
      id: json.uuid('id'),
      number: json.int('number'),
      duration: json.number('duration'),
      untilStanding: json.bool('untilStanding'),
      note: json.optionalString('note'),
      breakAfter: json.optionalNumber('breakAfter'),
    }
  },
}

/** A parsed (and possibly hand-corrected) training schedule. */
export interface TrainingPlan {
  id: string
  title: string
  trainers: string
  /** The schedule's date (epoch ms, noon local time), if the header had one. */
  date: number | null
  notes: string[]
  /** Seconds. */
  defaultBreak: number
  exits: PlannedExit[]
  rawText: string
}

export const TrainingPlan = {
  defaultBreakDuration: 120,

  /** Title of a schedule without a header line. */
  defaultTitle(): string {
    return tr('Тренировка', 'Training')
  },

  make(fields: Partial<TrainingPlan> = {}): TrainingPlan {
    return {
      id: fields.id ?? newUUID(),
      title: fields.title ?? TrainingPlan.defaultTitle(),
      trainers: fields.trainers ?? '',
      date: fields.date ?? null,
      notes: fields.notes ?? [],
      defaultBreak: fields.defaultBreak ?? TrainingPlan.defaultBreakDuration,
      exits: fields.exits ?? [],
      rawText: fields.rawText ?? '',
    }
  },

  /** Break that follows the exit at `index` (falls back to the default break). */
  breakAfter(plan: TrainingPlan, index: number): number {
    if (index < 0 || index >= plan.exits.length) return plan.defaultBreak
    return plan.exits[index].breakAfter ?? plan.defaultBreak
  },

  /** Sum of planned exits and the breaks between them (the last break is excluded). */
  estimatedDuration(plan: TrainingPlan): number {
    let total = 0
    plan.exits.forEach((exit, index) => {
      total += exit.duration
      if (index < plan.exits.length - 1) total += TrainingPlan.breakAfter(plan, index)
    })
    return total
  },

  isValid(plan: TrainingPlan): boolean {
    return plan.exits.length > 0
  },

  /** A copy with exit numbers rewritten to 1…n in order (`renumber()`). */
  renumbered(plan: TrainingPlan): TrainingPlan {
    return { ...plan, exits: plan.exits.map((exit, index) => ({ ...exit, number: index + 1 })) }
  },

  /** Short label used in lists, e.g. "05.10.2026 · Тренировка на понедельник". */
  displayTitle(plan: TrainingPlan): string {
    const trimmed = trimWhitespaces(plan.title)
    return plan.date !== null ? `${TrainingPlan.formatDate(plan.date)} · ${trimmed}` : trimmed
  },

  /** The schedule's date: "05.10.2026" / "10/05/2026" (`TrainingPlan.dateFormatter`). */
  formatDate(ms: number): string {
    return formatDate(ms, 'ddMMyyyy')
  },

  encode(plan: TrainingPlan, dates: DateEncoding): JSONObject {
    return compact({
      id: plan.id,
      title: plan.title,
      trainers: plan.trainers,
      date: plan.date === null ? null : encodeDate(plan.date, dates),
      notes: plan.notes,
      defaultBreak: plan.defaultBreak,
      exits: plan.exits.map(PlannedExit.encode),
      rawText: plan.rawText,
    })
  },

  decode(value: unknown, dates: DateEncoding, path = ''): TrainingPlan {
    const json = new ObjectReader(value, path)
    return {
      id: json.uuid('id'),
      title: json.string('title'),
      trainers: json.string('trainers'),
      date: json.optionalDate('date', dates),
      notes: json.array('notes', expectString),
      defaultBreak: json.number('defaultBreak'),
      exits: json.array('exits', (item, itemPath) => PlannedExit.decode(item, itemPath)),
      rawText: json.string('rawText'),
    }
  },
}
