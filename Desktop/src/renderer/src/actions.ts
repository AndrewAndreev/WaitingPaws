import { t } from '@shared/i18n'
import { PlanParser } from '@core/planParser'
import { TrainingPlan } from '@core/models'
import { SessionPhase, type TrainingSessionSnapshot } from '@core/trainingSession'
import type { AppState } from '@shared/api'
import { isConfigured, isRecording } from './model'
import { call, toast, ui } from './store'

/// What menus, keys, the title bar and the panels do — the Mac app's `MacUIState`.

/// Ctrl+Shift+V: parse the trainer's message from the clipboard and show how it was read.
export async function pasteSchedule(text?: string): Promise<void> {
  const app = ui.get().app
  if (!app || app.session) return
  const source = text ?? (await call('clipboard.readText')) ?? ''
  if (!source.trim()) {
    toast({ title: t('В буфере обмена нет текста. Скопируйте сообщение тренера и попробуйте снова.'), kind: 'warning' })
    return
  }
  const plan = PlanParser.parse(source)
  if (!TrainingPlan.isValid(plan)) {
    toast({ title: t('В скопированном тексте не нашлось ни одного выхода («1 выход - 30 секунд»).'), kind: 'warning' })
    return
  }
  await call('pending.set', plan)
  ui.set({ reviewingPlan: true, route: 'training' })
}

/// «Начать тренировку и запись» when the start starts the recording too (the setting is on and there is a camera).
export function startTitle(app: AppState): string {
  return app.settings.autoRecord && isConfigured(app.settings) ? t('Начать тренировку и запись') : t('Начать тренировку')
}

/// «Завершить тренировку и запись» while a recording runs: finishing stops it.
export function finishTitle(app: AppState): string {
  return isRecording(app) ? t('Завершить тренировку и запись') : t('Завершить')
}

/// Ctrl+Enter
export async function startPending(): Promise<void> {
  const app = ui.get().app
  if (!app?.pendingPlan || app.session) return
  await call('session.start', TrainingPlan.renumbered(app.pendingPlan))
  ui.set({ reviewingPlan: false })
}

/// Space: the one obvious next step of the running session — «Вышли», «Вернулись» (or «Завершить» in the last break).
export async function primaryStep(): Promise<void> {
  const app = ui.get().app
  const session = app?.session as TrainingSessionSnapshot | null | undefined
  if (!session) {
    await startPending()
    return
  }
  const phase = session.phase
  if (phase.kind === 'away') return void call('session.command', 'endExit')
  if (SessionPhase.canGoOutside(phase)) return void call('session.command', 'markBehindDoor')
  if (phase.kind === 'breakTime') return void call('session.command', 'finish')
}

/// Backspace: false start — outside, or in a break when the dog went to the door before «Вышли».
export function falseStart(): void {
  const session = ui.get().app?.session as TrainingSessionSnapshot | null | undefined
  if (!session || !SessionPhase.canFalseStart(session.phase)) return
  void call('session.command', 'resetExit')
}

export function primaryStepTitle(session: TrainingSessionSnapshot | null): string {
  if (!session) return t('Начать тренировку')
  const phase = session.phase
  if (phase.kind === 'finished') return t('Готово')
  if (phase.kind === 'away') return t('Вернулись')
  return SessionPhase.canGoOutside(phase) ? t('Вышли') : t('Завершить')
}
