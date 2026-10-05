import { t } from '@shared/i18n'
import { useApp } from '../store'

/// The waiting plan on the timeline, editable with the mouse (port of MacPlanTimelineEditor) — placeholder.
export function PlanTimelineEditor() {
  const app = useApp()
  return <div className="empty-state" style={{ height: '100%' }}>{app.pendingPlan?.title ?? t('План')}</div>
}
