// Plan wording and editing shared by the schedule review dialog and the plan timeline (port of `MacPlanFormat`
// and the editing helpers of `MacPlanReviewSheet`). Pure functions over plain `TrainingPlan` objects: every
// edit returns a new plan, numbers are rewritten 1…n after anything that changes the order.
import { plural, t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { coreLocale } from '@core/localization'
import { EarlyEntry, PlannedExit, TrainingPlan } from '@core/models'
import { roundHalfAwayFromZero } from '@core/text'

export const PlanFormat = {
  /// "2 мин", "1:30" when minutes and seconds mix, "45 с".
  cell(seconds: number): string {
    const total = DurationText.wholeSeconds(seconds)
    return total >= 60 && total % 60 !== 0 ? DurationText.clock(seconds) : DurationText.short(seconds)
  },

  /// "≈ 28 мин" for summaries (seconds dropped from ten minutes up).
  approx(seconds: number): string {
    const total = DurationText.wholeSeconds(seconds)
    if (total >= 600) return t('≈ %lld мин', roundHalfAwayFromZero(total / 60))
    return '≈ ' + DurationText.short(seconds)
  },

  /// "+0:30", "−1:00".
  signed(delta: number): string {
    return (delta < 0 ? '−' : '+') + DurationText.clock(Math.abs(delta))
  },

  exits: (n: number) => plural(n, ['%d выход', '%d выхода', '%d выходов'], ['%d exit', '%d exits']),
  breaks: (n: number) => plural(n, ['%d перерыв', '%d перерыва', '%d перерывов'], ['%d break', '%d breaks']),
  notes: (n: number) => plural(n, ['%d заметка', '%d заметки', '%d заметок'], ['%d note', '%d notes']),
  lines: (n: number) => plural(n, ['%d строка', '%d строки', '%d строк'], ['%d line', '%d lines']),
  triggers: (n: number) => plural(n, ['%d триггер', '%d триггера', '%d триггеров'], ['%d trigger', '%d triggers']),
  conditions: (n: number) => plural(n, ['%d условие', '%d условия', '%d условий'], ['%d condition', '%d conditions']),

  /// «через 2:00» / «сразу»: when to come back after the dog did it.
  entryDelay(entry: EarlyEntry): string {
    if (entry.delay !== null && entry.delay > 0) return t('через %@', DurationText.clock(entry.delay))
    return EarlyEntry.unreadDelay(entry) ?? t('сразу')
  },

  /// «встала и пошла → через 2:00» (the common conditions in the bar above the table).
  entryLine(entry: EarlyEntry): string {
    const [first = '', ...rest] = Array.from(entry.event)
    return `${first.toLowerCase()}${rest.join('')} → ${PlanFormat.entryDelay(entry)}`
  },

  /// Delays offered for a condition: right away to five minutes.
  entryPresets: [0, 10, 15, 20, 30, 40, 60, 90, 120, 180, 300] as readonly number[],

  exitsTotal(plan: TrainingPlan): number {
    return plan.exits.reduce((sum, exit) => sum + exit.duration, 0)
  },

  breaksTotal(plan: TrainingPlan): number {
    return TrainingPlan.estimatedDuration(plan) - PlanFormat.exitsTotal(plan)
  },

  /// Seconds from the start of the training to the start of the exit at `index`.
  start(index: number, plan: TrainingPlan): number {
    let time = 0
    for (let i = 0; i < Math.min(index, plan.exits.length); i++) time += plan.exits[i].duration + TrainingPlan.breakAfter(plan, i)
    return time
  },

  /// Exit durations offered in the editor (from «выйти и вернуться» to ten minutes).
  exitPresets: [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600] as readonly number[],
  /// Breaks between exits.
  breakPresets: [60, 90, 120, 180, 240, 300, 420, 600, 900] as readonly number[],

  /// "Фальстарт: если пошла…" → "Если пошла…".
  ruleBody(text: string): string {
    const body = text.split(':').slice(1).join(':').trim()
    const value = body === '' ? text : body
    return value.slice(0, 1).toUpperCase() + value.slice(1)
  },

  /// «a, b и c» / "a, b, and c" in the app's language.
  list(parts: string[]): string {
    try {
      return new Intl.ListFormat(coreLocale(), { type: 'conjunction', style: 'long' }).format(parts)
    } catch {
      return parts.join(', ')
    }
  },

  capitalizedFirst(text: string): string {
    return text.slice(0, 1).toUpperCase() + text.slice(1)
  },
}

/// The result of an edit that also moves the table selection.
export interface PlanEdit {
  plan: TrainingPlan
  selection: string[]
}

function renumbered(plan: TrainingPlan, exits: PlannedExit[]): TrainingPlan {
  return TrainingPlan.renumbered({ ...plan, exits })
}

/// Exits that set their own break (the last exit's break never plays).
export function ownBreaks(plan: TrainingPlan): PlannedExit[] {
  return plan.exits.slice(0, -1).filter((exit) => exit.breakAfter !== null)
}

/// Indices of the selected exits, in plan order.
export function selectedIndices(plan: TrainingPlan, selection: Iterable<string>): number[] {
  const ids = new Set(selection)
  return plan.exits.flatMap((exit, index) => (ids.has(exit.id) ? [index] : []))
}

export function updateExit(plan: TrainingPlan, id: string, patch: Partial<Omit<PlannedExit, 'id'>>): TrainingPlan {
  return { ...plan, exits: plan.exits.map((exit) => (exit.id === id ? { ...exit, ...patch } : exit)) }
}

/// A new exit after the last selected one (or at the end) with the duration of the exit above it.
export function addExit(plan: TrainingPlan, selection: Iterable<string>): PlanEdit {
  const indices = selectedIndices(plan, selection)
  const index = indices.length ? indices[indices.length - 1] : plan.exits.length - 1
  const template = index >= 0 ? plan.exits[index] : undefined
  const exit = PlannedExit.make({ number: 0, duration: template?.duration ?? 30 })
  const exits = [...plan.exits]
  exits.splice(index + 1, 0, exit)
  return { plan: renumbered(plan, exits), selection: [exit.id] }
}

/// Copies of the selected exits (new ids) right after the last selected one.
export function duplicateExits(plan: TrainingPlan, selection: Iterable<string>): PlanEdit | null {
  const indices = selectedIndices(plan, selection)
  if (!indices.length) return null
  const copies = indices.map((index) => ({ ...plan.exits[index], id: PlannedExit.make({ number: 0, duration: 0 }).id }))
  const exits = [...plan.exits]
  exits.splice(indices[indices.length - 1] + 1, 0, ...copies)
  return { plan: renumbered(plan, exits), selection: copies.map((exit) => exit.id) }
}

/// Removes the selected exits; at least one exit stays (a plan without exits cannot start). The row that takes the
/// place of the first removed one becomes selected.
export function deleteExits(plan: TrainingPlan, selection: Iterable<string>): PlanEdit | null {
  const indices = selectedIndices(plan, selection)
  if (!indices.length || plan.exits.length <= indices.length) return null
  const removed = new Set(indices)
  const exits = plan.exits.filter((_, index) => !removed.has(index))
  const next = exits[Math.min(indices[0], exits.length - 1)]
  return { plan: renumbered(plan, exits), selection: next ? [next.id] : [] }
}

export function canDelete(plan: TrainingPlan, selection: Iterable<string>): boolean {
  const count = selectedIndices(plan, selection).length
  return count > 0 && plan.exits.length > count
}

/// Swift's `Array.move(fromOffsets:toOffset:)`: the elements at `offsets` (kept in order) land before the element
/// that was at `toOffset` (0…count).
export function moveOffsets<T>(items: readonly T[], offsets: readonly number[], toOffset: number): T[] {
  const set = new Set(offsets)
  const moving = items.filter((_, index) => set.has(index))
  const rest = items.filter((_, index) => !set.has(index))
  const before = [...set].filter((index) => index < toOffset).length
  rest.splice(Math.max(0, Math.min(rest.length, toOffset - before)), 0, ...moving)
  return rest
}

/// Drag and drop: the exits with `ids` before the row that was at `toOffset`.
export function moveExits(plan: TrainingPlan, ids: Iterable<string>, toOffset: number): TrainingPlan {
  const offsets = selectedIndices(plan, ids)
  if (!offsets.length) return plan
  const exits = moveOffsets(plan.exits, offsets, Math.min(Math.max(0, toOffset), plan.exits.length))
  if (exits.every((exit, index) => exit === plan.exits[index])) return plan
  return renumbered(plan, exits)
}

/// «Выше» / «Ниже»: the selected block one row up or down.
export function shiftExits(plan: TrainingPlan, selection: Iterable<string>, delta: -1 | 1): TrainingPlan | null {
  if (!canShift(plan, selection, delta)) return null
  const indices = selectedIndices(plan, selection)
  const destination = delta < 0 ? indices[0] - 1 : indices[indices.length - 1] + 2
  return renumbered(plan, moveOffsets(plan.exits, indices, destination))
}

export function canShift(plan: TrainingPlan, selection: Iterable<string>, delta: -1 | 1): boolean {
  const indices = selectedIndices(plan, selection)
  if (!indices.length) return false
  return delta < 0 ? indices[0] > 0 : indices[indices.length - 1] < plan.exits.length - 1
}

// MARK: - Triggers and conditions of one exit

export function addTrigger(plan: TrainingPlan, id: string, text: string): TrainingPlan {
  const trigger = text.trim()
  const exit = plan.exits.find((item) => item.id === id)
  if (!exit || trigger === '' || exit.triggers.includes(trigger)) return plan
  return updateExit(plan, id, { triggers: [...exit.triggers, trigger] })
}

export function removeTrigger(plan: TrainingPlan, id: string, index: number): TrainingPlan {
  const exit = plan.exits.find((item) => item.id === id)
  if (!exit) return plan
  return updateExit(plan, id, { triggers: exit.triggers.filter((_, other) => other !== index) })
}

/// Triggers of the other exits this one has not got: offered as one-click chips.
export function suggestedTriggers(plan: TrainingPlan, id: string, limit = 4): string[] {
  const own = new Set(plan.exits.find((exit) => exit.id === id)?.triggers ?? [])
  const result: string[] = []
  for (const exit of plan.exits) {
    for (const trigger of exit.triggers) {
      if (!own.has(trigger) && !result.includes(trigger)) result.push(trigger)
    }
  }
  return result.slice(0, limit)
}

/// The conditions the editor lists for an exit: what `TrainingPlan.earlyEntries` gives, without «Встала → сразу» of
/// «ИЛИ до вставания» (the editor shows that one as a switch).
export function editableEntries(plan: TrainingPlan, exit: PlannedExit): EarlyEntry[] {
  const untilStanding = EarlyEntry.untilStanding().id
  return TrainingPlan.earlyEntries(plan, exit).filter((entry) => entry.id !== untilStanding)
}

/// An edit of the exit's conditions (`editableEntries` in, the new list out). The common conditions it shows become
/// its own copy first (`detachEarlyEntries`): the change is for this exit alone, the other exits keep the common ones.
export function editEarlyEntries(plan: TrainingPlan, id: string, edit: (entries: EarlyEntry[]) => EarlyEntry[]): TrainingPlan {
  const index = plan.exits.findIndex((exit) => exit.id === id)
  if (index < 0) return plan
  const detached = TrainingPlan.detachEarlyEntries(plan, index)
  return updateExit(detached, id, { earlyEntries: edit(detached.exits[index].earlyEntries), usesCommonEarlyEntries: false })
}

/// «Общие условия» of one exit: on — the plan's common conditions instead of its own; off — none.
export function setUsesCommonEntries(plan: TrainingPlan, id: string, value: boolean): TrainingPlan {
  return updateExit(plan, id, { earlyEntries: [], usesCommonEarlyEntries: value })
}

/// The dot of a condition cycles through the trainer's colours: 🟡 → 🟢 → none.
export function nextTone(tone: EarlyEntry['tone']): EarlyEntry['tone'] {
  return tone === 'yellow' ? 'green' : tone === 'green' ? 'plain' : 'yellow'
}

/// A new common break; own breaks that now equal it become common again (as `PlanParser` reads them).
export function setDefaultBreak(plan: TrainingPlan, value: number): TrainingPlan {
  return {
    ...plan,
    defaultBreak: value,
    exits: plan.exits.map((exit) => (exit.breakAfter === value ? { ...exit, breakAfter: null } : exit)),
  }
}

/// «Сделать везде 2 мин»: every exit follows the common break.
export function resetOwnBreaks(plan: TrainingPlan): TrainingPlan {
  return { ...plan, exits: plan.exits.map((exit) => (exit.breakAfter === null ? exit : { ...exit, breakAfter: null })) }
}

/// The break after one exit set from the editor: the common value means «как у всех».
export function setBreakAfter(plan: TrainingPlan, id: string, value: number | null): TrainingPlan {
  return updateExit(plan, id, { breakAfter: value === plan.defaultBreak ? null : value })
}

/// The schedule's date (epoch ms, noon local time) ↔ `<input type="date">` ("2026-10-04").
export function dateInputValue(ms: number | null, now = Date.now()): string {
  const date = new Date(ms ?? now)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${String(date.getFullYear()).padStart(4, '0')}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
}

export function dateFromInput(value: string): number | null {
  const match = /^(\d{4,})-(\d{2})-(\d{2})$/.exec(value)
  if (!match) return null
  const date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 12, 0, 0, 0)
  date.setFullYear(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
  return Number.isFinite(date.getTime()) ? date.getTime() : null
}

/// Minutes and seconds editing of the duration editor: steps of 5 s below a minute, 30 s from a minute up.
export function stepDuration(total: number, direction: 1 | -1, step = 5): number {
  if (direction > 0) return total + (total >= 60 ? 30 : step)
  return Math.max(0, total - (total > 60 ? 30 : step))
}

export function withMinutes(total: number, minutes: number): number {
  return Math.max(0, Math.min(120, Math.trunc(minutes))) * 60 + (total % 60)
}

export function withSeconds(total: number, seconds: number): number {
  return Math.floor(total / 60) * 60 + Math.max(0, Math.min(59, Math.trunc(seconds)))
}
