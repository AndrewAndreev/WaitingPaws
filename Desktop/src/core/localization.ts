// Port of Localization/CoreLanguage.swift.
//
// Language of the texts the core writes: the trainer's log, durations, event names, camera settings, errors.
// It follows the app's UI language: Russian on Russian devices, English everywhere else. The parser reads
// schedules in both languages whatever this is.
//
// The current language is process-wide (like `CoreLanguage.current`): set it once at start-up with
// `setCoreLanguage` (the Electron main process and the renderer each have their own copy). Only `Intl` is
// used, so this runs in Electron main, the renderer and a plain browser.

export type CoreLanguage = 'ru' | 'en'

export const CORE_LANGUAGES: readonly CoreLanguage[] = ['ru', 'en']

let current: CoreLanguage = detectCoreLanguage()
/** `undefined`: detect from the default `Intl` locale; `null`: no region (ru_RU / en_US). */
let region: string | null | undefined

/** The language the core writes in (`CoreLanguage.current`). */
export function coreLanguage(): CoreLanguage {
  return current
}

export function setCoreLanguage(language: CoreLanguage): void {
  current = language
}

/**
 * The app's language for the user's preferred languages (`Bundle.preferredLocalizations`: the first
 * preferred language the app has, English otherwise). Defaults to `navigator.languages` or the `Intl` locale.
 */
export function detectCoreLanguage(preferred: readonly string[] = preferredLanguages()): CoreLanguage {
  for (const tag of preferred) {
    const lower = tag.toLowerCase()
    if (lower.startsWith('ru')) return 'ru'
    if (lower.startsWith('en')) return 'en'
  }
  return 'en'
}

function preferredLanguages(): string[] {
  const navigator = (globalThis as { navigator?: { languages?: readonly string[]; language?: string } }).navigator
  if (navigator?.languages?.length) return [...navigator.languages]
  if (navigator?.language) return [navigator.language]
  try {
    return [Intl.DateTimeFormat().resolvedOptions().locale]
  } catch {
    return []
  }
}

/**
 * The device's region ("US", "GB", "RU"…) used for date formats (en_GB writes 05/10/2026, en_US 10/05/2026).
 * The Electron main process should pass the OS region (`app.getSystemLocale()`); `null` means none.
 */
export function setCoreRegion(value: string | null): void {
  region = value ? value.toUpperCase() : null
  formatters.clear()
}

/** The device's region, or `null` when unknown (`Locale.current.region`). */
export function coreRegion(): string | null {
  if (region === undefined) {
    try {
      region = new Intl.Locale(Intl.DateTimeFormat().resolvedOptions().locale).region?.toUpperCase() ?? null
    } catch {
      region = null
    }
  }
  return region
}

/** BCP 47 locale for dates and numbers in `language` with the device's region: "ru-RU", "en-GB". */
export function coreLocale(language: CoreLanguage = current): string {
  const fallback = language === 'ru' ? 'ru-RU' : 'en-US'
  const deviceRegion = coreRegion()
  if (!deviceRegion) return fallback
  try {
    return Intl.getCanonicalLocales(`${language}-${deviceRegion}`)[0] ?? fallback
  } catch {
    return fallback
  }
}

/** The Russian or the English text, for the current language. */
export function tr(ru: string, en: string): string {
  return current === 'ru' ? ru : en
}

/** "1 выход", "3 выхода", "5 выходов" / "1 exit", "2 exits". */
export function pluralText(
  count: number,
  ru: { one: string; few: string; many: string },
  en: { one: string; other: string },
): string {
  if (current === 'ru') {
    const mod10 = count % 10
    const mod100 = count % 100
    const word =
      mod10 === 1 && mod100 !== 11
        ? ru.one
        : mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14)
          ? ru.few
          : ru.many
    return `${count} ${word}`
  }
  return `${count} ${count === 1 ? en.one : en.other}`
}

// MARK: - Dates

const formatters = new Map<string, Intl.DateTimeFormat>()

/**
 * A formatter for an ICU skeleton `template` in `language` (`CoreLanguage.dateFormatter(_:)`, which uses
 * `setLocalizedDateFormatFromTemplate`). Supported skeleton letters: y, M/L, d, E, j, H/k, h/K, m, s —
 * e.g. "ddMMyyyy" → "05.10.2026" / "10/05/2026", "jmm" → "18:00" / "6:00 PM", "dMMM", "EEdMMMyyyy".
 * Times are in the local time zone.
 */
export function dateFormatter(template: string, language: CoreLanguage = current): Intl.DateTimeFormat {
  const locale = coreLocale(language)
  const key = `${locale}|${template}`
  let formatter = formatters.get(key)
  if (!formatter) {
    formatter = new Intl.DateTimeFormat(locale, skeletonOptions(template))
    formatters.set(key, formatter)
  }
  return formatter
}

/** Formats epoch milliseconds with a skeleton `template` (see `dateFormatter`). */
export function formatDate(ms: number, template: string, language: CoreLanguage = current): string {
  return dateFormatter(template, language).format(ms)
}

function skeletonOptions(template: string): Intl.DateTimeFormatOptions {
  const options: Intl.DateTimeFormatOptions = {}
  for (const [run] of template.matchAll(/([A-Za-z])\1*/g)) {
    const width = run.length
    switch (run[0]) {
      case 'y':
        options.year = width === 2 ? '2-digit' : 'numeric'
        break
      case 'M':
      case 'L':
        options.month = (['numeric', '2-digit', 'short', 'long', 'narrow'] as const)[Math.min(width, 5) - 1]
        break
      case 'd':
        options.day = width >= 2 ? '2-digit' : 'numeric'
        break
      case 'E':
        options.weekday = width === 4 ? 'long' : width >= 5 ? 'narrow' : 'short'
        break
      case 'j':
        // The language's clock, as the UI writes times: Russian is 18:00 in any region, en-US 6:00 PM, en-GB 18:00.
        // (ICU's `j` on the Mac takes the region's instead: ru_US would write "6:00 PM".)
        options.hour = width >= 2 ? '2-digit' : 'numeric'
        break
      case 'H':
      case 'k':
        options.hour = width >= 2 ? '2-digit' : 'numeric'
        options.hourCycle = 'h23'
        break
      case 'h':
      case 'K':
        options.hour = width >= 2 ? '2-digit' : 'numeric'
        options.hour12 = true
        break
      case 'm':
        options.minute = '2-digit'
        break
      case 's':
        options.second = '2-digit'
        break
    }
  }
  return options
}
