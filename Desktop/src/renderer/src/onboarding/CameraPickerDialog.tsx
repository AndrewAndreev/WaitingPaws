import { t } from '@shared/i18n'
import { Dialog } from '../ui/kit'

export function CameraPickerDialog({ onClose }: { onClose: () => void }) {
  return <Dialog open onOpenChange={(open) => !open && onClose()} title={t('Выбрать камеру…')} />
}
