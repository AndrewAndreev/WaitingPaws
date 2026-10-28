// The trainer's text, line by line, and what `PlanParser` made of each line (port of `MacPlanTextLine` and
// `MacPlanLineMap`). Classified with the parser's own patterns (exit line, «Перерыв N» after an exit, a line about
// all breaks, the first line as the header), plus the false-start rule («🔖 Фальстарт: …»), which the parser keeps
// as a note. Conditions for coming back early and the «не входить» rule come from `PlanParser.sourceLines`, which
// also knows which exit a condition belongs to.
import { DurationText } from '@core/durationText'
import type { EarlyEntryTone, TrainingPlan } from '@core/models'
import { PlanParser } from '@core/planParser'
import { trimWhitespaces } from '@core/text'

export type PlanLineKind =
  | { kind: 'header' }
  /// `ordinal`: position among the exit lines = index of the exit in the parsed plan.
  | { kind: 'exit'; number: number; ordinal: number }
  /// «Перерыв 5 минут»: own break of the exit on line `afterLine`.
  | { kind: 'ownBreak'; afterLine: number }
  /// «➡️ Все перерывы 2 минуты».
  | { kind: 'defaultBreak' }
  /// «🔖 Фальстарт: …».
  | { kind: 'rule' }
  /// «🟡 Если встала и пошла - входим через 2 минуты…»: right under the exit on line `afterLine`, or common
  /// (`afterLine` null).
  | { kind: 'earlyEntry'; tone: EarlyEntryTone; afterLine: number | null }
  /// «🚩 Если залаяла, завыла - ни в коем случае не входить…».
  | { kind: 'doNotEnter' }
  | { kind: 'note' }
  | { kind: 'blank' }

export interface PlanTextLine {
  /// 1-based line number.
  id: number
  text: string
  kind: PlanLineKind
}

export const PlanLine = {
  isExit: (line: PlanTextLine) => line.kind.kind === 'exit',
  isBreak: (line: PlanTextLine) => line.kind.kind === 'ownBreak' || line.kind.kind === 'defaultBreak',
  /// Lines marked in the gutter.
  isRecognised: (line: PlanTextLine) => ['exit', 'ownBreak', 'defaultBreak', 'rule', 'earlyEntry', 'doNotEnter'].includes(line.kind.kind),
  /// The exit line an own break or a condition under an exit belongs to.
  ownerLine: (line: PlanTextLine): number | null =>
    line.kind.kind === 'ownBreak' ? line.kind.afterLine : line.kind.kind === 'earlyEntry' ? line.kind.afterLine : null,
}

/// Unlike `splitLines` (Foundation's `.newlines`), CRLF is one line break: Windows clipboards use it.
const lineBreaks = /\r\n|[\n\u000B\u000C\r\u0085\u2028\u2029]/u

