import { useLayoutEffect, useRef, useState } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { TrainingPlan } from '@core/models'
import { formatTime } from '../model'
import { ChartIcon } from '../ui/icons'
import type { LiveSession } from './live'

/// Plan vs actual on one time axis (lanes: plan, actual, recording) with a playhead at "now".
interface Segment {
  start: number
  end: number
  kind: 'exit' | 'break' | 'own-break' | 'break-over' | 'walk' | 'outside' | 'over' | 'false' | 'rec' | 'future-exit' | 'future-break'
  label?: string
}

const LABEL_WIDTH = 86

export function SessionTimeline({ live }: { live: LiveSession }) {
  const [width, ref] = useWidth()
  const start = live.session.startedAt
  const planEnd = start + TrainingPlan.estimatedDuration(live.plan) * 1000
  const end = Math.max(planEnd, live.eta) + 120_000
  const span = Math.max(1, end - start)
  const usable = Math.max(1, width - LABEL_WIDTH - 16)
  const x = (time: number) => LABEL_WIDTH + ((time - start) / span) * usable
  const drift = live.drift

  return (
    <div className="timeline">
      <div className="timeline__header">
        <span className="h3">{t('Таймлайн')}</span>
        <Legend kind="exit" text={t('выход по плану')} />
        <Legend kind="outside" text={t('за дверью')} />
        <Legend kind="over" text={t('фальстарт / сверх плана')} />
        <Legend kind="break" text={t('перерыв')} />
        <Legend kind="break-over" text={t('перерыв сверх плана')} />
        <span className="spacer" />
        {drift !== null && (
          <span className="muted tabular" style={{ fontSize: 13 }}>
            {drift >= 0 ? t('отстаём от плана на %@', DurationText.clock(drift)) : t('опережаем план на %@', DurationText.clock(-drift))}
          </span>
        )}
      </div>
      <div className="timeline__body" ref={ref}>
        <Ruler start={start} end={end} x={x} />
        <div className="timeline__lanes">
          <Lane title={t('План')} segments={planSegments(live)} x={x} />
          <Lane title={t('Факт')} segments={factSegments(live)} x={x} />
          <Lane title={t('Запись')} segments={recordSegments(live)} x={x} thin />
        </div>
        <div className="timeline__playhead" style={{ left: x(live.now) }}>
          <span className="timeline__playhead-label tabular">{formatTime(live.now, true)}</span>
        </div>
      </div>
    </div>
  )
}

function planSegments(live: LiveSession): Segment[] {
  const plan = live.plan
  let time = live.session.startedAt
  const segments: Segment[] = []
  plan.exits.forEach((exit, index) => {
    segments.push({ start: time, end: time + Math.max(exit.duration, 4) * 1000, kind: 'exit', label: String(exit.number) })
    time += exit.duration * 1000
    if (index < plan.exits.length - 1) {
      const pause = TrainingPlan.breakAfter(plan, index)
      segments.push({ start: time, end: time + pause * 1000, kind: exit.breakAfter !== null ? 'own-break' : 'break', label: exit.breakAfter !== null ? DurationText.short(pause) : undefined })
      time += pause * 1000
    }
  })
  return segments
}

