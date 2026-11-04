import { useCallback, useEffect, useRef, useState } from 'react'
import { TrainingPlan } from '@core/models'
import { call, ui, useStore } from '../store'
import { DraftSync } from './draftSync'

/// The waiting plan as an editable draft. Edits show at once (typing, dragging an edge) and go to the backend with
/// `pending.set(plan, keepOriginal: true)`; the backend's echoes of our own edits (and stale states pushed before
/// they arrived) never overwrite a newer local edit, while a change from elsewhere (a new paste, a linked iPhone, the
/// other editor) replaces the draft.
export function usePendingPlan(): {
  plan: TrainingPlan | null
  original: TrainingPlan | null
  setPlan: (next: TrainingPlan | ((current: TrainingPlan) => TrainingPlan)) => void
} {
  const pending = useStore((store) => (store.app?.pendingPlan ?? null) as TrainingPlan | null)
  const original = useStore((store) => (store.app?.pendingOriginal ?? null) as TrainingPlan | null)
  const [draft, setDraft] = useState<TrainingPlan | null>(pending)
  const draftRef = useRef<TrainingPlan | null>(pending)
  const draftJSON = useRef(JSON.stringify(pending))
  const sync = useRef<DraftSync | null>(null)
  sync.current ??= new DraftSync(draftJSON.current)

  useEffect(() => {
    const json = JSON.stringify(pending)
    if (sync.current!.receive(json) === 'keep' || json === draftJSON.current) return
    draftRef.current = pending
    draftJSON.current = json
    setDraft(pending)
  }, [pending])

  const setPlan = useCallback((next: TrainingPlan | ((current: TrainingPlan) => TrainingPlan)) => {
    const current = draftRef.current
    if (!current) return
    // An added exit or a new time keeps «к длинным» / «ко всем» (the table, the inspector and the timeline come here).
    const value = TrainingPlan.keepingCommonEntriesScope(typeof next === 'function' ? next(current) : next, current)
    if (value === current) return
    const json = JSON.stringify(value)
    if (json === draftJSON.current) return
    draftRef.current = value
    draftJSON.current = json
    sync.current!.send(json)
    setDraft(value)
    void call('pending.set', value, true)
  }, [])

  return { plan: draft, original, setPlan }
}

/// Sends the draft and waits (briefly) until the app state shows it, so `startPending()` starts exactly what the
/// user sees even right after an edit.
export async function flushPendingPlan(plan: TrainingPlan): Promise<void> {
  const json = JSON.stringify(plan)
  const shown = () => JSON.stringify(ui.get().app?.pendingPlan ?? null) === json
  if (shown()) return
  await call('pending.set', plan, true)
  if (shown()) return
  await new Promise<void>((resolve) => {
    let unsubscribe = () => {}
    const finish = () => {
      window.clearTimeout(timer)
      unsubscribe()
      resolve()
    }
    const timer = window.setTimeout(finish, 1000)
    unsubscribe = useStore.subscribe(() => {
      if (shown()) finish()
    })
  })
}