export function classifyLines(text: string): PlanTextLine[] {
  const result: PlanTextLine[] = []
  let contentIndex = 0
  let exitOrdinal = 0
  let lastExitLine: number | null = null
  const rows = text.split(lineBreaks)
  while (rows.length && trimWhitespaces(rows[rows.length - 1]) === '') rows.pop()
  // The parser's own reading of the same rows: a row is one or more of its lines (a bullet in the middle of a row
  // starts a line), its blank rows at the start are left out.
  const source = PlanParser.sourceLines(rows.join('\n'))
  let sourceIndex = 0
  const exitLineOfNumber = new Map<number, number>()
  rows.forEach((raw, index) => {
    const id = index + 1
    const line = trimWhitespaces(raw)
    if (line === '') {
      if (sourceIndex > 0) sourceIndex += 1
      result.push({ id, text: '', kind: { kind: 'blank' } })
      return
    }
    const parts = source.slice(sourceIndex, sourceIndex + PlanParser.lines(raw).length)
    sourceIndex += parts.length
    const stripped = PlanParser.stripDecorations(line)
    // A row of decorations only («➡️») is not content, as in `PlanParser.sourceLines`: it is no header.
    if (stripped === '') {
      result.push({ id, text: line, kind: { kind: 'note' } })
      return
    }
    const lower = stripped.toLowerCase()
    let kind: PlanLineKind
    const exit = PlanParser.parseExit(stripped)
    if (exit) {
      kind = { kind: 'exit', number: exit.number, ordinal: exitOrdinal++ }
      lastExitLine = id
      exitLineOfNumber.set(exit.number, id)
    } else if (PlanParser.isExitBreak(lower) && lastExitLine !== null && DurationText.sumOfUnits(stripped) !== null) {
      kind = { kind: 'ownBreak', afterLine: lastExitLine }
    } else if (PlanParser.commonBreak(stripped) !== null) {
      kind = { kind: 'defaultBreak' }
    } else if (contentIndex === 0) {
      kind = { kind: 'header' }
    } else if (isRule(line)) {
      kind = { kind: 'rule' }
    } else {
      kind = { kind: 'note' }
    }
    if (kind.kind === 'note') {
      const entry = parts.find((part) => part.kind === 'earlyEntry')
      if (entry) {
        const tone = PlanParser.parseEarlyEntry(entry.text)?.tone ?? 'plain'
        kind = { kind: 'earlyEntry', tone, afterLine: entry.exitNumber === null ? null : exitLineOfNumber.get(entry.exitNumber) ?? null }
      } else if (parts.some((part) => part.kind === 'doNotEnter')) {
        kind = { kind: 'doNotEnter' }
      }
    }
    contentIndex += 1
    result.push({ id, text: line, kind })
  })
  return result
}

/// «🔖 Фальстарт: …», «Фальстарт — …», "False start: …".
export function isRule(line: string): boolean {
  return PlanParser.hasMark(line, '🔖') || PlanParser.isFalseStartRule(PlanParser.stripDecorations(line).toLowerCase())
}

// MARK: - Highlighting

export type PlanTextRole = 'plain' | 'dim' | 'label' | 'duration' | 'pause' | 'flag' | 'title' | 'rule' | 'trigger' | 'delay' | 'stop'

export interface PlanTextRun {
  text: string
  role: PlanTextRole
}