function factSegments(live: LiveSession): Segment[] {
  const segments: Segment[] = []
  const results = live.results()
  results.forEach((result, i) => {
    if (result.leftAt !== null) {
      // A walk to the door only in sessions run from an older iPhone («Начать выход»).
      if (result.leftAt > result.startedAt) segments.push({ start: result.startedAt, end: result.leftAt, kind: 'walk' })
      segments.push({ start: result.leftAt, end: Math.max(result.endedAt, result.leftAt + 4000), kind: result.falseStart ? 'false' : 'outside', label: result.falseStart ? '↺' : String(result.number) })
    } else if (result.falseStart) {
      // A false start before «Вышли»: a short mark where the break started over.
      segments.push({ start: result.startedAt, end: Math.max(result.endedAt, result.startedAt + 4000), kind: 'false', label: '↺' })
    }
    const next = i + 1 < results.length ? results[i + 1].startedAt : live.currentStart ?? live.now
    const planned = result.endedAt + result.plannedBreak * 1000
    segments.push({ start: result.endedAt, end: Math.min(next, planned), kind: 'break' })
    if (next > planned) segments.push({ start: planned, end: next, kind: 'break-over' })
  })
  const phase = live.phase
  if (phase.kind === 'leaving') {
    segments.push({ start: phase.since, end: live.now, kind: 'walk' })
  } else if (phase.kind === 'away') {
    if (phase.leftAt > phase.since) segments.push({ start: phase.since, end: phase.leftAt, kind: 'walk' })
    const planned = phase.leftAt + live.plan.exits[phase.exitIndex].duration * 1000
    segments.push({ start: phase.leftAt, end: Math.min(planned, live.now), kind: 'exit', label: String(live.plan.exits[phase.exitIndex].number) })
    if (live.now > planned) segments.push({ start: planned, end: live.now, kind: 'over' })
  }
  // What is left, projected from now: the rest of the current exit or break, then the plan as it goes.
  const index = live.currentExitIndex
  if (index !== null) {
    let time = live.now
    const started = phase.kind === 'away' || phase.kind === 'leaving'
    if (phase.kind === 'away') {
      time = Math.max(live.now, phase.leftAt + live.plan.exits[phase.exitIndex].duration * 1000)
    } else if (phase.kind === 'breakTime') {
      const left = Math.max(0, live.remaining ?? 0) * 1000
      if (left > 0) segments.push({ start: time, end: time + left, kind: 'future-break' })
      time += left
    }
    for (let i = index; i < live.plan.exits.length; i++) {
      if (i > index || !started) {
        const exit = live.plan.exits[i]
        segments.push({ start: time, end: time + Math.max(exit.duration, 4) * 1000, kind: 'future-exit', label: String(exit.number) })
        time += exit.duration * 1000
      }
      if (i < live.plan.exits.length - 1) {
        const pause = TrainingPlan.breakAfter(live.plan, i)
        segments.push({ start: time, end: time + pause * 1000, kind: 'future-break' })
        time += pause * 1000
      }
    }
  }
  return segments
}

function recordSegments(live: LiveSession): Segment[] {
  if (live.recordingSince === null) return []
  return [{ start: live.recordingSince, end: live.now, kind: 'rec', label: `REC ${DurationText.clock((live.now - live.recordingSince) / 1000)}` }]
}

export function Lane({ title, segments, x, thin }: { title: string; segments: Segment[]; x: (time: number) => number; thin?: boolean }) {
  return (
    <div className={'lane' + (thin ? ' lane--thin' : '')}>
      <span className="lane__title">{title}</span>
      {segments.map((segment, index) => {
        const left = x(segment.start)
        const width = Math.max(2, x(segment.end) - left)
        return (
          <div key={index} className={`seg seg--${segment.kind}`} style={{ left, width }}>
            {segment.label && (width > 12 || thin) && <span className="seg__label tabular">{segment.label}</span>}
          </div>
        )
      })}
    </div>
  )
}

function Ruler({ start, end, x }: { start: number; end: number; x: (time: number) => number }) {
  const ticks: { time: number; major: boolean }[] = []
  const first = new Date(start)
  first.setSeconds(0, 0)
  for (let time = first.getTime(); time <= end; time += 60_000) {
    if (time < start) continue
    ticks.push({ time, major: new Date(time).getMinutes() % 5 === 0 })
  }
  return (
    <div className="ruler">
      {ticks.map((tick) => (
        <div key={tick.time} className={'ruler__tick' + (tick.major ? ' ruler__tick--major' : '')} style={{ left: x(tick.time) }}>
          {tick.major && <span className="tabular">{formatTime(tick.time)}</span>}
        </div>
      ))}
    </div>
  )
}

function Legend({ kind, text }: { kind: string; text: string }) {
  return (
    <span className="legend">
      <span className={`legend__swatch seg--${kind}`} />
      {text}
    </span>
  )
}

/// Before anything is pasted: where the plan will appear.
export function EmptyTimeline() {
  return (
    <div className="empty-state" style={{ height: '100%' }}>
      <ChartIcon style={{ width: 28, height: 28 }} />
      <div className="empty-state__title">{t('Здесь появится план на шкале времени')}</div>
      <div style={{ fontSize: 13 }}>{t('После вставки расписания выходы и перерывы можно растянуть мышью перед стартом.')}</div>
    </div>
  )
}

export function useWidth(): [number, React.RefObject<HTMLDivElement | null>] {
  const ref = useRef<HTMLDivElement>(null)
  const [width, setWidth] = useState(0)
  useLayoutEffect(() => {
    const element = ref.current
    if (!element) return
    const observer = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width))
    observer.observe(element)
    setWidth(element.getBoundingClientRect().width)
    return () => observer.disconnect()
  }, [])
  return [width, ref]
}
