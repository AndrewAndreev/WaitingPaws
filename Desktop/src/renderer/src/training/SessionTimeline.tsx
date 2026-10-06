import { useLayoutEffect, useRef, useState, type HTMLAttributes, type PointerEvent as ReactPointerEvent, type Ref } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { TrainingPlan } from '@core/models'
import { call, ui } from '../store'
import { formatTime } from '../model'
import { ChartIcon, EditIcon } from '../ui/icons'
import { Button } from '../ui/kit'
import { DurationPopover } from '../plan/DurationEditor'
import { PlanFormat } from '../plan/planEdit'
import type { LiveSession } from './live'

/// Plan vs actual on one time axis (lanes: plan, actual, recording) with a playhead at "now" — from the first exit on
/// (until then the plan slides along with now). The header carries the numbers of the whole training. The plan lane
/// is the schedule itself: click an exit or a break to type its length, or drag its right edge (Shift: 5 s steps).
/// Edits apply as they go — the timer follows at once, a linked iPhone gets every step — and the log notes each one
/// once, when it is done.
type SegmentKind =
  | 'exit'
  | 'break'
  | 'own-break'
  | 'break-over'
  | 'walk'
  | 'outside'
  | 'over'
  | 'false'
  | 'rec'
  | 'future-exit'
  | 'future-break'

interface Segment {
  start: number
  end: number
  kind: SegmentKind
  label?: string
  /// One bar in two colours: from `split` on it is `splitKind` (an exit or a break past its plan).
  split?: number
  splitKind?: SegmentKind
  edge?: PlanEdge
}

/// One block of the plan: the exit at `index` or the break after it.
interface PlanEdge {
  index: number
  kind: 'exit' | 'pause'
}

interface EdgeDrag {
  edge: PlanEdge
  startValue: number
  /// The axis frozen for the drag, so the edge stays under the pointer while the plan grows.
  start: number
  end: number
}

const LABEL_WIDTH = 86
/// Room before the first exit, so its start is not glued to the lane titles (seconds).
const LEAD = 15

const sameEdge = (a: PlanEdge | null | undefined, b: PlanEdge | null | undefined) => !!a && !!b && a.index === b.index && a.kind === b.kind

