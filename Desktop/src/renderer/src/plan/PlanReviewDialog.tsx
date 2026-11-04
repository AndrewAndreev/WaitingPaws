import { useMemo, useRef, useState, type KeyboardEvent, type PointerEvent as ReactPointerEvent } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { TrainingPlan } from '@core/models'
import { TrainingSession, type TrainingSessionSnapshot } from '@core/trainingSession'
import { startPending, startTitle } from '../actions'
import { isConfigured } from '../model'
import { call, toast, ui, useApp } from '../store'
import { CalendarIcon, CheckIcon, ChevronDownIcon, EditIcon, PlayFilledIcon, SuccessFilledIcon, WarningFilledIcon } from '../ui/icons'
import { Button, Checkbox, Dialog, Tooltip } from '../ui/kit'
import { DurationPopover } from './DurationEditor'
import { CommonEntriesBar, ExitInspector, PlanRuleChips } from './PlanConditions'
import { PlanExitTable, type ExitTableCommands } from './PlanExitTable'
import { PlanMiniBar } from './PlanMiniBar'
import { PlanSourcePane } from './PlanSourcePane'
import {
  PlanFormat,
  addExit,
  dateFromInput,
  dateInputValue,
  deleteExits,
  duplicateExits,
  ownBreaks,
  resetOwnBreaks,
  selectedIndices,
  setDefaultBreak,
  shiftExits,
} from './planEdit'
import { PlanLine, classifyLines, exitLines, type PlanTextLine } from './planText'
import { flushPendingPlan, usePendingPlan } from './usePendingPlan'
import '../styles/plan.css'

/// «Расписание разобрано» — the dialog over the training page right after a paste (port of `MacPlanReviewSheet`):
/// the trainer's text on the left as a read-only source view (recognised lines marked in the gutter), the parsed
/// exits as an editable table on the right — the rules of the whole training as chips and the common conditions
/// above it, the selected exit's triggers, conditions and note in the inspector below — the summary and the start in
/// the footer. Selecting a row highlights its lines in the text; clicking an exit line selects its row. Every edit
/// goes straight to the waiting plan.
export function PlanReviewDialog() {
  const { plan, setPlan } = usePendingPlan()
  if (!plan) return null
  const start = async () => {
    if (!TrainingPlan.isValid(plan)) return
    await flushPendingPlan(plan)
    await startPending()
  }
  return <PlanDialog plan={plan} setPlan={setPlan} onStart={() => void start()} onDone={() => ui.set({ reviewingPlan: false })} />
}

/// The running training's schedule in the same dialog («Изменить расписание»): edits stay in a draft until
/// «Сохранить» (`session.updatePlan`). The exits already done and the current one keep their place — an edit that
/// drops or moves them is not taken.
export function SessionPlanDialog() {
  const session = useApp().session as TrainingSessionSnapshot | null
  const [draft, setDraft] = useState<TrainingPlan | null>(() => (session?.plan as TrainingPlan | undefined) ?? null)
  if (!session || !draft) return null
  const close = () => ui.set({ editingSessionPlan: false })
  // Functional: the inspector may send two edits from one event (a trigger typed in, then the note).
  const setPlan = (next: TrainingPlan | ((current: TrainingPlan) => TrainingPlan)) =>
    setDraft((current) => {
      if (!current) return current
      const value = TrainingPlan.keepingCommonEntriesScope(typeof next === 'function' ? next(current) : next, current)
      return TrainingSession.canUpdatePlan(session, value) ? value : current
    })
  const save = async () => {
    if (await call('session.updatePlan', draft)) close()
    else toast({ title: t('Прошедшие выходы и текущий нельзя удалить или переставить.'), kind: 'warning' })
  }
  return <PlanDialog plan={draft} setPlan={setPlan} fixedExits={TrainingSession.fixedExitCount(session)} onStart={() => void save()} onDone={close} />
}

