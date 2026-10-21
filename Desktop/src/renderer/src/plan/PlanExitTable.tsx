import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { EarlyEntry, PlannedExit, TrainingPlan } from '@core/models'
import {
  AddIcon,
  ChevronUpDownIcon,
  DeleteIcon,
  DragHandleIcon,
  DuplicateIcon,
  EarlyEntryIcon,
  ExitNoteIcon,
  MoveDownIcon,
  MoveUpIcon,
  SubtractIcon,
  TriggerIcon,
} from '../ui/icons'
import { Button, ContextMenu, ContextMenuContent, ContextMenuItem, ContextMenuSeparator, ContextMenuTrigger, Kbd, Tooltip } from '../ui/kit'
import { DurationPopover } from './DurationEditor'
import { PlanFormat, canDelete, canShift, moveExits, setBreakAfter, updateExit } from './planEdit'

export interface ExitTableCommands {
  /// After the given exits (default: the selection); an empty list adds at the end.
  add: (after?: string[]) => void
  duplicate: (ids?: string[]) => void
  remove: (ids?: string[]) => void
  shift: (delta: -1 | 1) => void
}

/// The parsed exits as an editable table: duration and break popovers, the source line, and under every exit a summary
/// of what goes with it — «⚡ куртка · ключи  🏃 встала и пошла → 2:00 · легла → 0:30  📝» (the inspector below the
/// table edits them). Click selects (Ctrl toggles, Shift extends), dragging a row (anywhere outside its controls)
/// reorders, right click offers duplicate / add below / delete; the toolbar below repeats them with the shortcuts.
export function PlanExitTable({
  plan,
  setPlan,
  selection,
  setSelection,
  lineOfExit,
  commands,
}: {
  plan: TrainingPlan
  setPlan: (next: TrainingPlan | ((current: TrainingPlan) => TrainingPlan)) => void
  selection: string[]
  setSelection: (ids: string[]) => void
  /// Which line of the trainer's text each exit came from; null hides the «Строка» column (no text).
  lineOfExit: Map<string, number> | null
  commands: ExitTableCommands
}) {
  const bodyRef = useRef<HTMLDivElement>(null)
  const anchor = useRef<string | null>(null)
  const [drag, setDrag] = useState<{ ids: string[]; drop: number | null } | null>(null)
  const selected = new Set(selection)
  const hasSelection = selection.length > 0

  // Keyboard first: the table has the focus when the dialog opens (Delete, arrows, Ctrl+D work at once).
  useEffect(() => {
    bodyRef.current?.focus({ preventScroll: true })
  }, [])

  // The selected row stays in view (keyboard, a click on a line in the text, a new or duplicated row).
  const lastSelected = selection[selection.length - 1]
  useEffect(() => {
    if (!lastSelected) return
    bodyRef.current?.querySelector<HTMLElement>(`[data-exit="${lastSelected}"]`)?.scrollIntoView({ block: 'nearest' })
  }, [lastSelected])

  const onRowPointerDown = (event: ReactPointerEvent<HTMLDivElement>, exit: PlannedExit, index: number) => {
    if (event.button !== 0) return
    const target = event.target as HTMLElement
    if (target.closest('input, button, label, textarea, select, a')) {
      if (!selected.has(exit.id)) setSelection([exit.id])
      anchor.current = exit.id
      return
    }
    event.preventDefault()
    bodyRef.current?.focus({ preventScroll: true })
    if (event.ctrlKey || event.metaKey) {
      setSelection(selected.has(exit.id) ? selection.filter((id) => id !== exit.id) : [...selection, exit.id])
      anchor.current = exit.id
      return
    }
    if (event.shiftKey && anchor.current) {
      const from = plan.exits.findIndex((item) => item.id === anchor.current)
      if (from >= 0) {
        const [a, b] = from < index ? [from, index] : [index, from]
        setSelection(plan.exits.slice(a, b + 1).map((item) => item.id))
        return
      }
    }
    const wasSelected = selected.has(exit.id)
    const ids = wasSelected ? plan.exits.filter((item) => selected.has(item.id)).map((item) => item.id) : [exit.id]
    if (!wasSelected) setSelection([exit.id])
    anchor.current = exit.id

    // A press becomes a drag after a few pixels; a plain click on one of several selected rows selects just it.
    const startY = event.clientY
    let dragging = false
    let drop: number | null = null
    const move = (moveEvent: PointerEvent) => {
      if (!dragging && Math.abs(moveEvent.clientY - startY) < 4) return
      dragging = true
      const body = bodyRef.current
      if (!body) return
      const box = body.getBoundingClientRect()
      if (moveEvent.clientY < box.top + 24) body.scrollTop -= 10
      else if (moveEvent.clientY > box.bottom - 24) body.scrollTop += 10
      drop = dropIndex(body, moveEvent.clientY)
      setDrag({ ids, drop })
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      window.removeEventListener('pointercancel', up)
      setDrag(null)
      if (dragging && drop !== null) {
        const target = drop
        setPlan((current) => moveExits(current, ids, target))
        setSelection(ids)
      } else if (!dragging && wasSelected) {
        setSelection([exit.id])
      }
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
    window.addEventListener('pointercancel', up)
  }

  const dropTop = drag && drag.drop !== null ? dropLineTop(bodyRef.current, drag.drop) : null
  const dragging = new Set(drag?.ids ?? [])

  return (
    <div className={'plan-table' + (lineOfExit ? '' : ' plan-table--no-lines')}>
      <div className="plan-table__head" role="row">
        <span className="plan-cell--num" role="columnheader">
          {t('№')}
        </span>
        <span role="columnheader">{t('Начало')}</span>
        <span role="columnheader">{t('За дверью')}</span>
        <span role="columnheader">{t('Перерыв после')}</span>
        {lineOfExit && (
          <span className="plan-cell--line" role="columnheader">
            {t('Строка')}
          </span>
        )}
      </div>
      <ContextMenu>
        <ContextMenuTrigger asChild>
          <div className={'plan-table__body' + (drag ? ' is-dragging' : '')} ref={bodyRef} tabIndex={-1} role="rowgroup">
            {plan.exits.map((exit, index) => (
              <ExitRow
                key={exit.id}
                plan={plan}
                exit={exit}
                index={index}
                selected={selected.has(exit.id)}
                dragged={dragging.has(exit.id)}
                line={lineOfExit ? lineOfExit.get(exit.id) ?? null : undefined}
                setPlan={setPlan}
                onPointerDown={(event) => onRowPointerDown(event, exit, index)}
                onContextMenu={() => {
                  if (!selected.has(exit.id)) setSelection([exit.id])
                }}
                commands={commands}
                canDelete={canDelete(plan, selected.has(exit.id) ? selection : [exit.id])}
              />
            ))}
            {dropTop !== null && <div className="plan-drop" style={{ top: dropTop }} />}
          </div>
        </ContextMenuTrigger>
        <ContextMenuContent>
          <ContextMenuItem icon={<AddIcon />} onSelect={() => commands.add([])}>
            {t('Добавить выход')}
          </ContextMenuItem>
        </ContextMenuContent>
      </ContextMenu>
      <div className="plan-toolbar">
        <ToolButton icon={<AddIcon />} label={t('Добавить выход') + ' (Ctrl+N)'} onClick={() => commands.add()} />
        <ToolButton icon={<SubtractIcon />} label={t('Удалить выбранные') + ' (Del)'} disabled={!canDelete(plan, selection)} onClick={() => commands.remove()} />
        <span className="plan-toolbar__sep" />
        <ToolButton icon={<DuplicateIcon />} label={t('Дублировать') + ' (Ctrl+D)'} disabled={!hasSelection} onClick={() => commands.duplicate()} />
        <ToolButton icon={<MoveUpIcon />} label={t('Выше') + ' (Alt+↑)'} disabled={!canShift(plan, selection, -1)} onClick={() => commands.shift(-1)} />
        <ToolButton icon={<MoveDownIcon />} label={t('Ниже') + ' (Alt+↓)'} disabled={!canShift(plan, selection, 1)} onClick={() => commands.shift(1)} />
        <span className="spacer" />
        <span className="plan-toolbar__hint plan-toolbar__hint--long">{t('Перетащите строку, чтобы изменить порядок')}</span>
        <span className="plan-toolbar__hint plan-toolbar__hint--short">{t('Строки можно перетаскивать')}</span>
        <span className="plan-toolbar__keys">
          <Kbd keys="Ctrl+D" />
          {t('дублировать')}
          <Kbd keys="Del" />
          {t('удалить')}
        </span>
      </div>
    </div>
  )
}

/// Insertion index (0…count) for a pointer at `y`: before the first row whose middle is below it.
function dropIndex(body: HTMLElement, y: number): number {
  const rows = [...body.querySelectorAll<HTMLElement>('[data-exit]')]
  for (let index = 0; index < rows.length; index++) {
    const box = rows[index].getBoundingClientRect()
    if (y < box.top + box.height / 2) return index
  }
  return rows.length
}

function dropLineTop(body: HTMLElement | null, drop: number): number | null {
  if (!body) return null
  const rows = [...body.querySelectorAll<HTMLElement>('[data-exit]')]
  if (!rows.length) return null
  if (drop < rows.length) return rows[drop].offsetTop - 2
  const last = rows[rows.length - 1]
  return last.offsetTop + last.offsetHeight
}

function ToolButton({ icon, label, disabled, onClick }: { icon: ReactNode; label: string; disabled?: boolean; onClick: () => void }) {
  return (
    <Tooltip content={label} side="top">
      <Button variant="subtle" size="sm" iconOnly className="plan-toolbar__button" icon={icon} aria-label={label} disabled={disabled} onClick={onClick} />
    </Tooltip>
  )
}

function ExitRow({
  plan,
  exit,
  index,
  selected,
  dragged,
  line,
  setPlan,
  onPointerDown,
  onContextMenu,
  commands,
  canDelete,
}: {
  plan: TrainingPlan
  exit: PlannedExit
  index: number
  selected: boolean
  dragged: boolean
  /// undefined: no «Строка» column.
  line: number | null | undefined
  setPlan: (next: TrainingPlan | ((current: TrainingPlan) => TrainingPlan)) => void
  onPointerDown: (event: ReactPointerEvent<HTMLDivElement>) => void
  onContextMenu: () => void
  commands: ExitTableCommands
  canDelete: boolean
}) {
  const isLast = index === plan.exits.length - 1
  const update = (patch: Partial<Omit<PlannedExit, 'id'>>) => setPlan((current) => updateExit(current, exit.id, patch))
  return (
    <ContextMenu
      onOpenChange={(open) => {
        if (open) onContextMenu()
      }}
    >
      <ContextMenuTrigger asChild>
        <div
          className={'plan-row' + (selected ? ' is-selected' : '') + (dragged ? ' is-dragged' : '')}
          data-exit={exit.id}
          role="row"
          aria-selected={selected}
          onPointerDown={onPointerDown}
        >
          <div className="plan-row__main">
            <span className="plan-cell--num tabular">
              <DragHandleIcon className="plan-row__grip" />
              {exit.number}
            </span>
            <span className="plan-cell--start tabular">+{DurationText.clock(PlanFormat.start(index, plan))}</span>
            <span>
              <DurationPopover
                value={exit.duration}
                onChange={(value) => update({ duration: Math.max(0, value ?? exit.duration) })}
                title={t('Выход %lld — за дверью', exit.number)}
                presets={PlanFormat.exitPresets}
                tint="exit"
                tooltip={t('Выход %lld: %@ — изменить', exit.number, PlannedExit.durationDescription(exit))}
              >
                <button type="button" className="plan-value plan-value--exit tabular">
                  {PlanFormat.cell(exit.duration)}
                  <ChevronUpDownIcon className="plan-value__chevron" />
                </button>
              </DurationPopover>
            </span>
            <span>
              {isLast ? (
                <Tooltip content={t('После последнего выхода тренировка заканчивается')}>
                  <span className="faint plan-end">{t('конец')}</span>
                </Tooltip>
              ) : (
                <DurationPopover
                  value={exit.breakAfter}
                  onChange={(value) => setPlan((current) => setBreakAfter(current, exit.id, value))}
                  title={t('Перерыв после выхода %lld', exit.number)}
                  presets={PlanFormat.breakPresets}
                  defaultValue={plan.defaultBreak}
                  tint="break"
                  tooltip={
                    exit.breakAfter === null
                      ? t('Перерыв после выхода %lld — как у всех. Выберите, чтобы задать свой', exit.number)
                      : t('Свой перерыв после выхода %lld', exit.number)
                  }
                >
                  <button type="button" className={'plan-value tabular' + (exit.breakAfter !== null ? ' plan-value--own' : ' plan-value--common')}>
                    {exit.breakAfter !== null ? t('%@ · свой', PlanFormat.cell(exit.breakAfter)) : PlanFormat.cell(plan.defaultBreak)}
                    <ChevronUpDownIcon className="plan-value__chevron" />
                  </button>
                </DurationPopover>
              )}
            </span>
            {line === undefined ? null : line !== null ? (
              <Tooltip content={t('Строка %lld в тексте тренера', line)}>
                <span className="plan-cell--line tabular">{line}</span>
              </Tooltip>
            ) : (
              <Tooltip content={t('Выхода нет в тексте тренера — добавлен здесь')}>
                <span className="plan-cell--line">{t('вручную')}</span>
              </Tooltip>
            )}
          </div>
          <ExitSummary plan={plan} exit={exit} />
        </div>
      </ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem icon={<DuplicateIcon />} onSelect={() => commands.duplicate()}>
          {t('Дублировать')}
        </ContextMenuItem>
        <ContextMenuItem icon={<AddIcon />} onSelect={() => commands.add()}>
          {t('Добавить выход ниже')}
        </ContextMenuItem>
        <ContextMenuSeparator />
        <ContextMenuItem icon={<DeleteIcon />} danger disabled={!canDelete} onSelect={() => commands.remove()}>
          {t('Удалить')}
        </ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  )
}

/// The second line of a row: triggers, conditions for coming back early, the note. The icons are always there, an
/// empty one dimmed with «—», so the column reads the same on every exit.
function ExitSummary({ plan, exit }: { plan: TrainingPlan; exit: PlannedExit }) {
  const entries = TrainingPlan.earlyEntries(plan, exit)
  const note = PlannedExit.noteText(exit)
  return (
    <div className="plan-sum">
      <span className={'plan-sum__item plan-sum__item--trigger' + (exit.triggers.length ? '' : ' is-empty')}>
        <TriggerIcon />
        <span className="ellipsis">{exit.triggers.length ? exit.triggers.join(' · ') : '—'}</span>
      </span>
      <span className={'plan-sum__item plan-sum__item--entry' + (entries.length ? '' : ' is-empty')}>
        <EarlyEntryIcon />
        <span className="ellipsis">{entries.length ? entries.map(EarlyEntry.summary).join(' · ') : '—'}</span>
      </span>
      {note ? (
        <Tooltip content={<span className="plan-sum__tip">{note}</span>}>
          <span className="plan-sum__item plan-sum__item--note" aria-label={t('Заметка')}>
            <ExitNoteIcon />
          </span>
        </Tooltip>
      ) : (
        <span className="plan-sum__item plan-sum__item--note is-empty">
          <ExitNoteIcon />
          <span>—</span>
        </span>
      )}
    </div>
  )
}