// Russian and English (the Mac app marks Russian units only).
const durationRegex = /\d+(?:[.,]\d+)?\s*(?:час\p{L}*|мин\p{L}*|сек\p{L}*|hour\p{L}*|hr\p{L}*|min\p{L}*|sec\p{L}*)/giu
const exitLabelRegex =
  /\d+(?:st|nd|rd|th)?\s*[-–—.)]?\s*(?:выход|exit|departure)\p{L}*|(?:выход|exit|departure)\p{L}*\s*(?:№|#|no\.?)?\s*\d+/iu
const standingRegex = /или\s+до\s+вставания|пока\s+не\s+встанет|or\s+until\s+(?:the\s+dog\s+|she\s+|he\s+|it\s+)?stands?(?:\s+up)?/iu
/// «+ куртка», «+ взять ключи, звякнуть ими»: a trigger after a plus sign, up to the next one.
const triggerRegex = /\+\s*([^+]*[^+\s])/gu

/// The line split into coloured runs: durations of exits pink, breaks blue, the rule's head orange, notes dimmed.
export function highlightLine(line: PlanTextLine): PlanTextRun[] {
  const text = line.text
  const marks: { start: number; end: number; role: PlanTextRole }[] = []
  const add = (start: number, end: number, role: PlanTextRole) => marks.push({ start, end, role })
  const durations = (role: PlanTextRole) => {
    for (const match of text.matchAll(durationRegex)) add(match.index, match.index + match[0].length, role)
  }
  let base: PlanTextRole = 'dim'
  switch (line.kind.kind) {
    case 'blank':
      return []
    case 'note':
      base = 'dim'
      break
    case 'header': {
      // «Название - Тренеры - Дата»: the parser splits on any dash between spaces.
      base = 'plain'
      const ends = [' - ', ' – ', ' — '].map((dash) => text.indexOf(dash)).filter((index) => index >= 0)
      add(0, ends.length ? Math.min(...ends) : text.length, 'title')
      break
    }
    case 'rule': {
      base = 'dim'
      const colon = text.indexOf(':')
      if (colon >= 0) add(0, colon + 1, 'rule')
      else base = 'rule'
      break
    }
    case 'exit': {
      base = 'dim'
      const label = exitLabelRegex.exec(text)
      if (label) add(label.index, label.index + label[0].length, 'label')
      durations('duration')
      const flag = standingRegex.exec(text)
      if (flag) add(flag.index, flag.index + flag[0].length, 'flag')
      for (const match of text.matchAll(triggerRegex)) {
        const start = match.index + match[0].length - match[1].length
        add(start, start + match[1].length, 'trigger')
      }
      break
    }
    case 'earlyEntry':
      // The time to come back after, in the condition's colour.
      base = 'plain'
      durations('delay')
      break
    case 'doNotEnter': {
      // «🚩 Если залаяла, завыла -» red, the rest dimmed.
      base = 'dim'
      const dash = [' - ', ' – ', ' — '].map((mark) => text.indexOf(mark)).filter((index) => index >= 0)
      add(0, dash.length ? Math.min(...dash) : text.length, 'stop')
      break
    }
    case 'ownBreak':
    case 'defaultBreak':
      base = line.kind.kind === 'defaultBreak' ? 'dim' : 'pause'
      durations('pause')
      break
  }
  marks.sort((a, b) => a.start - b.start)
  const runs: PlanTextRun[] = []
  const push = (start: number, end: number, role: PlanTextRole) => {
    if (end > start) runs.push({ text: text.slice(start, end), role })
  }
  let cursor = 0
  for (const mark of marks) {
    if (mark.start < cursor) continue
    push(cursor, mark.start, base)
    push(mark.start, mark.end, mark.role)
    cursor = mark.end
  }
  push(cursor, text.length, base)
  return runs
}

// MARK: - Which line each exit came from

/// The parsed exits follow the exit lines in order; the link is remembered per plan, so it survives reordering,
/// deleting and re-opening the dialog. Exits added by hand have no line.
const lineMapCache = new Map<string, Map<string, number>>()

export function exitLines(plan: TrainingPlan, lines: PlanTextLine[]): Map<string, number> {
  const known = lineMapCache.get(plan.id)
  if (known) return known
  const exitRows = lines.filter(PlanLine.isExit)
  if (!exitRows.length) return new Map()
  if (exitRows.length === plan.exits.length) {
    const map = new Map(plan.exits.map((exit, index) => [exit.id, exitRows[index].id]))
    lineMapCache.set(plan.id, map)
    return map
  }
  // Edited before the first look: match by the number written in the text.
  const map = new Map<string, number>()
  for (const exit of plan.exits) {
    const row = exitRows.find((line) => line.kind.kind === 'exit' && line.kind.number === exit.number)
    if (row) map.set(exit.id, row.id)
  }
  return map
}

/// Lines of the selected exits, their own breaks and conditions (highlighted in the text).
export function linkedLines(lines: PlanTextLine[], lineOfExit: Map<string, number>, selection: Iterable<string>): Set<number> {
  const exitLineIds = new Set<number>()
  for (const id of selection) {
    const line = lineOfExit.get(id)
    if (line !== undefined) exitLineIds.add(line)
  }
  const result = new Set(exitLineIds)
  for (const line of lines) {
    const owner = PlanLine.ownerLine(line)
    if (owner !== null && exitLineIds.has(owner)) result.add(line.id)
  }
  return result
}

/// Click on an exit line (or its own break, a condition under it): the exit to select in the table.
export function exitForLine(line: PlanTextLine, plan: TrainingPlan, lineOfExit: Map<string, number>): string | null {
  const target = line.kind.kind === 'exit' ? line.id : PlanLine.ownerLine(line)
  if (target === null) return null
  for (const [id, row] of lineOfExit) {
    if (row === target && plan.exits.some((exit) => exit.id === id)) return id
  }
  return null
}
