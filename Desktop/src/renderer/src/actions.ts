import { t } from '@shared/i18n'
import { PlanParser } from '@core/planParser'
import { TrainingPlan } from '@core/models'
import { TrainingSession, type TrainingSessionSnapshot } from '@core/trainingSession'
import type { HistoryList } from '@shared/api'
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

/// The schedule of the latest training in history: what «Повторить прошлое» offers.
export async function lastPlan(): Promise<TrainingPlan | null> {
  const list = (await call('history.list')) as HistoryList | undefined
  const record = list?.records.find((item) => TrainingPlan.isValid(item.plan))
  return record?.plan ?? null
}

/// Ctrl+Shift+R: the previous schedule again (a fresh copy: new ids, today's date).
export async function repeatLast(): Promise<void> {
  const app = ui.get().app
  if (!app || app.session) return
  const plan = await lastPlan()
  if (!plan) return
  await call('pending.set', plan)
  ui.set({ reviewingPlan: true, route: 'training' })
}

/// Ctrl+Enter
export async function startPending(): Promise<void> {
  const app = ui.get().app
  if (!app?.pendingPlan || app.session) return
  await call('session.start', TrainingPlan.renumbered(app.pendingPlan))
  ui.set({ reviewingPlan: false })
}

/// Space: the one obvious next step of the running session.
export async function primaryStep(): Promise<void> {
  const app = ui.get().app
  const session = app?.session as TrainingSessionSnapshot | null | undefined
  if (!session) {
    await startPending()
    return
  }
  const phase = session.phase
  switch (phase.kind) {
    case 'ready':
      return void call('session.command', 'startExit')
    case 'leaving':
      return void call('session.command', 'markBehindDoor')
    case 'away':
      return void call('session.command', 'endExit')
    case 'breakTime':
      if (phase.nextExitIndex !== null) return void call('session.command', 'startExit')
      return void call('session.command', 'finish')
  }
}

/// Backspace: false start while leaving or behind the door.
export function falseStart(): void {
  const session = ui.get().app?.session as TrainingSessionSnapshot | null | undefined
  if (!session || (session.phase.kind !== 'leaving' && session.phase.kind !== 'away')) return
  void call('session.command', 'resetExit')
}

export function primaryStepTitle(session: TrainingSessionSnapshot | null): string {
  if (!session) return t('Начать тренировку')
  const phase = session.phase
  const exit = TrainingSession.currentExit(session)
  switch (phase.kind) {
    case 'ready':
      return t('Начать выход %lld', exit?.number ?? 1)
    case 'leaving':
      return t('За дверью')
    case 'away':
      return t('Вернулись')
    case 'breakTime':
      return phase.nextExitIndex !== null ? t('Начать выход %lld', session.plan.exits[phase.nextExitIndex].number) : t('Завершить')
    case 'finished':
      return t('Готово')
  }
}
