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
      <PaneHeader title={t('Оформление')} description={t('Тема и язык приложения.')} />
      <Group>
        <Row icon={<ThemeIcon />} title={t('Тема')} description={t('Светлая или тёмная, или как в Windows.')}>
          <Select<ThemePreference>
            label={t('Тема')}
            value={app.settings.theme}
            options={[
              { value: 'system', label: t('Как в системе') },
              { value: 'light', label: t('Светлая') },
              { value: 'dark', label: t('Тёмная') },
            ]}
            onChange={(theme) => void call('settings.update', { theme })}
          />
        </Row>
        <Row icon={<LanguageIcon />} title={t('Язык')} description={t('Интерфейс и тексты логов для тренера.')}>
          <Select<LanguagePreference>
            label={t('Язык')}
            value={app.settings.language}
            options={[
              { value: 'system', label: t('Как в системе') },
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
