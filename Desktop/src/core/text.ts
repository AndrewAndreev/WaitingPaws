// String helpers that reproduce the Foundation behaviour the Swift core relies on (character sets of
// `trimmingCharacters(in:)`, `components(separatedBy: .newlines)`, `Int(String)` / `Double(String)`,
// `rounded()`), so the parser and the formatters give the same results as on the Mac and iPhone.

/** `CharacterSet.whitespaces`: Unicode Zs plus tab (no newlines). */
const whitespaces = '\\t\\p{Zs}'
/** `CharacterSet.newlines`: U+000A…U+000D, U+0085, U+2028, U+2029. */
const newlines = '\\n\\u000B\\u000C\\r\\u0085\\u2028\\u2029'

const trimWhitespacesRegex = new RegExp(`^[${whitespaces}]+|[${whitespaces}]+$`, 'gu')
const trimAllRegex = new RegExp(`^[${whitespaces}\\p{Z}${newlines}]+|[${whitespaces}\\p{Z}${newlines}]+$`, 'gu')
const newlinesRegex = new RegExp(`[${newlines}]`, 'u')

/** `trimmingCharacters(in: .whitespaces)`. */
export function trimWhitespaces(text: string): string {
  return text.replace(trimWhitespacesRegex, '')
}

/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
export function trimWhitespacesAndNewlines(text: string): string {
  return text.replace(trimAllRegex, '')
}

/** `trimmingCharacters(in: .whitespaces + extra characters)`, e.g. `trimCharacters(text, '-')`. */
export function trimWhitespacesAnd(text: string, extra: string): string {
  const escaped = extra.replace(/[\\\]^-]/g, '\\$&')
  return text.replace(new RegExp(`^[${whitespaces}${escaped}]+|[${whitespaces}${escaped}]+$`, 'gu'), '')
}

/** `components(separatedBy: .newlines)`: every newline character separates (CRLF gives an empty component). */
export function splitLines(text: string): string[] {
  return text.split(newlinesRegex)
}

/** `Int(String)`: optional sign and ASCII digits only, no spaces. */
export function parseSwiftInt(text: string): number | null {
  if (!/^[+-]?\d+$/.test(text)) return null
  const value = Number(text)
  return Number.isSafeInteger(value) ? value : null
}

/** `Double(String)` for decimal input ("90", "1.5", "-2e3"); no spaces. */
export function parseSwiftDouble(text: string): number | null {
  if (!/^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(text)) return null
  return Number(text)
}

/** `Double.rounded()`: to nearest, halves away from zero (Math.round sends -2.5 to -2). */
export function roundHalfAwayFromZero(value: number): number {
  return value < 0 ? -Math.round(-value) : Math.round(value)
}

/** `String(format: "%02d", value)`. */
export function pad2(value: number): string {
  return String(value).padStart(2, '0')
}
