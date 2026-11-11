import { useEffect, useState } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { EarlyEntry, PlannedExit, TrainingPlan, type CommonEntriesScope } from '@core/models'
import { PlanParser } from '@core/planParser'
import { AddIcon, CloseIcon, DoNotEnterIcon, EarlyEntryIcon, ExitNoteIcon, PrepIcon, RuleIcon, TriggerIcon } from '../ui/icons'
import { Checkbox, Segmented, Tooltip } from '../ui/kit'
import { DurationPopover } from './DurationEditor'
import {
  PlanFormat,
  addTrigger,
  editEarlyEntries,
  editableEntries,
  nextTone,
  removeTrigger,
  setUsesCommonEntries,
  suggestedTriggers,
  updateExit,
} from './planEdit'
import { linkedLines, type PlanTextLine } from './planText'

type SetPlan = (next: TrainingPlan | ((current: TrainingPlan) => TrainingPlan)) => void

// MARK: - Rules for the whole training

/// «Правила тренировки: ⛔ Залаяла, завыла — ждать тишины · 🔖 Фальстарт · ➡️ Подготовка · 4» above the table: the plan's
/// notes that are about the whole training. A click marks their lines in the trainer's text.
export function PlanRuleChips({ plan, lines, focused, onFocus }: { plan: TrainingPlan; lines: PlanTextLine[]; focused: string | null; onFocus: (key: string | null, lines: number[]) => void }) {
  const stop = TrainingPlan.doNotEnterRule(plan)
  const falseStart = plan.notes.find((note) => PlanParser.isFalseStartRule(note.toLowerCase()))
  const prep = plan.notes.filter(
    (note) => note !== stop?.text && note !== falseStart && !PlanParser.isDoNotEnterRule(note) && PlanParser.commonBreak(note) === null,
  )
  const ids = (kind: PlanTextLine['kind']['kind']) => lines.filter((line) => line.kind.kind === kind).map((line) => line.id)
  const chips = [
    stop && { key: 'stop', tone: 'stop', icon: <DoNotEnterIcon />, text: t('%@ — wait for quiet', stop.title), help: stop.text, lines: ids('doNotEnter') },
    falseStart && { key: 'rule', tone: 'rule', icon: <RuleIcon />, text: t('False Start'), help: falseStart, lines: ids('rule') },
    prep.length > 0 && { key: 'prep', tone: 'prep', icon: <PrepIcon />, text: t('Preparation · %lld', prep.length), help: prep.join('\n'), lines: ids('note') },
  ].filter((chip) => !!chip)
  if (!chips.length) return null
  return (
    <div className="plan-rules">
      <span className="plan-rules__label">{t('Training rules:')}</span>
      {chips.map((chip) => (
        <Tooltip key={chip.key} content={<span className="plan-rules__tip">{chip.help}</span>}>
          <button
            type="button"
            className={`plan-rules__chip plan-rules__chip--${chip.tone}` + (focused === chip.key ? ' is-on' : '')}
            aria-pressed={focused === chip.key}
            onClick={() => (focused === chip.key ? onFocus(null, []) : onFocus(chip.key, chip.lines))}
          >
            {chip.icon}
            <span className="ellipsis">{chip.text}</span>
          </button>
        </Tooltip>
      ))}
    </div>
  )
}

// MARK: - The common conditions

export type ScopeChoice = CommonEntriesScope | 'custom'

/// «Условия раннего входа — после всех выходов: 🟡 встала и пошла → через 2:00 · 🟢 легла → через 0:30. К каким
/// выходам применить?» with «Ко всем · К длинным ≥ 1 мин · Выбрать». «Выбрать» leaves it to the «Общие условия» box of
/// every exit in the inspector.
export function CommonEntriesBar({ plan, setPlan, lines, picking, setPicking }: { plan: TrainingPlan; setPlan: SetPlan; lines: PlanTextLine[]; picking: boolean; setPicking: (value: boolean) => void }) {
  const scope = TrainingPlan.commonEntriesScope(plan)
  const value: ScopeChoice = picking || scope === null ? 'custom' : scope
  // Where the trainer wrote them: after the last exit, before the first one, or (an edited plan) nowhere.
  const exitLines = lines.filter((line) => line.kind.kind === 'exit').map((line) => line.id)
  const entryLines = lines.filter((line) => line.kind.kind === 'earlyEntry' && line.kind.afterLine === null).map((line) => line.id)
  const where =
    !exitLines.length || !entryLines.length
      ? t('for the whole training')
      : entryLines[0] > exitLines[exitLines.length - 1]
        ? t('after all exits')
        : entryLines[entryLines.length - 1] < exitLines[0]
          ? t('before the exits')
          : t('for the whole training')
  return (
    <div className="plan-common">
      <EarlyEntryIcon className="plan-common__icon" />
      <div className="plan-common__text">
        <div className="plan-common__title">{t('Coming back early — %@', where)}</div>
        <div className="plan-common__entries">
          {plan.commonEarlyEntries.map((entry, index) => (
            <span key={entry.id} className="plan-common__entry">
              {index > 0 && <span className="plan-common__sep">·</span>}
              <span className={`tone-dot tone-dot--${entry.tone}`} />
              {PlanFormat.entryLine(entry)}
            </span>
          ))}
          <span className="plan-common__ask">{value === 'custom' ? t('Tick “Common conditions” on the exits below.') : t('Which exits do they apply to?')}</span>
        </div>
      </div>
      <Segmented<ScopeChoice>
        value={value}
        options={[
          { value: 'all', label: t('All exits') },
          { value: 'long', label: t('Long ones ≥ 1 min') },
          { value: 'custom', label: t('Choose') },
        ]}
        onChange={(choice) => {
          setPicking(choice === 'custom')
          if (choice !== 'custom') setPlan((current) => TrainingPlan.applyCommonEarlyEntries(current, choice))
        }}
      />
    </div>
  )
}