export function SessionTimeline({ live }: { live: LiveSession }) {
  const [width, ref] = useWidth()
  const [drag, setDrag] = useState<EdgeDrag | null>(null)
  /// The plan as the drag or the typing left it, drawn until the backend's state catches up.
  const [draft, setDraft] = useState<TrainingPlan | null>(null)
  /// The block being typed and the plan before it (the log notes the whole edit against it).
  const typing = useRef<{ edge: PlanEdge; start: TrainingPlan; plan: TrainingPlan } | null>(null)
  const [typed, setTyped] = useState<PlanEdge | null>(null)
  const plan = draft ?? live.plan

  const planStart = live.planStart
  const start = drag?.start ?? planStart - LEAD * 1000
  const end = drag?.end ?? Math.max(planStart + TrainingPlan.estimatedDuration(plan) * 1000, live.eta) + 120_000
  const span = Math.max(1, end - start)
  const usable = Math.max(1, width - LABEL_WIDTH - 16)
  const x = (time: number) => LABEL_WIDTH + ((time - start) / span) * usable
  const pps = (usable / span) * 1000

  /// One step of an edit: applied at once, without a note.
  const step = (edited: TrainingPlan) => void call('session.updatePlan', edited, { quiet: true })
  /// The edit is done: one note with everything it changed.
  const finish = (edited: TrainingPlan, start: TrainingPlan) => {
    if (JSON.stringify(edited) !== JSON.stringify(start)) void call('session.updatePlan', edited, { changesSince: start })
  }

  const startResize = (event: ReactPointerEvent, edge: PlanEdge) => {
    if (event.button !== 0) return
    event.preventDefault()
    event.stopPropagation()
    const frozen: EdgeDrag = { edge, startValue: blockValue(live.plan, edge), start, end }
    const frozenPps = pps
    const startX = event.clientX
    const before = live.plan
    let current = before
    setDrag(frozen)
    setDraft(current)
    document.body.classList.add('is-resizing-columns')
    const move = (moveEvent: PointerEvent) => {
      // By the second; with Shift the 5 s grid.
      const grid = moveEvent.shiftKey ? 5 : 1
      const raw = frozen.startValue + (moveEvent.clientX - startX) / frozenPps
      const value = Math.min(Math.max(Math.round(raw / grid) * grid, 0), 60 * 60)
      if (value === blockValue(current, edge)) return
      current = withValue(current, edge, value)
      setDraft(current)
      step(current)
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      window.removeEventListener('pointercancel', up)
      document.body.classList.remove('is-resizing-columns')
      finish(current, before)
      setDrag(null)
      setDraft(null)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
    window.addEventListener('pointercancel', up)
  }

  const planSegments = planLane(plan, planStart)

  return (
    <div className="timeline">
      <div className="timeline__header">
        <span className="h3">{t('Таймлайн')}</span>
        <span className="timeline__legend">
          <Legend kind="exit" text={t('выход по плану')} />
          <Legend kind="outside" text={t('за дверью')} />
          <Legend kind="over" text={t('фальстарт / сверх плана')} />
          <Legend kind="break" text={t('перерыв')} />
          <Legend kind="break-over" text={t('перерыв сверх плана')} />
        </span>
        <span className="spacer" />
        <Stats live={live} />
        <Button icon={<EditIcon />} onClick={() => ui.set({ editingSessionPlan: true })} title={t('Поправить выходы и перерывы прямо во время тренировки')}>
          {t('Расписание…')}
        </Button>
      </div>
      <div className="timeline__body" ref={ref}>
        <Ruler start={start} end={end} x={x} />
        <div className="timeline__lanes">
          <div className="lane">
            <span className="lane__title">{t('План')}</span>
            {planSegments.map((segment, index) => {
              const edge = segment.edge!
              const value = blockValue(live.plan, edge)
              const own = edge.kind === 'pause' && live.plan.exits[edge.index]?.breakAfter !== null
              return (
                <DurationPopover
                  key={index}
                  value={edge.kind === 'pause' && !own ? null : value}
                  onChange={(next) => {
                    const edit = typing.current
                    if (!edit || !sameEdge(edit.edge, edge)) return
                    // Into the plan as it is typed: the timer follows.
                    edit.plan = withValue(edit.plan, edge, edge.kind === 'exit' ? (next ?? blockValue(edit.plan, edge)) : next)
                    setDraft(edit.plan)
                    step(edit.plan)
                  }}
                  onOpenChange={(open) => {
                    if (open) {
                      typing.current = { edge, start: live.plan, plan: live.plan }
                      setTyped(edge)
                      return
                    }
                    const edit = typing.current
                    typing.current = null
                    setTyped(null)
                    setDraft(null)
                    if (edit && sameEdge(edit.edge, edge)) finish(edit.plan, edit.start)
                  }}
                  title={edgeTitle(plan, edge)}
                  presets={edge.kind === 'exit' ? PlanFormat.exitPresets : PlanFormat.breakPresets}
                  defaultValue={edge.kind === 'pause' ? live.plan.defaultBreak : undefined}
                  tint={edge.kind === 'exit' ? 'exit' : 'break'}
                >
                  <SegmentView segment={segment} x={x} editable active={sameEdge(drag?.edge, edge) || sameEdge(typed, edge)} />
                </DurationPopover>
              )
            })}
            {planSegments.map((segment, index) => (
              <div
                key={`h${index}`}
                className={'tl-handle' + (sameEdge(drag?.edge, segment.edge) ? ' is-active' : '')}
                style={{ left: x(segment.end) - 5 }}
                onPointerDown={(event) => startResize(event, segment.edge!)}
                title={t('Тяните край блока, чтобы изменить длительность (⇧ — по 5 с)')}
              >
                <span className="tl-handle__grip" />
              </div>
            ))}
          </div>
          <Lane title={t('Факт')} segments={factSegments(live, plan)} x={x} />
          <Lane title={t('Запись')} segments={recordSegments(live)} x={x} thin />
        </div>
        <div className="timeline__playhead" style={{ left: x(live.now) }}>
          <span className="timeline__playhead-label tabular">{formatTime(live.now, true)}</span>
        </div>
        {drag && <DragTip plan={plan} drag={drag} x={x(planSegments.find((segment) => sameEdge(segment.edge, drag.edge))?.end ?? live.now)} />}
      </div>
    </div>
  )
}

/// The whole training at a glance: exits, false starts, how long it runs, the planned end, how far from the plan.
function Stats({ live }: { live: LiveSession }) {
  const drift = live.drift
  return (
    <span className="timeline__stats">
      <Stat value={t('%lld из %lld', live.completedExits, live.plan.exits.length)} label={t('выходов')} />
      <Stat value={String(live.falseStarts)} label={t('фальстартов')} warn={live.falseStarts > 0} />
      <Stat value={DurationText.clock((live.now - live.session.startedAt) / 1000)} label={t('идёт тренировка')} />
      <Stat value={`≈ ${formatTime(live.eta)}`} label={t('конец по плану')} />
      {drift !== null && Math.abs(drift) >= 1 && (
        <span title={drift > 0 ? t('отстаём от плана на %@', DurationText.clock(drift)) : t('опережаем план на %@', DurationText.clock(-drift))}>
          <Stat value={(drift > 0 ? '+' : '−') + DurationText.clock(Math.abs(drift))} label={t('от плана')} warn={drift > 60} />
        </span>
      )}
    </span>
  )
}

function Stat({ value, label, warn }: { value: string; label: string; warn?: boolean }) {
  return (
    <span className="stat">
      <span className="stat__value tabular" style={warn ? { color: 'var(--warning)' } : undefined}>
        {value}
      </span>
      <span className="stat__label">{label}</span>
    </span>
  )
}

/// «Выход 4 · 0:50 (+0:05)» above the edge being dragged.
function DragTip({ plan, drag, x }: { plan: TrainingPlan; drag: EdgeDrag; x: number }) {
  const value = blockValue(plan, drag.edge)
  const delta = value - drag.startValue
  return (
    <span className="tl-tip tabular" style={{ left: x }}>
      {edgeTitle(plan, drag.edge)} · <b>{DurationText.clock(value)}</b>
      {delta !== 0 && <span className="tl-tip__delta"> ({PlanFormat.signed(delta)})</span>}
    </span>
  )
}

function edgeTitle(plan: TrainingPlan, edge: PlanEdge): string {
  const number = plan.exits[edge.index]?.number ?? edge.index + 1
  return edge.kind === 'exit' ? t('Выход %lld', number) : t('Перерыв после %lld', number)
}

function blockValue(plan: TrainingPlan, edge: PlanEdge): number {
  const exit = plan.exits[edge.index]
  if (!exit) return 0
  return edge.kind === 'exit' ? exit.duration : TrainingPlan.breakAfter(plan, edge.index)
}

/// `plan` with the block at `edge` set to `value` (a break other than the common one becomes the exit's own; null:
/// the common one).
function withValue(plan: TrainingPlan, edge: PlanEdge, value: number | null): TrainingPlan {
  const exit = plan.exits[edge.index]
  if (!exit) return plan
  const changed =
    edge.kind === 'exit'
      ? { ...exit, duration: Math.max(0, value ?? exit.duration) }
      : { ...exit, breakAfter: value === null || value === plan.defaultBreak ? null : value }
  return { ...plan, exits: plan.exits.map((item, index) => (index === edge.index ? changed : item)) }
}

/// The schedule laid out from the first exit; every block can be edited.
function planLane(plan: TrainingPlan, planStart: number): Segment[] {
  let time = planStart
  const segments: Segment[] = []
  plan.exits.forEach((exit, index) => {
    segments.push({ start: time, end: time + Math.max(exit.duration, 4) * 1000, kind: 'exit', label: String(exit.number), edge: { index, kind: 'exit' } })
    time += exit.duration * 1000
    if (index < plan.exits.length - 1) {
      const pause = TrainingPlan.breakAfter(plan, index)
      segments.push({
        start: time,
        end: time + pause * 1000,
        kind: exit.breakAfter !== null ? 'own-break' : 'break',
        label: exit.breakAfter !== null ? DurationText.short(pause) : undefined,
        edge: { index, kind: 'pause' },
      })
      time += pause * 1000
    }
  })
  return segments
}

function factSegments(live: LiveSession, plan: TrainingPlan): Segment[] {
  const segments: Segment[] = []
  const results = live.results()
  results.forEach((result, i) => {
    if (result.leftAt !== null) {
      // A walk to the door only in sessions run from an older iPhone («Начать выход»).
      if (result.leftAt > result.startedAt) segments.push({ start: result.startedAt, end: result.leftAt, kind: 'walk' })
      const planned = result.leftAt + result.plannedDuration * 1000
      segments.push({
        start: result.leftAt,
        end: Math.max(result.endedAt, result.leftAt + 4000),
        kind: result.falseStart ? 'false' : 'outside',
        label: result.falseStart ? '↺' : String(result.number),
        split: !result.falseStart && result.endedAt > planned ? planned : undefined,
        splitKind: 'over',
      })
    } else if (result.falseStart) {
      // A false start before «Вышли»: a short mark where the break started over.
      segments.push({ start: result.startedAt, end: Math.max(result.endedAt, result.startedAt + 4000), kind: 'false', label: '↺' })
    }
    const next = i + 1 < results.length ? results[i + 1].startedAt : live.currentStart ?? live.now
    const planned = result.endedAt + result.plannedBreak * 1000
    segments.push({ start: result.endedAt, end: next, kind: 'break', split: next > planned ? planned : undefined, splitKind: 'break-over' })
  })
  const phase = live.phase
  if (phase.kind === 'leaving') {
    segments.push({ start: phase.since, end: live.now, kind: 'walk' })
  } else if (phase.kind === 'away') {
    if (phase.leftAt > phase.since) segments.push({ start: phase.since, end: phase.leftAt, kind: 'walk' })
    const planned = phase.leftAt + plan.exits[phase.exitIndex].duration * 1000
    segments.push({
      start: phase.leftAt,
      end: Math.max(live.now, phase.leftAt + 1000),
      kind: 'exit',
      label: String(plan.exits[phase.exitIndex].number),
      split: live.now > planned ? planned : undefined,
      splitKind: 'over',
    })
  }
  // What is left, projected from now: the rest of the current exit or break, then the plan as it goes.
  const index = live.currentExitIndex
  if (index !== null && index < plan.exits.length) {
    let time = live.now
    const started = phase.kind === 'away' || phase.kind === 'leaving'
    if (phase.kind === 'away') {
      time = Math.max(live.now, phase.leftAt + plan.exits[phase.exitIndex].duration * 1000)
    } else if (phase.kind === 'breakTime') {
      const left = Math.max(0, live.remaining ?? 0) * 1000
      if (left > 0) segments.push({ start: time, end: time + left, kind: 'future-break' })
      time += left
    }
    for (let i = index; i < plan.exits.length; i++) {
      if (i > index || !started) {
        const exit = plan.exits[i]
        segments.push({ start: time, end: time + Math.max(exit.duration, 4) * 1000, kind: 'future-exit', label: String(exit.number) })
        time += exit.duration * 1000
      }
      if (i < plan.exits.length - 1) {
        const pause = TrainingPlan.breakAfter(plan, i)
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
      {segments.map((segment, index) => (
        <SegmentView key={index} segment={segment} x={x} thin={thin} />
      ))}
    </div>
  )
}

/// A block of a lane; an overrun is the same bar in a second colour (no seam: it is the same stage going on).
/// Nothing is drawn left of the axis (a recording started before the first exit is cut at its start). As a popover
/// trigger it takes the trigger's props and ref onto its element.
function SegmentView({
  segment,
  x,
  thin,
  editable,
  active,
  ref,
  ...rest
}: { segment: Segment; x: (time: number) => number; thin?: boolean; editable?: boolean; active?: boolean; ref?: Ref<HTMLDivElement> } & HTMLAttributes<HTMLDivElement>) {
  const left = Math.max(LABEL_WIDTH, x(segment.start))
  const right = x(segment.end)
  if (right <= LABEL_WIDTH) return null
  const width = Math.max(2, right - left)
  const splitAt = segment.split !== undefined ? x(segment.split) - left : null
  const split = splitAt !== null && splitAt > 0 && splitAt < width && segment.splitKind
  const label = segment.label && (width > 12 || thin) && <span className="seg__label tabular">{segment.label}</span>
  const className = 'seg' + (split ? ' seg--split' : ` seg--${segment.kind}`) + (editable ? ' seg--editable' : '') + (active ? ' is-active' : '')
  return (
    <div {...rest} ref={ref} className={className} style={{ left, width }}>
      {split && (
        <>
          <span className={`seg__fill seg--${segment.kind}`} style={{ width: splitAt }} />
          <span className={`seg__fill seg--${segment.splitKind}`} style={{ flex: 1 }} />
        </>
      )}
      {label}
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
