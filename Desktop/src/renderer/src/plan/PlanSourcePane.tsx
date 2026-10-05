import { useEffect, useMemo, useRef } from 'react'
import { t } from '@shared/i18n'
import type { TrainingPlan } from '@core/models'
import { SourceTextIcon, SuccessFilledIcon } from '../ui/icons'
import { Tooltip } from '../ui/kit'
import { PlanFormat } from './planEdit'
import { PlanLine, exitForLine, highlightLine, linkedLines, type PlanTextLine } from './planText'

/// The pasted text as a read-only source view: line numbers, a coloured bar for every recognised line, notes dimmed,
/// a legend at the bottom. The lines of the selected exits are highlighted; clicking an exit line selects its row.
export function PlanSourcePane({
  lines,
  plan,
  lineOfExit,
  selection,
  onSelect,
  width,
}: {
  lines: PlanTextLine[]
  plan: TrainingPlan
  lineOfExit: Map<string, number>
  selection: string[]
  onSelect: (id: string) => void
  width: number | null
}) {
  const linked = useMemo(() => linkedLines(lines, lineOfExit, selection), [lines, lineOfExit, selection])
  const first = linked.size ? Math.min(...linked) : null
  const last = linked.size ? Math.max(...linked) : null
  const scrollRef = useRef<HTMLDivElement>(null)

  // The linked lines (an exit and its own break) come into view, centred when they were out of sight.
  useEffect(() => {
    const container = scrollRef.current
    if (first === null || last === null || !container) return
    const top = container.querySelector<HTMLElement>(`[data-line="${first}"]`)
    const bottom = container.querySelector<HTMLElement>(`[data-line="${last}"]`)
    if (!top || !bottom) return
    const from = top.offsetTop
    const to = bottom.offsetTop + bottom.offsetHeight
    if (from >= container.scrollTop && to <= container.scrollTop + container.clientHeight) return
    container.scrollTo({ top: Math.max(0, (from + to) / 2 - container.clientHeight / 2), behavior: 'smooth' })
  }, [first, last])

  return (
    <section className="plan-source" style={width !== null ? { width } : undefined} aria-label={t('Текст тренера')}>
      <div className="plan-source__bar">
        <SourceTextIcon className="plan-source__bar-icon" />
        <span>{t('Текст тренера')}</span>
        <span className="spacer" />
        <span className="faint ellipsis">{t('разобран автоматически')}</span>
        <SuccessFilledIcon className="plan-source__ok" />
      </div>
      <div className="plan-source__lines selectable" ref={scrollRef}>
        {lines.map((line) => (
          <SourceLine
            key={line.id}
            line={line}
            linked={linked.has(line.id)}
            onClick={() => {
              const id = exitForLine(line, plan, lineOfExit)
              if (id) onSelect(id)
            }}
          />
        ))}
      </div>
      <Legend lines={lines} />
    </section>
  )
}

function SourceLine({ line, linked, onClick }: { line: PlanTextLine; linked: boolean; onClick: () => void }) {
  const kind = line.kind.kind
  const clickable = kind === 'exit' || kind === 'ownBreak'
  const row = (
    <div
      className={`plan-line plan-line--${kind}` + (linked ? ' is-linked' : '') + (clickable ? ' is-clickable' : '')}
      data-line={line.id}
      onClick={(event) => {
        // Selecting text with the mouse is not a click on the line.
        if (!clickable || window.getSelection()?.toString()) return
        event.preventDefault()
        onClick()
      }}
    >
      <span className="plan-line__no tabular">{line.id}</span>
      <span className="plan-line__bar" />
      <span className="plan-line__text">
        {highlightLine(line).map((run, index) => (
          <span key={index} className={`plan-run--${run.role}`}>
            {run.text}
          </span>
        ))}
      </span>
    </div>
  )
  const help = lineHelp(line)
  return help ? (
    <Tooltip content={help} side="right">
      {row}
    </Tooltip>
  ) : (
    row
  )
}

function lineHelp(line: PlanTextLine): string {
  switch (line.kind.kind) {
    case 'header':
      return t('Заголовок: название, тренеры и дата')
    case 'exit':
      return t('Выход %lld — щёлкните, чтобы выбрать его в таблице', line.kind.number)
    case 'ownBreak':
      return t('Свой перерыв после выхода выше')
    case 'defaultBreak':
      return t('Перерыв между выходами')
    case 'rule':
      return t('Правило фальстарта')
    case 'note':
      return t('Заметка тренера')
    case 'blank':
      return ''
  }
}

function Legend({ lines }: { lines: PlanTextLine[] }) {
  const exits = lines.filter(PlanLine.isExit).length
  const breaks = lines.filter(PlanLine.isBreak).length
  const notes = lines.filter((line) => line.kind.kind === 'note').length
  const rule = lines.some((line) => line.kind.kind === 'rule')
  return (
    <div className="plan-source__legend">
      <LegendItem kind="exit" text={PlanFormat.exits(exits)} />
      {breaks > 0 && <LegendItem kind="break" text={PlanFormat.breaks(breaks)} />}
      {rule && <LegendItem kind="rule" text={t('фальстарт')} />}
      {notes > 0 && <LegendItem kind="note" text={PlanFormat.notes(notes)} />}
      <span className="spacer" />
      <span className="faint plan-source__count">{PlanFormat.lines(lines.length)}</span>
    </div>
  )
}

function LegendItem({ kind, text }: { kind: string; text: string }) {
  return (
    <span className="plan-source__legend-item">
      <span className={`plan-source__swatch plan-source__swatch--${kind}`} />
      {text}
    </span>
  )
}