function PlanDialog({
  plan,
  setPlan,
  fixedExits,
  onStart,
  onDone,
}: {
  plan: TrainingPlan
  setPlan: (next: TrainingPlan | ((current: TrainingPlan) => TrainingPlan)) => void
  /// During a training: how many exits from the start are done or running.
  fixedExits?: number
  onStart: () => void
  onDone: () => void
}) {
  const running = fixedExits !== undefined
  const [rawSelection, setRawSelection] = useState<string[]>([])
  // A rule chip above the table marks its lines in the text until a row is picked.
  const [focus, setFocus] = useState<{ key: string | null; lines: number[] }>({ key: null, lines: [] })
  // «Выбрать» in the common conditions bar: the exits are ticked one by one in the inspector.
  const [picking, setPicking] = useState(false)
  const setSelection = (ids: string[]) => {
    setRawSelection(ids)
    setFocus({ key: null, lines: [] })
  }
  const [sourceWidth, setSourceWidth] = useState<number | null>(null)
  const splitRef = useRef<HTMLDivElement>(null)
  const rawText = plan?.rawText ?? ''
  const lines = useMemo(() => classifyLines(rawText), [rawText])

  const lineOfExit = exitLines(plan, lines)
  const ids = new Set(plan.exits.map((exit) => exit.id))
  const selection = rawSelection.filter((id) => ids.has(id))
  const valid = TrainingPlan.isValid(plan)
  const hasSource = lines.some((line) => line.kind.kind !== 'blank')

  const done = onDone
  const start = () => {
    if (valid) onStart()
  }

  const commands: ExitTableCommands = {
    add: (after = selection) => {
      const edit = addExit(plan, after)
      setPlan(edit.plan)
      setSelection(edit.selection)
    },
    duplicate: (from = selection) => {
      const edit = duplicateExits(plan, from)
      if (!edit) return
      setPlan(edit.plan)
      setSelection(edit.selection)
    },
    remove: (from = selection) => {
      const edit = deleteExits(plan, from)
      if (!edit) return
      setPlan(edit.plan)
      setSelection(edit.selection)
    },
    shift: (delta) => {
      const next = shiftExits(plan, selection, delta)
      if (next) setPlan(next)
    },
  }

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const target = event.target as HTMLElement
    const typing = target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName)
    const ctrl = event.ctrlKey || event.metaKey
    const key = event.key.toLowerCase()
    const handled = () => {
      event.preventDefault()
      event.stopPropagation()
    }
    if (ctrl && !event.shiftKey && !event.altKey) {
      if (key === 'enter') {
        handled()
        return start()
      }
      if (key === 'n') {
        handled()
        return commands.add()
      }
      if (key === 'd') {
        handled()
        return commands.duplicate()
      }
      if (key === 'a' && !typing) {
        handled()
        return setSelection(plan.exits.map((exit) => exit.id))
      }
    }
    // Keys in the inspector (a chip's ✕ focused, the colour dot) are not about the table's rows.
    if (typing || ctrl || event.shiftKey || target.closest('.popover, [role="menu"], .plan-inspector, .plan-common, .plan-rules')) return
    if (event.altKey && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) {
      handled()
      return commands.shift(event.key === 'ArrowUp' ? -1 : 1)
    }
    if (event.altKey) return
    if (event.key === 'Delete' || event.key === 'Backspace') {
      if (!selection.length) return
      handled()
      return commands.remove()
    }
    if ((event.key === 'ArrowUp' || event.key === 'ArrowDown') && target.closest('.plan-table__body')) {
      handled()
      const indices = selectedIndices(plan, selection)
      const from = indices.length ? (event.key === 'ArrowUp' ? indices[0] : indices[indices.length - 1]) : -1
      const next = Math.min(plan.exits.length - 1, Math.max(0, event.key === 'ArrowUp' ? from - 1 : from + 1))
      setSelection([plan.exits[next].id])
    }
  }

  const onSplitterDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return
    event.preventDefault()
    const pane = (event.currentTarget.previousElementSibling as HTMLElement | null)?.getBoundingClientRect().width ?? 400
    const total = splitRef.current?.getBoundingClientRect().width ?? 1200
    const startX = event.clientX
    const move = (moveEvent: PointerEvent) => {
      const max = Math.max(280, Math.min(620, total - 600))
      setSourceWidth(Math.round(Math.min(max, Math.max(280, pane + moveEvent.clientX - startX))))
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      document.body.classList.remove('is-resizing-columns')
    }
    document.body.classList.add('is-resizing-columns')
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }

  return (
    <Dialog
      open
      onOpenChange={(open) => !open && done()}
      icon={
        running ? (
          <EditIcon className="plan-review__icon" style={{ color: 'var(--info)' }} />
        ) : valid ? (
          <SuccessFilledIcon className="plan-review__icon" style={{ color: 'var(--success)' }} />
        ) : (
          <WarningFilledIcon className="plan-review__icon" style={{ color: 'var(--warning)' }} />
        )
      }
      title={running ? t('Расписание тренировки') : valid ? t('Расписание разобрано') : t('В расписании нет выходов')}
      description={
        <span className="plan-review__summary-text">
          {running
            ? t('Тренировка идёт: изменения применятся сразу, и к идущему перерыву тоже. Прошедшие выходы и текущий нельзя удалить или переставить.')
            : summary(plan, lines)}
        </span>
      }
      width={1440}
      height={1000}
      bodyClassName="plan-review"
      footer={<Footer plan={plan} valid={valid} running={running} onStart={start} onDone={done} />}
    >
      <div className="plan-review__split" ref={splitRef} onKeyDown={onKeyDown}>
        {hasSource && (
          <>
            <PlanSourcePane
              lines={lines}
              plan={plan}
              lineOfExit={lineOfExit}
              selection={selection}
              focus={focus.lines}
              onSelect={(id) => setSelection([id])}
              width={sourceWidth}
            />
            <div className="plan-splitter" role="separator" aria-orientation="vertical" onPointerDown={onSplitterDown} />
          </>
        )}
        <section className="plan-editor">
          <PlanForm plan={plan} setPlan={setPlan} />
          <PlanRuleChips plan={plan} lines={lines} focused={focus.key} onFocus={(key, ids) => setFocus({ key, lines: ids })} />
          {plan.commonEarlyEntries.length > 0 && <CommonEntriesBar plan={plan} setPlan={setPlan} lines={lines} picking={picking} setPicking={setPicking} />}
          <PlanExitTable plan={plan} setPlan={setPlan} selection={selection} setSelection={setSelection} lineOfExit={hasSource ? lineOfExit : null} commands={commands} />
          <ExitInspector plan={plan} setPlan={setPlan} selection={selection} lines={lines} lineOfExit={hasSource ? lineOfExit : null} />
        </section>
      </div>
    </Dialog>
  )
}

