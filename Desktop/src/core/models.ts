// Port of Models/TrainingPlan.swift.
//
// Models are plain, immutable-by-convention objects (safe to put in a React store or send over IPC);
// the functions Swift has as members live in companion objects of the same name
// (`TrainingPlan.breakAfter(plan, index)` for `plan.breakAfter(exitAt: index)`).

import {
  type DateEncoding,
  DecodingError,
  type JSONObject,
  ObjectReader,
  compact,
  deepEqual,
  encodeDate,
  expectString,
  newUUID,
  sameUUID,
} from './codable'
import { DurationText } from './durationText'
import { formatDate, tr } from './localization'
import { PlanParser } from './planParser'
import { trimWhitespaces, trimWhitespacesAndNewlines } from './text'

/** The trainer's mark in front of a condition line (`EarlyEntry.Tone`). */
export type EarlyEntryTone = 'yellow' | 'green' | 'plain'

const tones: readonly EarlyEntryTone[] = ['yellow', 'green', 'plain']

/**
 * When to come back before the planned time, from a line such as «🟡 Если встала и пошла - входим через 2 минуты от
 * начала движения, когда сняла фокус внимания с двери» or «🟢 Если легла - входим через 30 секунд от укладки».
 */
export interface EarlyEntry {
  id: string
  /** What the dog does: «Встала и пошла», «Легла». */
  event: string
  /** How long after it to come back, in seconds; `null` — right away. */
  delay: number | null
  /** The rest of the trainer's sentence: «от начала движения, когда сняла фокус внимания с двери…», «от укладки». */
  detail: string | null
  tone: EarlyEntryTone
}

export const EarlyEntry = {
  make(fields: Pick<EarlyEntry, 'event'> & Partial<EarlyEntry>): EarlyEntry {
    return {
      id: fields.id ?? newUUID(),
      event: fields.event,
      delay: fields.delay ?? null,
      detail: fields.detail ?? null,
      tone: fields.tone ?? 'plain',
    }
  },

  /** «через 2 мин» / «сразу». */
  delayDescription(entry: EarlyEntry): string {
    if (entry.delay === null || entry.delay <= 0) return tr('сразу', 'right away')
    const text = DurationText.short(entry.delay)
    return tr(`через ${text}`, `in ${text}`)
  },

  /** «встала и пошла → 2:00», «легла → 0:30», «встала → сразу»: the short form for summaries. */
  summary(entry: EarlyEntry): string {
    const [first = '', ...rest] = Array.from(entry.event)
    const name = first.toLowerCase() + rest.join('')
    if (entry.delay === null || entry.delay <= 0) return `${name} → ` + tr('сразу', 'right away')
    return `${name} → ${DurationText.clock(entry.delay)}`
  },

  /** The condition is about the dog standing up («встала», «встала и пошла», "stands up"). */
  isStandingUp(entry: EarlyEntry): boolean {
    const lower = entry.event.toLowerCase()
    return lower.includes('встал') || lower.includes('встав') || lower.includes('stand') || lower.includes('got up')
  },

  /** The same condition with a new id (a copy for one exit of the plan's common conditions). */
  copy(entry: EarlyEntry): EarlyEntry {
    return { ...entry, id: newUUID() }
  },

  /** «До вставания»: an exit's «ИЛИ до вставания» shown as a condition. */
  untilStanding(): EarlyEntry {
    return EarlyEntry.make({ id: '00000000-0000-0000-0000-00000000057A', event: tr('Встала', 'Stands up') })
  },

  encode(entry: EarlyEntry): JSONObject {
    return compact({ id: entry.id, event: entry.event, delay: entry.delay, detail: entry.detail, tone: entry.tone })
  },

  decode(value: unknown, path = ''): EarlyEntry {
    const json = new ObjectReader(value, path)
    return {
      id: json.uuid('id'),
      event: json.string('event'),
      delay: json.optionalNumber('delay'),
      detail: json.optionalString('detail'),
      tone: json.required('tone', (item, itemPath) => {
        const tone = expectString(item, itemPath)
        if (!(tones as readonly string[]).includes(tone)) throw new DecodingError(itemPath, `unknown tone ${tone}`)
        return tone as EarlyEntryTone
      }),
    }
  },
}