// MARK: - Inspector of the selected exit

/// Below the table: the selected exit's triggers (chips, «+ Добавить»), its conditions for coming back early (the
/// trainer's colour, what the dog does, «через 2:00» / «сразу»; «ИЛИ до вставания» is one of them, «Встала →
/// сразу»), and its note. A condition shown from the plan's common ones is marked «общее»; changing it gives this
/// exit its own copy.
export function ExitInspector({
  plan,
  setPlan,
  selection,
  lines,
  lineOfExit,
}: {
  plan: TrainingPlan
  setPlan: SetPlan
  selection: string[]
  lines: PlanTextLine[]
  lineOfExit: Map<string, number> | null
}) {
  const exit = selection.length === 1 ? plan.exits.find((item) => item.id === selection[0]) : undefined
  if (!exit) {
    return (
      <div className="plan-inspector plan-inspector--empty">
        {selection.length > 1
          ? t('%lld exits selected. Select one to edit its triggers, coming back early and note.', selection.length)
          : t('Select an exit in the table to edit its triggers, coming back early and note.')}
      </div>
    )
  }
  const own = lineOfExit && lines.length ? [...linkedLines(lines, lineOfExit, [exit.id])].sort((a, b) => a - b) : []
  const where = own.length === 0 ? null : own.length === 1 ? t('line %lld', own[0]) : t('lines %lld–%lld', own[0], own[own.length - 1])
  return (
    <div className="plan-inspector">
      <div className="plan-inspector__head">
        <span className="plan-inspector__title">{t('Exit %lld · %@', exit.number, DurationText.short(exit.duration))}</span>
        {where && <span className="faint">{where}</span>}
      </div>
      <div className="plan-inspector__columns">
        <TriggersEditor plan={plan} exit={exit} setPlan={setPlan} />
        <EntriesEditor plan={plan} exit={exit} setPlan={setPlan} />
        <NoteEditor exit={exit} setPlan={setPlan} />
      </div>
    </div>
  )
}

function TriggersEditor({ plan, exit, setPlan }: { plan: TrainingPlan; exit: PlannedExit; setPlan: SetPlan }) {
  const [adding, setAdding] = useState(false)
  const [text, setText] = useState('')
  const suggestions = suggestedTriggers(plan, exit.id)
  const commit = () => {
    if (text.trim()) setPlan((current) => addTrigger(current, exit.id, text))
    setText('')
  }
  useEffect(() => {
    setAdding(false)
    setText('')
  }, [exit.id])
  return (
    <section className="plan-inspector__column">
      <h4 className="plan-inspector__label">
        <TriggerIcon />
        {t('Triggers')}
      </h4>
      <div className="plan-chips">
        {exit.triggers.map((trigger, index) => (
          <span key={`${index}-${trigger}`} className="plan-chip">
            <TriggerIcon className="plan-chip__icon" />
            <span className="ellipsis">{trigger}</span>
            <button type="button" className="plan-chip__remove" aria-label={t('Remove “%@”', trigger)} onClick={() => setPlan((current) => removeTrigger(current, exit.id, index))}>
              <CloseIcon />
            </button>
          </span>
        ))}
        {adding ? (
          <input
            className="plan-chip plan-chip--input"
            autoFocus
            value={text}
            placeholder={t('jacket, shoes, keys…')}
            aria-label={t('New Trigger')}
            onChange={(event) => setText(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') {
                event.preventDefault()
                event.stopPropagation()
                commit()
              } else if (event.key === 'Escape') {
                event.preventDefault()
                event.stopPropagation()
                setText('')
                setAdding(false)
              }
            }}
            onBlur={() => {
              commit()
              setAdding(false)
            }}
          />
        ) : (
          <button type="button" className="plan-chip plan-chip--add" onClick={() => setAdding(true)}>
            <AddIcon className="plan-chip__icon" />
            {t('Add')}
          </button>
        )}
        {suggestions.map((trigger) => (
          <Tooltip key={trigger} content={t('Add “%@”', trigger)}>
            <button type="button" className="plan-chip plan-chip--suggestion" onClick={() => setPlan((current) => addTrigger(current, exit.id, trigger))}>
              {trigger}
            </button>
          </Tooltip>
        ))}
      </div>
    </section>
  )
}