/// «8 выходов, 4 триггера, условия раннего входа у выходов 4, 6 и 8, правило фальстарта и 5 заметок. Проверьте…».
function summary(plan: TrainingPlan, lines: PlanTextLine[]): string {
  if (plan.rawText === '') {
    return t('%@. Проверьте длительности и перерывы перед стартом.', PlanFormat.exits(plan.exits.length))
  }
  const parts = [PlanFormat.exits(lines.filter(PlanLine.isExit).length)]
  const breaks = lines.filter(PlanLine.isBreak).length
  if (breaks > 0) parts.push(PlanFormat.breaks(breaks))
  const triggers = plan.exits.reduce((sum, exit) => sum + exit.triggers.length, 0)
  if (triggers > 0) parts.push(PlanFormat.triggers(triggers))
  const early = plan.exits.filter((exit) => TrainingPlan.earlyEntries(plan, exit).length > 0)
  if (early.length > 0 && early.length === plan.exits.length) parts.push(t('условия раннего входа у всех выходов'))
  else if (early.length === 1) parts.push(t('условия раннего входа у выхода %lld', early[0].number))
  else if (early.length > 1) parts.push(t('условия раннего входа у выходов %@', PlanFormat.list(early.map((exit) => String(exit.number)))))
  if (lines.some((line) => line.kind.kind === 'doNotEnter')) parts.push(t('правило «не входить»'))
  if (lines.some((line) => line.kind.kind === 'rule')) parts.push(t('правило фальстарта'))
  const notes = lines.filter((line) => line.kind.kind === 'note').length
  if (notes > 0) parts.push(PlanFormat.notes(notes))
  return t('%@. Проверьте и поправьте, если что-то прочитано не так.', PlanFormat.capitalizedFirst(PlanFormat.list(parts)))
}

// MARK: - Title, date, trainers, the common break