/** One planned exit from the apartment. */
export interface PlannedExit {
  id: string
  /** 1-based number as written in the schedule. */
  number: number
  /** Planned time behind the door, in seconds. */
  duration: number
  /** "ИЛИ до вставания" — come back as soon as the dog stands up. */
  untilStanding: boolean
  /**
   * The exit's own notes: a remark in parentheses («выйти и сразу вернуться»), the trainer's wording of the exit, the
   * owner's own words.
   */
  note: string | null
  /** Explicit break after this exit, in seconds. `null` means the plan's default break. */
  breakAfter: number | null
  /** What to do or take on the way out: «куртка», «взять ключи, звякнуть ими», «закрыть дверь на один оборот». */
  triggers: string[]
  /** The exit's own conditions for coming back early (lines under the exit in the schedule). */
  earlyEntries: EarlyEntry[]
  /** The plan's common conditions apply to this exit (when it has none of its own). */
  usesCommonEarlyEntries: boolean
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
      triggers: fields.triggers ?? [],
      earlyEntries: fields.earlyEntries ?? [],
      usesCommonEarlyEntries: fields.usesCommonEarlyEntries ?? true,
    }
  },

  /** Human readable planned duration, e.g. "30 с или до вставания" / "30 s or until the dog stands". */
  durationDescription(exit: PlannedExit): string {
    let text = DurationText.short(exit.duration)
    if (exit.untilStanding) text += ' ' + PlannedExit.untilStandingText()
    return text
  },

  /** The note with something in it. */
  noteText(exit: PlannedExit): string | null {
    const note = exit.note === null ? '' : trimWhitespacesAndNewlines(exit.note)
    return note === '' ? null : note
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
      triggers: exit.triggers,
      earlyEntries: exit.earlyEntries.map(EarlyEntry.encode),
      usesCommonEarlyEntries: exit.usesCommonEarlyEntries,
    })
  },

  /** Plans from builds before triggers and conditions decode with none of their own. */
  decode(value: unknown, path = ''): PlannedExit {
    const json = new ObjectReader(value, path)
    return {
      id: json.uuid('id'),
      number: json.int('number'),
      duration: json.number('duration'),
      untilStanding: json.bool('untilStanding'),
      note: json.optionalString('note'),
      breakAfter: json.optionalNumber('breakAfter'),
      triggers: json.has('triggers') ? json.array('triggers', expectString) : [],
      earlyEntries: json.has('earlyEntries') ? json.array('earlyEntries', (item, itemPath) => EarlyEntry.decode(item, itemPath)) : [],
      usesCommonEarlyEntries: json.optionalBool('usesCommonEarlyEntries') ?? true,
    }
  },
}

/** Which exits get the common conditions: all of them or those of at least a minute (`TrainingPlan.CommonEntriesScope`). */
export type CommonEntriesScope = 'all' | 'long'

export const CommonEntriesScope = {
  allCases: ['all', 'long'] as readonly CommonEntriesScope[],

  /** «К длинным»: an exit this long or longer. */
  longExit: 60,

  includes(scope: CommonEntriesScope, exit: PlannedExit): boolean {
    return scope === 'all' || exit.duration >= CommonEntriesScope.longExit
  },
}

/** «🚩 Если залаяла, завыла - ни в коем случае не входить, ждём…»: when NOT to come in (`TrainingPlan.Rule`). */
export interface PlanRule {
  /** «Залаяла, завыла». */
  title: string
  /** «ни в коем случае не входить, ждём когда станет чуть спокойнее…». */
  detail: string
  text: string
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
  /** Conditions for coming back early written once for the whole training (after or before the exits). */
  commonEarlyEntries: EarlyEntry[]
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
      commonEarlyEntries: fields.commonEarlyEntries ?? [],
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

  // MARK: - Conditions for coming back early

  /**
   * Conditions that apply to `exit`: its own, or the plan's common ones when it has none and they apply to it.
   * An «ИЛИ до вставания» exit without a condition about standing up gets «Встала → сразу».
   */
  earlyEntries(plan: TrainingPlan, exit: PlannedExit): EarlyEntry[] {
    const entries = exit.earlyEntries.length === 0 && exit.usesCommonEarlyEntries ? plan.commonEarlyEntries : exit.earlyEntries
    if (exit.untilStanding && !entries.some(EarlyEntry.isStandingUp)) return [EarlyEntry.untilStanding(), ...entries]
    return entries
  },

  /** `exit` shows the plan's common conditions (none of its own). */
  usesCommonEarlyEntries(plan: TrainingPlan, exit: PlannedExit): boolean {
    return exit.earlyEntries.length === 0 && exit.usesCommonEarlyEntries && plan.commonEarlyEntries.length > 0
  },

  /** The scope the exits now follow; `null` when they were picked one by one. */
  commonEntriesScope(plan: TrainingPlan): CommonEntriesScope | null {
    const candidates = plan.exits.filter((exit) => exit.earlyEntries.length === 0)
    return (
      CommonEntriesScope.allCases.find((scope) =>
        candidates.every((exit) => exit.usesCommonEarlyEntries === CommonEntriesScope.includes(scope, exit)),
      ) ?? null
    )
  },

  /** Exits with their own conditions keep them. */
  applyCommonEarlyEntries(plan: TrainingPlan, scope: CommonEntriesScope): TrainingPlan {
    return {
      ...plan,
      exits: plan.exits.map((exit) =>
        exit.earlyEntries.length === 0 ? { ...exit, usesCommonEarlyEntries: CommonEntriesScope.includes(scope, exit) } : exit,
      ),
    }
  },

