import { t } from '@shared/i18n'
import { startPending } from '../actions'
import { ui } from '../store'
import { Button, Dialog } from '../ui/kit'

/// «Расписание разобрано» — placeholder until the full editor lands.
export function PlanReviewDialog() {
  return (
    <Dialog open onOpenChange={(open) => !open && ui.set({ reviewingPlan: false })} title={t('Расписание разобрано')} footer={<Button variant="primary" onClick={() => void startPending()}>{t('Начать тренировку')}</Button>} />
  )
}
