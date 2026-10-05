import { t } from '@shared/i18n'
import { call, useApp } from '../store'
import { Switch } from '../ui/kit'
import { ClipIcon, FinishIcon, KeepAwakeIcon } from '../ui/icons'
import { Group, PaneHeader, Row } from './rows'

/// Тренировка: what happens at the start and the end of a training, and the computer staying awake meanwhile.
export function TrainingPane() {
  const app = useApp()
  const settings = app.settings
  return (
    <>
      <PaneHeader title={t('Тренировка')} description={t('Что происходит в начале и в конце тренировки.')} />
      <Group>
        <Row icon={<ClipIcon />} title={t('Включать запись вместе с тренировкой')} description={t('Видео с камеры пишется от начала тренировки до конца.')}>
          <Switch checked={settings.autoRecord} label={t('Включать запись вместе с тренировкой')} onChange={(value) => void call('settings.update', { autoRecord: value })} />
        </Row>
        <Row icon={<FinishIcon />} title={t('Завершать автоматически')} description={t('После перерыва за последним выходом: запись и лог сохраняются сами.')}>
          <Switch checked={settings.autoFinishAfterLastBreak} label={t('Завершать автоматически')} onChange={(value) => void call('settings.update', { autoFinishAfterLastBreak: value })} />
        </Row>
        {app.platform !== 'web' && (
          <Row icon={<KeepAwakeIcon />} title={t('Не давать компьютеру засыпать')} description={t('Пока идёт тренировка или запись, экран не гаснет и компьютер не уходит в сон — запись не оборвётся.')}>
            <Switch checked={settings.keepAwake} label={t('Не давать компьютеру засыпать')} onChange={(value) => void call('settings.update', { keepAwake: value })} />
          </Row>
        )}
      </Group>
    </>
  )
}
