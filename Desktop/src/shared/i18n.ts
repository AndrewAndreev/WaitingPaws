/// UI strings: the English text is the key (as in the Swift code and `Localizable.xcstrings`), Russian comes
/// from the same translation table the Mac/iPhone apps use (`Tools/strings/ru.json`) plus the strings that exist
/// only on Windows and the Web (`strings/*.ru.json`, one file per area). Swift format specifiers are kept in the
/// keys: `t('Start Exit %lld', 3)`, `t('%@ · plan %@', a, b)`. A key with a context after `|` (`'Cancel|verb'`)
/// is a second Russian text for the same English one; English shows the text before the `|`.
import shared from '../../../Tools/strings/ru.json'

const desktop = Object.assign(
  {},
  ...Object.values(import.meta.glob<Record<string, string>>('./strings/*.ru.json', { eager: true, import: 'default' })),
) as Record<string, string>

export type Language = 'ru' | 'en'

const russian: Record<string, string> = { ...(shared as Record<string, string>), ...desktop }
let current: Language = 'ru'
const listeners = new Set<(language: Language) => void>()

export function systemLanguage(): Language {
  const languages = typeof navigator !== 'undefined' ? navigator.languages ?? [navigator.language] : []
  const preferred = languages[0] ?? Intl.DateTimeFormat().resolvedOptions().locale
  return preferred.toLowerCase().startsWith('ru') ? 'ru' : 'en'
}

export function setLanguage(language: Language): void {
  if (language === current) return
  current = language
  for (const listener of listeners) listener(language)
}

export function language(): Language {
  return current
}

export function onLanguageChange(listener: (language: Language) => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

/// Translates an English key and fills in Swift-style specifiers (%@, %lld, %d, %.0f, %1$@ …).
export function t(key: string, ...args: unknown[]): string {
  const template = current === 'en' ? english(key) : russian[key] ?? english(key)
  return format(template, args)
}

/// The English text of a key: the key itself, without a context ('Cancel|verb' → 'Cancel').
function english(key: string): string {
  const bar = key.indexOf('|')
  return bar < 0 ? key : key.slice(0, bar)
}

/// Picks the English or Russian text directly (strings that are not worth a table entry).
export function tr(en: string, ru: string): string {
  return current === 'en' ? en : ru
}

const specifier = /%(?:(\d+)\$)?(@|lld|ld|d|i|u|(?:\.(\d+))?f|%)/g

export function format(template: string, args: unknown[]): string {
  let index = 0
  return template.replace(specifier, (_match, position: string | undefined, kind: string, precision: string | undefined) => {
    if (kind === '%') return '%'
    const value = args[position ? Number(position) - 1 : index++]
    if (kind.endsWith('f')) {
      const number = Number(value)
      const digits = precision ? Number(precision) : 6
      return Number.isFinite(number) ? number.toFixed(digits) : String(value)
    }
    if (kind === '@') return value === undefined || value === null ? '' : String(value)
    const number = Number(value)
    return Number.isFinite(number) ? String(Math.trunc(number)) : String(value)
  })
}

/// English plural forms (one, other) / Russian (one, few, many).
export function plural(n: number, en: [string, string], ru: [string, string, string]): string {
  if (current === 'en') return (Math.abs(n) === 1 ? en[0] : en[1]).replace('%d', String(n))
  const mod10 = Math.abs(n) % 10
  const mod100 = Math.abs(n) % 100
  const form = mod10 === 1 && mod100 !== 11 ? ru[0] : mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14) ? ru[1] : ru[2]
  return form.replace('%d', String(n))
}
