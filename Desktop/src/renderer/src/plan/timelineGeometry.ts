// Geometry and editing of the plan timeline (port of the logic in `MacPlanTimelineEditor`): blocks of exits and
// breaks laid out from the start, the time scale with zoom, the ruler steps, and the drag of a block's right edge
// (5 s steps, everything after it moves, a changed break becomes the exit's own break).
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { TrainingPlan } from '@core/models'

export type BlockKind = 'exit' | 'pause'

/// Right edge of one block: the exit at `index` or the break after it.
export interface BlockEdge {
  index: number
  kind: BlockKind
}

export interface PlanBlock {
  edge: BlockEdge
  /// Seconds from the start of the training.
  start: number
  duration: number
  /// Value in the trainer's text (null: the exit is not in it).
  original: number | null
  number: number
  /// A break of its own (not the plan's common break).
  own: boolean
  untilStanding: boolean
}

export const edgeKey = (edge: BlockEdge) => `${edge.kind}:${edge.index}`
export const sameEdge = (a: BlockEdge | null | undefined, b: BlockEdge | null | undefined) =>
  !!a && !!b && a.index === b.index && a.kind === b.kind

export const blockEnd = (block: PlanBlock) => block.start + block.duration
export const blockChanged = (block: PlanBlock) => block.original !== null && block.original !== block.duration

export function planBlocks(plan: TrainingPlan, original: TrainingPlan | null): PlanBlock[] {
  let time = 0
  const result: PlanBlock[] = []
  plan.exits.forEach((exit, index) => {
    const source = original ? original.exits.findIndex((item) => item.id === exit.id) : -1
    result.push({
      edge: { index, kind: 'exit' },
      start: time,
      duration: exit.duration,
      original: source >= 0 ? original!.exits[source].duration : null,
      number: exit.number,
      own: false,
      untilStanding: exit.untilStanding,
    })
    time += exit.duration
    if (index < plan.exits.length - 1) {
      const pause = TrainingPlan.breakAfter(plan, index)
      result.push({
        edge: { index, kind: 'pause' },
        start: time,
        duration: pause,
        original: source >= 0 ? TrainingPlan.breakAfter(original!, source) : null,
        number: exit.number,
        own: exit.breakAfter !== null,
        untilStanding: false,
      })
      time += pause
    }
  })
  return result
}

/// «Выход 6 · 2 мин или до вставания · у тренера 1 мин».
export function blockHelp(block: PlanBlock): string {
  const length = DurationText.short(block.duration)
  let text: string
  if (block.edge.kind === 'exit') {
    text = block.untilStanding ? t('Выход %lld · %@ или до вставания', block.number, length) : t('Выход %lld · %@', block.number, length)
  } else {
    text = block.own ? t('Перерыв после выхода %lld · %@, свой', block.number, length) : t('Перерыв после выхода %lld · %@', block.number, length)
  }
  if (blockChanged(block) && block.original !== null) text = t('%@ · у тренера %@', text, DurationText.short(block.original))
  return text
}

/// Exits, their order and the effective breaks differ from the trainer's plan (title edits don't count).
export function differs(plan: TrainingPlan, original: TrainingPlan): boolean {
  const schedule = (item: TrainingPlan) =>
    item.exits.map((exit, index) => ({
      id: exit.id,
      duration: exit.duration,
      pause: index < item.exits.length - 1 ? TrainingPlan.breakAfter(item, index) : 0,
      untilStanding: exit.untilStanding,
    }))
  return JSON.stringify(schedule(plan)) !== JSON.stringify(schedule(original))
}

/// «Как у тренера»: the exits and breaks from the trainer's text (title, date and trainers stay).
export function revertedToOriginal(plan: TrainingPlan, original: TrainingPlan): TrainingPlan {
  return { ...plan, exits: original.exits, defaultBreak: original.defaultBreak }
}

export function blockValue(plan: TrainingPlan, edge: BlockEdge): number {
  if (edge.index < 0 || edge.index >= plan.exits.length) return 0
  return edge.kind === 'exit' ? plan.exits[edge.index].duration : TrainingPlan.breakAfter(plan, edge.index)
}

