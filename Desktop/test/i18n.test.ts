import { afterEach, describe, expect, it } from 'vitest'
import { format, plural, setLanguage, t } from '@shared/i18n'
import shared from '../../Tools/strings/en.json'

const desktop = import.meta.glob<Record<string, string>>('../src/shared/strings/*.en.json', { eager: true, import: 'default' })

describe('UI strings', () => {
  afterEach(() => setLanguage('ru'))

  it('fills Swift format specifiers', () => {
    expect(format('Начать выход %lld', [3])).toBe('Начать выход 3')
    expect(format('%@ · план %@', ['a', 'b'])).toBe('a · план b')
    expect(format('%2$@ then %1$@', ['a', 'b'])).toBe('b then a')
    expect(format('%.0f МБ', [12.6])).toBe('13 МБ')
    expect(format('100%%', [])).toBe('100%')
  })

  it('translates Russian keys from the shared Mac table and the desktop files', () => {
    setLanguage('en')
    expect(t('Начать выход %lld', 2)).toBe('Start Exit 2')
    expect(t('Показать в проводнике')).toBe('Show in Explorer')
    // Positional English for a key with plain specifiers.
    expect(t('%@ · план %@', '1:00', '2:00')).toBe('1:00 · plan 2:00')
    // Unknown keys fall back to the Russian text.
    expect(t('Нет такого ключа')).toBe('Нет такого ключа')
  })

  it('keeps one English text per key: the desktop files only add keys the shared table lacks', () => {
    const redefined = Object.entries(desktop).flatMap(([file, table]) =>
      Object.keys(table).filter((key) => key in shared).map((key) => `${file}: ${key}`))
    expect(Object.keys(desktop).length).toBeGreaterThan(0)
    expect(redefined).toEqual([])
  })

  it('picks Russian and English plural forms', () => {
    const forms: [[string, string, string], [string, string]] = [['%d выход', '%d выхода', '%d выходов'], ['%d exit', '%d exits']]
    expect([1, 2, 5, 11, 21, 22, 25].map((n) => plural(n, ...forms))).toEqual(['1 выход', '2 выхода', '5 выходов', '11 выходов', '21 выход', '22 выхода', '25 выходов'])
    setLanguage('en')
    expect([1, 2].map((n) => plural(n, ...forms))).toEqual(['1 exit', '2 exits'])
  })
})
