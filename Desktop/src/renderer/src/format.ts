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

/// «2 часа назад» / "2 hours ago", «сейчас» under a minute (the Mac's `.relative(presentation: .named)`).
export function relativeTime(time: number, now: number): string {
  const format = new Intl.RelativeTimeFormat(language() === 'ru' ? 'ru' : 'en', { numeric: 'auto' })
  const seconds = Math.round((time - now) / 1000)
  const size = Math.abs(seconds)
  if (size < 60) return format.format(0, 'second')
  if (size < 3600) return format.format(Math.round(seconds / 60), 'minute')
  if (size < 86400) return format.format(Math.round(seconds / 3600), 'hour')
  return format.format(Math.round(seconds / 86400), 'day')
}
