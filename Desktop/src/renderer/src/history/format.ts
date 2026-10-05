// Texts of the History page (MacHistoryFormat): days, time ranges, counts.
import { plural } from '@shared/i18n'
import { formatDate } from '@core/localization'
import { formatTime } from '../model'
import { rowEnd, type HistoryRow } from './logic'

function capitalized(text: string): string {
  return text.charAt(0).toLocaleUpperCase() + text.slice(1)
}

/// "Пт, 2 окт." / "Fri, Oct 2" (the year is added for older entries).
export function dayText(ms: number, now = Date.now()): string {
  const sameYear = new Date(ms).getFullYear() === new Date(now).getFullYear()
  return capitalized(formatDate(ms, sameYear ? 'EEdMMM' : 'EEdMMMyyyy'))
}

/// "2 окт." / "Oct 2".
export function dayMonth(ms: number): string {
  return formatDate(ms, 'dMMM')
}

/// "19:12–19:30" (or just the start while a recording's length is unknown).
export function timeRange(row: HistoryRow): string {
  const end = rowEnd(row)
  const start = formatTime(row.date)
  return end === null ? start : `${start}–${formatTime(end)}`
}

/// "Пятница, 2 октября, 18:36–19:02".
export function longDay(row: HistoryRow): string {
  return `${capitalized(formatDate(row.date, 'EEEEdMMMM'))}, ${timeRange(row)}`
}

/// "1 тренировка", "11 тренировок" / "1 training", "11 trainings".
export function trainingsText(n: number): string {
  return plural(n, ['%d тренировка', '%d тренировки', '%d тренировок'], ['%d training', '%d trainings'])
}

/// Accusative for «Удалить 1 тренировку».
export function trainingsAccusative(n: number): string {
  return plural(n, ['%d тренировку', '%d тренировки', '%d тренировок'], ['%d training', '%d trainings'])
}

/// "1 запись", "3 записи" / "1 recording", "3 recordings".
export function recordingsText(n: number): string {
  return plural(n, ['%d запись', '%d записи', '%d записей'], ['%d recording', '%d recordings'])
}
