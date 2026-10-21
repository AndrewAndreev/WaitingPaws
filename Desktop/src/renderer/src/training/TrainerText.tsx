import { useLayoutEffect, useMemo, useRef, useState } from 'react'
import { t } from '@shared/i18n'
import type { TrainingPlan } from '@core/models'
import { PlanParser, type SourceLine } from '@core/planParser'
import { ExpandIcon, SourceTextIcon } from '../ui/icons'
import { Button, Dialog, Tooltip } from '../ui/kit'

/// «Текст тренера» in the training panel, under the buttons and the exit's conditions: the trainer's message line by
/// line as `PlanParser.sourceLines` reads it. The lines of the exit at `exitIndex` (its own line and the conditions
/// under it) carry a pink bar, the exits before it are dimmed, and the list scrolls to keep that exit in view when it
/// changes. «Развернуть» opens the same text in a larger window.
export function TrainerText({ plan, exitIndex }: { plan: TrainingPlan; exitIndex: number | null }) {
  const [expanded, setExpanded] = useState(false)
  const lines = useSourceLines(plan.rawText)
  if (!lines.some((line) => line.kind !== 'blank')) return null
  return (
    <section className="trainer-text">
      <h4 className="brief__title">
        <SourceTextIcon />
        {t('Текст тренера')}
        <span className="spacer" />
        <Tooltip content={t('Развернуть')}>
          <Button variant="subtle" size="sm" iconOnly className="trainer-text__expand" icon={<ExpandIcon />} aria-label={t('Развернуть')} onClick={() => setExpanded(true)} />
        </Tooltip>
      </h4>
      <TrainerLines plan={plan} lines={lines} exitIndex={exitIndex} />
      {expanded && (
        <Dialog open onOpenChange={(open) => !open && setExpanded(false)} title={t('Текст тренера')} width={760} height={820} bodyClassName="trainer-text__dialog">
          <TrainerLines plan={plan} lines={lines} exitIndex={exitIndex} large />
        </Dialog>
      )}
    </section>
  )
}

function useSourceLines(text: string): SourceLine[] {
  return useMemo(() => PlanParser.sourceLines(text), [text])
}

function TrainerLines({ plan, lines, exitIndex, large = false }: { plan: TrainingPlan; lines: SourceLine[]; exitIndex: number | null; large?: boolean }) {
  const ref = useRef<HTMLDivElement>(null)
  // The exits follow the exit lines in order (the training renumbers them 1…n); by the written number when the plan
  // was edited and the counts differ.
  const written = lines.flatMap((line) => (line.kind === 'exit' && line.exitNumber !== null ? [line.exitNumber] : []))
  const numberOf = (index: number) => (written.length === plan.exits.length ? written[index] : plan.exits[index]?.number)
  const current = exitIndex === null ? null : numberOf(exitIndex) ?? null
  const past = new Set<number>()
  for (let index = 0; index < Math.min(exitIndex ?? plan.exits.length, plan.exits.length); index++) {
    const number = numberOf(index)
    if (number !== undefined && number !== current) past.add(number)
  }

  // The current exit's lines come into view when it changes, with a line or two of what came before — and again when
  // the list gets taller or shorter (the conditions above it come and go with the phase).
  useLayoutEffect(() => {
    const container = ref.current
    if (!container || current === null) return
    // A jump: a smooth scroll here often stopped short when it started together with the exit strip's.
    const reveal = () => {
      const block = [...container.querySelectorAll<HTMLElement>('.trainer-line.is-current')]
      if (!block.length) return
      const top = block[0].offsetTop
      const bottom = block[block.length - 1].offsetTop + block[block.length - 1].offsetHeight
      const context = Math.min(48, Math.max(0, container.clientHeight - (bottom - top)) / 2)
      container.scrollTo({ top: Math.max(0, top - context) })
    }
    reveal()
    let height = container.clientHeight
    const observer = new ResizeObserver(() => {
      if (container.clientHeight === height) return
      height = container.clientHeight
      reveal()
    })
    observer.observe(container)
    return () => observer.disconnect()
  }, [current])

  return (
    <div className={'trainer-text__lines selectable' + (large ? ' trainer-text__lines--large' : '')} ref={ref}>
      {lines.map((line) => {
        if (line.kind === 'blank') return <div key={line.id} className="trainer-line trainer-line--blank" />
        const state = line.exitNumber === null ? '' : line.exitNumber === current ? ' is-current' : past.has(line.exitNumber) ? ' is-past' : ''
        return (
          <p key={line.id} className={`trainer-line trainer-line--${line.kind}${state}`}>
            {line.kind === 'falseStart' ? <FalseStartLine text={line.text} /> : line.text}
          </p>
        )
      })}
    </div>
  )
}

/// «🔖 Фальстарт:» as a label, the rule after it in plain text.
function FalseStartLine({ text }: { text: string }) {
  const colon = text.indexOf(':')
  if (colon < 0) return <span className="trainer-line__label">{text}</span>
  return (
    <>
      <span className="trainer-line__label">{text.slice(0, colon + 1)}</span>
      {text.slice(colon + 1)}
    </>
  )
}
