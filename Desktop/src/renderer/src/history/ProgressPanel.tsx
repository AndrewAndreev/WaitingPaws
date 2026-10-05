import { useMemo, useState } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import type { TrainingRecord } from '@core/sessionLog'
import { ChevronDownIcon } from '../ui/icons'
import { Menu, MenuCheckItem, MenuContent, MenuTrigger, Tooltip } from '../ui/kit'
import { falseStarts, longestPlanned, longestStay, monotonePath, nearestIndex, progress, scale, stepPath, xAxisValues, yAxis, type Period } from './logic'
import { dayMonth } from './format'
import { historyUI, useHistoryUI } from './state'
import { useSize } from './useSize'

const PERIODS: { value: Period; title: string; gain: string }[] = [
  { value: 'fourWeeks', title: '4 недели', gain: 'За четыре недели' },
  { value: 'threeMonths', title: '3 месяца', gain: 'За три месяца' },
  { value: 'all', title: 'Всё время', gain: 'С первой тренировки' },
]

/// Top of the page (MacHistoryProgressPanel): key numbers on the left, «Дольше всего за дверью» per training on
/// the right. A click on a point opens that training in the table.
export function ProgressPanel({ records, selectedId, onReveal }: { records: TrainingRecord[]; selectedId: string | null; onReveal: (id: string) => void }) {
  const period = useHistoryUI((store) => store.period)
  const data = useMemo(() => progress(records, period), [records, period])
  const periodInfo = PERIODS.find((item) => item.value === period)!
  return (
    <section className="hprogress" aria-label={t('Дольше всего за дверью')}>
      <div className="hprogress__figures">
        {data.best ? (
          <Figure title={t('Рекорд за дверью')} value={DurationText.clock(longestStay(data.best))} note={t('%@ · план %@', dayMonth(data.best.startedAt), DurationText.clock(longestPlanned(data.best)))} />
        ) : (
          <Figure title={t('Рекорд за дверью')} value="—" note={t('пока ни одного выхода')} />
        )}
        <GainFigure title={data.includesFirstTraining ? t('С первой тренировки') : t(periodInfo.gain)} gain={data.gain} first={data.first} />
        <Figure
          title={t('Без фальстартов')}
          value={t('%lld из %lld', data.cleanCount, data.sessions.length)}
          note={data.falseStartTotal === 0 ? t('ни одного фальстарта') : t('фальстартов всего: %lld', data.falseStartTotal)}
        />
      </div>
      <div className="hprogress__chart">
        <div className="hprogress__header">
          <span className="h3 ellipsis">{t('Дольше всего за дверью')}</span>
          <span className="spacer" />
          <div className="hprogress__legend">
            <span className="legend">
              <span className="hlegend-line" />
              {t('дольше всего')}
            </span>
            <span className="legend">
              <span className="hlegend-dash" />
              {t('план')}
            </span>
            <span className="legend">
              <span className="hlegend-dot" />
              {t('был фальстарт')}
            </span>
          </div>
          <Menu>
            <Tooltip content={t('Период графика и цифр слева')}>
              <MenuTrigger asChild>
                <button type="button" className="btn btn--sm hprogress__period" aria-label={t('Период')}>
                  <span>{t(periodInfo.title)}</span>
                  <ChevronDownIcon />
                </button>
              </MenuTrigger>
            </Tooltip>
            <MenuContent align="end">
              {PERIODS.map((item) => (
                <MenuCheckItem key={item.value} checked={item.value === period} onSelect={() => historyUI.set({ period: item.value })}>
                  {t(item.title)}
                </MenuCheckItem>
              ))}
            </MenuContent>
          </Menu>
        </div>
        <Chart sessions={data.sessions} domain={data.domain} selectedId={selectedId} onReveal={onReveal} />
      </div>
    </section>
  )
}

function Figure({ title, value, note, tint }: { title: string; value: string; note: string; tint?: string }) {
  return (
    <div className="hfigure">
      <div className="hfigure__title">{title}</div>
      <div className="hfigure__value" style={tint ? { color: tint } : undefined}>
        {value}
      </div>
      <div className="hfigure__note">{note}</div>
    </div>
  )
}

function GainFigure({ title, gain, first }: { title: string; gain: number | null; first: TrainingRecord | null }) {
  if (gain === null || !first) return <Figure title={title} value="—" note={t('нужно хотя бы две тренировки')} />
  const tint = gain > 0 ? 'var(--success)' : gain < 0 ? 'var(--warning)' : undefined
  return <Figure title={title} value={(gain < 0 ? '−' : '+') + DurationText.clock(Math.abs(gain))} note={t('было %@ %@', DurationText.clock(longestStay(first)), dayMonth(first.startedAt))} tint={tint} />
}

const MARGIN = { left: 44, right: 14, top: 26, bottom: 24 }