/// A new length of one block. Back at the common break, a break is «как у всех» again (if the trainer had it so),
/// otherwise it becomes the exit's own break.
export function withBlockValue(plan: TrainingPlan, original: TrainingPlan | null, edge: BlockEdge, value: number): TrainingPlan {
  if (edge.index < 0 || edge.index >= plan.exits.length) return plan
  const exits = [...plan.exits]
  const exit = exits[edge.index]
  if (edge.kind === 'exit') {
    exits[edge.index] = { ...exit, duration: value }
  } else {
    const source = original?.exits.find((item) => item.id === exit.id)
    const wasCommon = source ? source.breakAfter === null : true
    exits[edge.index] = { ...exit, breakAfter: value === plan.defaultBreak && wasCommon ? null : value }
  }
  return { ...plan, exits }
}

export const Timeline = {
  /// Left padding of the lanes inside the scrolled area.
  inset: 12,
  /// Room after the plan for the finish flag and its time.
  trailingRoom: 72,
  zoomSteps: [1, 1.5, 2, 3, 4, 6, 8, 12] as readonly number[],
  maxZoom: 12,
  /// Drag step with Shift (and of the arrow keys); a plain drag goes by the second.
  snap: 5,
  maxDuration: 60 * 60,

  /// Seconds that fit the width at 100 %: the longer of the two plans.
  fitSpan(plan: TrainingPlan, original: TrainingPlan | null): number {
    return Math.max(60, original ? TrainingPlan.estimatedDuration(original) : 0, TrainingPlan.estimatedDuration(plan))
  },

  pointsPerSecond(width: number, span: number, zoom: number): number {
    return (Math.max(120, width - Timeline.inset - Timeline.trailingRoom) / span) * zoom
  },

  contentWidth(width: number, span: number, total: number, pps: number): number {
    return Math.max(width, Timeline.inset + Math.max(span, total) * pps + Timeline.trailingRoom)
  },

  /// Ruler labels at least ~64 px apart.
  labelStep(pps: number): number {
    return [10, 15, 30, 60, 120, 300, 600, 900].find((step) => step * pps >= 64) ?? 900
  },

  minorStep(pps: number, label: number): number {
    return [5, 10, 15, 30, 60, 120, 300].find((step) => label % step === 0 && step * pps >= 12) ?? label
  },

  /// Ticks of the ruler from the start to the right edge of the content.
  ticks(pps: number, width: number): { time: number; x: number; major: boolean }[] {
    const label = Timeline.labelStep(pps)
    const minor = Timeline.minorStep(pps, label)
    const ticks: { time: number; x: number; major: boolean }[] = []
    for (let time = 0; Timeline.inset + time * pps <= width; time += minor) {
      ticks.push({ time, x: Timeline.inset + time * pps, major: Math.trunc(time) % Math.trunc(label) === 0 })
    }
    return ticks
  },

  /// Dragging an edge by `dx` pixels from where it started: 5 s steps, exits from 5 s and breaks from 30 s (unless the
  /// trainer wrote less), up to an hour.
  resized(startValue: number, dx: number, pps: number, kind: BlockKind, step = 5): number {
    const raw = startValue + dx / pps
    const snapped = Math.round(raw / step) * step
    const minimum = Math.min(kind === 'exit' ? 5 : 30, startValue)
    return Math.min(Math.max(snapped, minimum), Timeline.maxDuration)
  },

  /// Keyboard (arrows on a focused edge): one step, the same limits as the drag.
  nudged(value: number, direction: 1 | -1, kind: BlockKind): number {
    const next = value + direction * Timeline.snap
    const minimum = Math.min(kind === 'exit' ? 5 : 30, value)
    return Math.min(Math.max(next, direction < 0 ? minimum : 0), Timeline.maxDuration)
  },

  /// The next zoom step in or out (the value itself when there is none).
  steppedZoom(zoom: number, direction: 1 | -1): number {
    const steps = Timeline.zoomSteps
    const next = direction > 0 ? steps.find((step) => step > zoom + 0.01) : [...steps].reverse().find((step) => step < zoom - 0.01)
    return next ?? zoom
  },

  clampZoom(zoom: number): number {
    return Math.min(Math.max(zoom, 1), Timeline.maxZoom)
  },

  /// Scroll offset that keeps the moment `time` at `anchor` px of the visible area after zooming.
  anchoredOffset(time: number, anchor: number, pps: number, contentWidth: number, viewport: number): number {
    const maxOffset = Math.max(0, contentWidth - viewport)
    return Math.min(Math.max(0, Timeline.inset + time * pps - anchor), maxOffset)
  },

  /// The moment under `anchor` px of the visible area.
  timeAt(offset: number, anchor: number, pps: number): number {
    return (offset + anchor - Timeline.inset) / pps
  },
}