  /** Turns the common conditions the exit at `index` shows into its own, so they can be changed for this exit alone. */
  detachEarlyEntries(plan: TrainingPlan, index: number): TrainingPlan {
    if (index < 0 || index >= plan.exits.length || !TrainingPlan.usesCommonEarlyEntries(plan, plan.exits[index])) return plan
    const exits = [...plan.exits]
    exits[index] = { ...exits[index], earlyEntries: plan.commonEarlyEntries.map(EarlyEntry.copy), usesCommonEarlyEntries: false }
    return { ...plan, exits }
  },

  // MARK: - Rules for the whole training

  /** The note that says when not to come in. */
  doNotEnterRule(plan: TrainingPlan): PlanRule | null {
    for (const note of plan.notes) {
      if (!PlanParser.isDoNotEnterRule(note)) continue
      const { title, detail } = PlanParser.splitCondition(note)
      return { title: title ?? tr('Не входить', 'Do not come in'), detail, text: note }
    }
    return null
  },

  /**
   * What an edit changed, for the session log: "перерывы 2 мин → 3 мин", "выход 4: 45 с → 1 мин",
   * "перерыв после выхода 5: 2 мин → 5 мин", "добавлен выход 6 — 30 с", "убран выход 7". Exits are matched by id.
   */
  changes(plan: TrainingPlan, old: TrainingPlan): string[] {
    const changes: string[] = []
    const short = DurationText.short
    if (plan.defaultBreak !== old.defaultBreak) {
      changes.push(
        tr(`перерывы ${short(old.defaultBreak)} → ${short(plan.defaultBreak)}`, `breaks ${short(old.defaultBreak)} → ${short(plan.defaultBreak)}`),
      )
    }
    plan.exits.forEach((exit, index) => {
      const oldIndex = old.exits.findIndex((other) => sameUUID(other.id, exit.id))
      const description = PlannedExit.durationDescription(exit)
      if (oldIndex < 0) {
        changes.push(tr(`добавлен выход ${exit.number} — ${description}`, `exit ${exit.number} added — ${description}`))
        return
      }
      const was = old.exits[oldIndex]
      if (was.duration !== exit.duration || was.untilStanding !== exit.untilStanding) {
        const before = PlannedExit.durationDescription(was)
        changes.push(tr(`выход ${exit.number}: ${before} → ${description}`, `exit ${exit.number}: ${before} → ${description}`))
      }
      if (!deepEqual(was.triggers, exit.triggers)) {
        changes.push(tr(`выход ${exit.number}: триггеры`, `exit ${exit.number}: triggers`))
      }
      if (!deepEqual(TrainingPlan.earlyEntries(old, was), TrainingPlan.earlyEntries(plan, exit))) {
        changes.push(tr(`выход ${exit.number}: ранний вход`, `exit ${exit.number}: coming back early`))
      }
      if (PlannedExit.noteText(was) !== PlannedExit.noteText(exit)) {
        changes.push(tr(`выход ${exit.number}: заметка`, `exit ${exit.number}: note`))
      }
      // Own breaks only: a new common break is already said above.
      const before = TrainingPlan.breakAfter(old, oldIndex)
      const after = TrainingPlan.breakAfter(plan, index)
      if ((was.breakAfter !== null || exit.breakAfter !== null) && before !== after && index < plan.exits.length - 1) {
        changes.push(
          tr(
            `перерыв после выхода ${exit.number}: ${short(before)} → ${short(after)}`,
            `break after exit ${exit.number}: ${short(before)} → ${short(after)}`,
          ),
        )
      }
    })
    for (const exit of old.exits) {
      if (!plan.exits.some((other) => sameUUID(other.id, exit.id))) {
        changes.push(tr(`убран выход ${exit.number}`, `exit ${exit.number} removed`))
      }
    }
    return changes
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
      commonEarlyEntries: plan.commonEarlyEntries.map(EarlyEntry.encode),
    })
  },

  /**
   * A plan from a build before conditions keeps «🟡 Если встала - входим через 15 секунд» among its notes: such
   * notes become its common conditions.
   */
  decode(value: unknown, dates: DateEncoding, path = ''): TrainingPlan {
    const json = new ObjectReader(value, path)
    let notes = json.array('notes', expectString)
    let commonEarlyEntries: EarlyEntry[]
    if (json.has('commonEarlyEntries')) {
      commonEarlyEntries = json.array('commonEarlyEntries', (item, itemPath) => EarlyEntry.decode(item, itemPath))
    } else {
      commonEarlyEntries = notes.flatMap((note) => PlanParser.parseEarlyEntry(note) ?? [])
      notes = notes.filter((note) => PlanParser.parseEarlyEntry(note) === null)
    }
    return {
      id: json.uuid('id'),
      title: json.string('title'),
      trainers: json.string('trainers'),
      date: json.optionalDate('date', dates),
      notes,
      defaultBreak: json.number('defaultBreak'),
      exits: json.array('exits', (item, itemPath) => PlannedExit.decode(item, itemPath)),
      rawText: json.string('rawText'),
      commonEarlyEntries,
    }
  },
}
