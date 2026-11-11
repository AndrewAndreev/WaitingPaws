import { t } from '@shared/i18n'
import { call, useApp } from '../store'
import { Switch } from '../ui/kit'
import { ClipIcon, KeepAwakeIcon } from '../ui/icons'
import { Group, PaneHeader, Row } from './rows'

/// Тренировка: what happens at the start and the end of a training, and the computer staying awake meanwhile.
export function TrainingPane() {
  const app = useApp()
  const settings = app.settings
  return (
    <>
      <PaneHeader title={t('Training')} description={t('What happens when a training starts. It ends only with the Finish button.')} />
      <Group>
        <Row icon={<ClipIcon />} title={t('Start recording with the training')} description={t('Camera video is recorded from the start of the training to the end.')}>
          <Switch checked={settings.autoRecord} label={t('Start recording with the training')} onChange={(value) => void call('settings.update', { autoRecord: value })} />
        </Row>
        {app.platform !== 'web' && (
          <Row icon={<KeepAwakeIcon />} title={t('Keep the computer awake')} description={t('While a training or a recording runs, the screen stays on and the computer doesn’t go to sleep, so the recording isn’t cut off.')}>
            <Switch checked={settings.keepAwake} label={t('Keep the computer awake')} onChange={(value) => void call('settings.update', { keepAwake: value })} />
          </Row>
        )}
      </Group>
    </>
  )
}
