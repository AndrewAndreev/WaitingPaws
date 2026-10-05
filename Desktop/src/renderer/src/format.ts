import { language } from '@shared/i18n'

/// "12,3 МБ" / "12.3 MB".
export function formatBytes(bytes: number): string {
  const units = language() === 'ru' ? ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'] : ['B', 'KB', 'MB', 'GB', 'TB']
  let value = bytes
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit += 1
  }
  const digits = unit >= 2 && value < 100 ? 1 : 0
  return `${value.toLocaleString(language() === 'ru' ? 'ru-RU' : 'en-US', { maximumFractionDigits: digits })} ${units[unit]}`
}
