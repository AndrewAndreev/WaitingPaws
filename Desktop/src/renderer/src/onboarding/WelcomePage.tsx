import { t } from '@shared/i18n'
import { call } from '../store'
import { Button } from '../ui/kit'

export function WelcomePage() {
  return (
    <div className="empty-state" style={{ height: '100%' }}>
      <div className="h1">Waiting Paws</div>
      <Button onClick={() => void call('camera.continueWithout')}>{t('Продолжить без камеры')}</Button>
    </div>
  )
}