function PlanForm({ plan, setPlan }: { plan: TrainingPlan; setPlan: (next: TrainingPlan | ((current: TrainingPlan) => TrainingPlan)) => void }) {
  const own = ownBreaks(plan)
  const resetHelp = own.length
    ? t('Убрать свои перерывы: %@', own.map((exit) => t('после %lld-го — %@', exit.number, DurationText.short(exit.breakAfter ?? 0))).join(', '))
    : t('У всех выходов общий перерыв')
  return (
    <div className="plan-form">
      <label className="plan-form__label" htmlFor="plan-title">
        {t('Название:')}
      </label>
      <input id="plan-title" className="input" value={plan.title} placeholder={t('Тренировка')} onChange={(event) => setPlan((current) => ({ ...current, title: event.target.value }))} />
      <label className="plan-form__label" htmlFor="plan-date">
        {t('Дата:')}
      </label>
      <DateField id="plan-date" value={plan.date} onChange={(date) => setPlan((current) => ({ ...current, date }))} />
      <label className="plan-form__label" htmlFor="plan-trainers">
        {t('Тренеры:')}
      </label>
      <input id="plan-trainers" className="input" value={plan.trainers} placeholder={t('Кто тренирует')} onChange={(event) => setPlan((current) => ({ ...current, trainers: event.target.value }))} />
      <span className="plan-form__label">{t('Перерыв:')}</span>
      <div className="row plan-form__breaks">
        <DurationPopover
          value={plan.defaultBreak}
          onChange={(value) => {
            if (value !== null) setPlan((current) => setDefaultBreak(current, value))
          }}
          title={t('Перерыв между выходами')}
          presets={PlanFormat.breakPresets}
          tint="break"
          tooltip={t('Перерыв между выходами — у всех, кроме выходов со своим перерывом')}
        >
          <button type="button" className="btn plan-form__break tabular">
            {DurationText.short(plan.defaultBreak)}
            <ChevronDownIcon className="plan-form__chevron" />
          </button>
        </DurationPopover>
        <Tooltip content={resetHelp}>
          <span className="plan-form__reset">
            <Button disabled={!own.length} onClick={() => setPlan(resetOwnBreaks)}>
              {t('Сделать везде %@', DurationText.short(plan.defaultBreak))}
            </Button>
          </span>
        </Tooltip>
      </div>
    </div>
  )
}

/// The schedule's date in the app's format («04.10.2026»); the system date picker opens on click.
function DateField({ id, value, onChange }: { id: string; value: number | null; onChange: (date: number) => void }) {
  const input = useRef<HTMLInputElement>(null)
  return (
    <div className="plan-form__date">
      <input
        ref={input}
        type="date"
        className="plan-form__date-input"
        tabIndex={-1}
        aria-hidden
        value={dateInputValue(value)}
        onChange={(event) => {
          const date = dateFromInput(event.target.value)
          if (date !== null) onChange(date)
        }}
      />
      <button
        id={id}
        type="button"
        className="btn plan-form__date-button tabular"
        onClick={() => {
          try {
            input.current?.showPicker()
          } catch {
            input.current?.focus()
          }
        }}
      >
        <span className="grow" style={{ textAlign: 'left' }}>
          {TrainingPlan.formatDate(value ?? Date.now())}
        </span>
        <CalendarIcon />
      </button>
    </div>
  )
}

// MARK: - Footer

function Footer({ plan, valid, running, onStart, onDone }: { plan: TrainingPlan; valid: boolean; running: boolean; onStart: () => void; onDone: () => void }) {
  return (
    <>
      <div className="plan-summary">
        <div className="plan-summary__line tabular">
          <span className="plan-summary__main">
            {PlanFormat.exits(plan.exits.length)} · {PlanFormat.approx(TrainingPlan.estimatedDuration(plan))}
          </span>
          {valid && (
            <span className="muted ellipsis">
              {t('за дверью %@, перерывы %@', DurationText.short(PlanFormat.exitsTotal(plan)), DurationText.short(PlanFormat.breaksTotal(plan)))}
            </span>
          )}
        </div>
        <PlanMiniBar plan={plan} />
      </div>
      <span className="spacer" />
      {running ? (
        <>
          <Tooltip content={t('Закрыть без изменений · Esc')}>
            <Button onClick={onDone}>{t('Отменить')}</Button>
          </Tooltip>
          <Button variant="primary" icon={<CheckIcon />} shortcut="Ctrl+Enter" disabled={!valid} onClick={onStart}>
            {t('Сохранить')}
          </Button>
        </>
      ) : (
        <PendingButtons valid={valid} onStart={onStart} onDone={onDone} />
      )}
    </>
  )
}

function PendingButtons({ valid, onStart, onDone }: { valid: boolean; onStart: () => void; onDone: () => void }) {
  const app = useApp()
  return (
    <>
      {isConfigured(app.settings) && (
        <Tooltip content={t('Включить запись с камеры вместе с тренировкой')}>
          <span className="plan-summary__record">
            <Checkbox checked={app.settings.autoRecord} onChange={(autoRecord) => void call('settings.update', { autoRecord })}>
              {t('Записывать видео')}
            </Checkbox>
          </span>
        </Tooltip>
      )}
      <Tooltip content={t('Оставить расписание на пульте и поправить его на таймлайне · Esc')}>
        <Button onClick={onDone}>{t('Готово')}</Button>
      </Tooltip>
      <Button variant="primary" icon={<PlayFilledIcon />} shortcut="Ctrl+Enter" disabled={!valid} onClick={onStart}>
        {startTitle(app)}
      </Button>
    </>
  )
}