function EntriesEditor({ plan, exit, setPlan }: { plan: TrainingPlan; exit: PlannedExit; setPlan: SetPlan }) {
  const entries = editableEntries(plan, exit)
  const common = TrainingPlan.usesCommonEarlyEntries(plan, exit)
  // A new condition's field takes the focus; left empty, the condition goes away again.
  const [fresh, setFresh] = useState<number | null>(null)
  useEffect(() => setFresh(null), [exit.id])
  const edit = (index: number, patch: Partial<EarlyEntry>) =>
    setPlan((current) => editEarlyEntries(current, exit.id, (list) => list.map((entry, other) => (other === index ? { ...entry, ...patch } : entry))))
  const remove = (index: number) => setPlan((current) => editEarlyEntries(current, exit.id, (list) => list.filter((_, other) => other !== index)))
  return (
    <section className="plan-inspector__column plan-inspector__column--wide">
      <h4 className="plan-inspector__label">
        <EarlyEntryIcon />
        {t('Coming back early')}
        <span className="spacer" />
        {plan.commonEarlyEntries.length > 0 && (
          <Tooltip content={t('The conditions the trainer wrote for the whole training apply to this exit too')}>
            <span className="plan-inspector__common">
              <Checkbox checked={common} onChange={(value) => setPlan((current) => setUsesCommonEntries(current, exit.id, value))}>
                {t('Common conditions')}
              </Checkbox>
            </span>
          </Tooltip>
        )}
      </h4>
      <div className="plan-entries">
        {entries.map((entry, index) => (
          // By position: a common condition's own copy has a new id, its field keeps the focus.
          <div key={index} className="plan-entry">
            <Tooltip content={t('The condition’s color — click to change it')}>
              <button type="button" className={`tone-dot tone-dot--${entry.tone} plan-entry__dot`} aria-label={t('Condition color')} onClick={() => edit(index, { tone: nextTone(entry.tone) })} />
            </Tooltip>
            <input
              className="plan-entry__event"
              value={entry.event}
              autoFocus={fresh === index}
              placeholder={t('What the dog did')}
              aria-label={t('What the dog did')}
              title={entry.detail ?? undefined}
              onChange={(event) => edit(index, { event: event.target.value })}
              onBlur={(event) => {
                if (fresh === index && event.target.value.trim() === '') remove(index)
                setFresh(null)
              }}
            />
            {common && <span className="plan-entry__common">{t('common')}</span>}
            <DurationPopover
              value={entry.delay ?? 0}
              onChange={(value) => edit(index, { delay: value !== null && value > 0 ? value : null })}
              title={t('Come in after')}
              presets={PlanFormat.entryPresets}
              zeroLabel={t('right away')}
              tint="exit"
            >
              <button type="button" className="plan-value plan-entry__delay tabular">
                {PlanFormat.entryDelay(entry)}
              </button>
            </DurationPopover>
            <Tooltip content={t('Remove condition')}>
              <button type="button" className="plan-entry__remove" aria-label={t('Remove condition')} onClick={() => remove(index)}>
                <CloseIcon />
              </button>
            </Tooltip>
          </div>
        ))}
        <button
          type="button"
          className="plan-entry plan-entry--add"
          onClick={() => {
            setFresh(entries.length)
            setPlan((current) => editEarlyEntries(current, exit.id, (list) => [...list, EarlyEntry.make({ event: '', delay: 30 })]))
          }}
        >
          <AddIcon />
          {t('Own condition')}
        </button>
      </div>
    </section>
  )
}

function NoteEditor({ exit, setPlan }: { exit: PlannedExit; setPlan: SetPlan }) {
  return (
    <section className="plan-inspector__column">
      <h4 className="plan-inspector__label">
        <ExitNoteIcon />
        {t('Note')}
      </h4>
      <textarea
        className="plan-inspector__note"
        value={exit.note ?? ''}
        placeholder={t('What to remember on this exit')}
        aria-label={t('Note')}
        onChange={(event) => {
          const note = event.target.value
          setPlan((current) => updateExit(current, exit.id, { note: note === '' ? null : note }))
        }}
      />
    </section>
  )
}