/// Longest stay per training (line with a soft area, monotone), the plan's longest exit (dashed steps), points
/// orange where the training had a false start; hover shows the date and value, click opens the training.
function Chart({ sessions, domain, selectedId, onReveal }: { sessions: TrainingRecord[]; domain: [number, number]; selectedId: string | null; onReveal: (id: string) => void }) {
  const [size, ref] = useSize<HTMLDivElement>()
  const [hovered, setHovered] = useState<number | null>(null)
  const width = Math.max(0, size.width)
  const height = Math.max(0, size.height)
  const axis = yAxis(sessions)
  const x = scale(domain, [MARGIN.left, width - MARGIN.right])
  const y = scale([0, axis.max], [height - MARGIN.bottom, MARGIN.top])
  const baseline = height - MARGIN.bottom
  const points = sessions.map((record) => [x(record.startedAt), y(longestStay(record))] as [number, number])
  const plan = sessions.map((record) => [x(record.startedAt), y(longestPlanned(record))] as [number, number])
  const line = monotonePath(points)
  const area = points.length > 1 ? `${line}L${points[points.length - 1][0]},${baseline}L${points[0][0]},${baseline}Z` : ''
  const yTicks: number[] = []
  for (let value = 0; value <= axis.max + 0.001; value += axis.step) yTicks.push(value)
  const xTicks = xAxisValues(domain)
  const selectedIndex = sessions.findIndex((record) => record.id === selectedId)
  const labelled = [...new Set([selectedIndex, hovered ?? -1])].filter((index) => index >= 0)
  const xs = points.map((point) => point[0])

  const pointer = (event: React.MouseEvent) => {
    const box = (event.currentTarget as HTMLElement).getBoundingClientRect()
    return nearestIndex(xs, event.clientX - box.left)
  }

  return (
    <div
      className="hchart"
      ref={ref}
      onMouseMove={(event) => setHovered(pointer(event))}
      onMouseLeave={() => setHovered(null)}
      onClick={(event) => {
        const index = pointer(event)
        if (index !== null) onReveal(sessions[index].id)
      }}
      style={{ cursor: hovered !== null ? 'pointer' : 'default' }}
      role="img"
      aria-label={t('График: дольше всего за дверью по тренировкам')}
    >
      {width > 0 && height > 0 && (
        <svg width={width} height={height} className="hchart__svg">
          <defs>
            <linearGradient id="hchart-area" x1="0" x2="0" y1="0" y2="1">
              <stop offset="0" stopColor="var(--phase-outside)" stopOpacity="0.22" />
              <stop offset="1" stopColor="var(--phase-outside)" stopOpacity="0" />
            </linearGradient>
          </defs>
          {yTicks.map((value) => (
            <g key={'y' + value}>
              <line className="hchart__grid" x1={MARGIN.left} x2={width - MARGIN.right} y1={y(value)} y2={y(value)} />
              <text className="hchart__axis" x={MARGIN.left - 8} y={y(value)} textAnchor="end" dominantBaseline="middle">
                {DurationText.clock(value)}
              </text>
            </g>
          ))}
          {xTicks.map((value) => (
            <g key={'x' + value}>
              <line className="hchart__grid" x1={x(value)} x2={x(value)} y1={MARGIN.top - 8} y2={baseline} />
              <text className="hchart__axis" x={x(value) + 4} y={height - 6}>
                {dayMonth(value)}
              </text>
            </g>
          ))}
          {area && <path d={area} fill="url(#hchart-area)" />}
          {plan.length > 0 && <path d={stepPath(plan)} className="hchart__plan" />}
          {selectedIndex >= 0 && <line className="hchart__rule" x1={points[selectedIndex][0]} x2={points[selectedIndex][0]} y1={MARGIN.top - 8} y2={baseline} />}
          {hovered !== null && hovered !== selectedIndex && <line className="hchart__crosshair" x1={points[hovered][0]} x2={points[hovered][0]} y1={MARGIN.top - 8} y2={baseline} />}
          {points.length > 1 && <path d={line} className="hchart__line" />}
          {sessions.map((record, index) => (
            <circle
              key={record.id}
              cx={points[index][0]}
              cy={points[index][1]}
              r={index === selectedIndex ? 6 : index === hovered ? 5 : 4}
              className={'hchart__point' + (falseStarts(record) > 0 ? ' hchart__point--false' : '')}
            />
          ))}
        </svg>
      )}
      {width > 0 &&
        labelled.map((index) => (
          <span
            key={'label' + index}
            className="hchart__label tabular"
            style={{ left: Math.min(Math.max(points[index][0], MARGIN.left + 40), width - 52), top: Math.max(0, points[index][1] - 30) }}
          >
            {dayMonth(sessions[index].startedAt)} · {DurationText.clock(longestStay(sessions[index]))}
          </span>
        ))}
    </div>
  )
}
