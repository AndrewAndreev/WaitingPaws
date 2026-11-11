import { t } from '@shared/i18n'
import type { LanguagePreference, ThemePreference } from '@shared/settings'
import { call, useApp } from '../store'
import { LanguageIcon, ThemeIcon } from '../ui/icons'
import { Group, PaneHeader, Row, Select } from './rows'

/// Оформление: light or dark, and the language of the app (and of the logs it writes).
export function AppearancePane() {
  const app = useApp()
  return (
    <>
      <PaneHeader title={t('Appearance')} description={t('The app’s theme and language.')} />
      <Group>
        <Row icon={<ThemeIcon />} title={t('Theme')} description={t('Light or dark, or the same as Windows.')}>
          <Select<ThemePreference>
            label={t('Theme')}
            value={app.settings.theme}
            options={[
              { value: 'system', label: t('Use system setting') },
              { value: 'light', label: t('Light') },
              { value: 'dark', label: t('Dark') },
            ]}
            onChange={(theme) => void call('settings.update', { theme })}
          />
        </Row>
        <Row icon={<LanguageIcon />} title={t('Language')} description={t('The interface and the logs for the trainer.')}>
          <Select<LanguagePreference>
            label={t('Language')}
            value={app.settings.language}
            options={[
              { value: 'system', label: t('Use system setting') },
              { value: 'ru', label: 'Русский' },
              { value: 'en', label: 'English' },
            ]}
            onChange={(language) => void call('settings.update', { language })}
          />
        </Row>
      </Group>
    </>
  )
}
