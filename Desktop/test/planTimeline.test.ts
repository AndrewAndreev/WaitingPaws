// The plan timeline's geometry and edge dragging (port of MacPlanTimelineEditor's logic).
import { beforeEach, describe, expect, it } from 'vitest'
import { PlanParser, TrainingPlan, setCoreLanguage } from '@core/index'
import { setLanguage } from '@shared/i18n'
import {
  Timeline,
  blockChanged,
  blockEnd,
  blockHelp,
  blockValue,
  differs,
  planBlocks,
  revertedToOriginal,
  withBlockValue,
} from '../src/renderer/src/plan/timelineGeometry'

const text = `Тренировка - Таня - 04.10.2026
Все перерывы 2 минуты
1 выход - 10 секунд
2 выход - 1 минута ИЛИ до вставания
Перерыв 5 минут
3 выход - 30 секунд`

beforeEach(() => {
  setCoreLanguage('ru')
  setLanguage('ru')
})

describe('plan blocks', () => {
  it('lays exits and breaks out from the start', () => {
    const plan = PlanParser.parse(text)
    const blocks = planBlocks(plan, plan)
    expect(blocks.map((block) => [block.edge.kind, block.edge.index, block.start, block.duration, block.own])).toEqual([
      ['exit', 0, 0, 10, false],
      ['pause', 0, 10, 120, false],
      ['exit', 1, 130, 60, false],
      ['pause', 1, 190, 300, true],
      ['exit', 2, 490, 30, false],
    ])
    expect(blockEnd(blocks[4])).toBe(TrainingPlan.estimatedDuration(plan))
    expect(blocks.some(blockChanged)).toBe(false)
    expect(blocks[2].untilStanding).toBe(true)
    expect(planBlocks(plan, null).every((block) => block.original === null)).toBe(true)
  })

  it('describes blocks with the trainer’s value when changed', () => {
    const plan = PlanParser.parse(text)
    const longer = withBlockValue(plan, plan, { index: 1, kind: 'exit' }, 90)
    const block = planBlocks(longer, plan)[2]
    expect(blockChanged(block)).toBe(true)
    expect(blockHelp(block)).toBe('Выход 2 · 1 мин 30 с или до вставания · у тренера 1 мин')
    expect(blockHelp(planBlocks(plan, plan)[3])).toBe('Перерыв после выхода 2 · 5 мин, свой')
  })

  it('knows when the plan differs from the trainer’s', () => {
    const plan = PlanParser.parse(text)
    expect(differs({ ...plan, title: 'Другое' }, plan)).toBe(false)
    const changed = withBlockValue(plan, plan, { index: 0, kind: 'exit' }, 15)
    expect(differs(changed, plan)).toBe(true)
    expect(differs({ ...plan, exits: [...plan.exits].reverse() }, plan)).toBe(true)
    // The same effective breaks written differently are the same schedule.
    expect(differs({ ...plan, exits: plan.exits.map((exit, index) => (index === 0 ? { ...exit, breakAfter: 120 } : exit)) }, plan)).toBe(false)
    const reverted = revertedToOriginal({ ...changed, title: 'Моё' }, plan)
    expect(differs(reverted, plan)).toBe(false)
    expect(reverted.title).toBe('Моё')
  })
})

describe('dragging an edge', () => {
  it('snaps to 5 s with the Mac limits', () => {
    expect(Timeline.resized(60, 31, 1, 'exit')).toBe(90)
    expect(Timeline.resized(60, 33, 1, 'exit')).toBe(95)
    expect(Timeline.resized(60, -200, 1, 'exit')).toBe(5)
    expect(Timeline.resized(0, -20, 1, 'exit')).toBe(0)
    expect(Timeline.resized(0, 12, 2, 'exit')).toBe(5)
    expect(Timeline.resized(120, -500, 1, 'pause')).toBe(30)
    expect(Timeline.resized(20, -500, 1, 'pause')).toBe(20)
    expect(Timeline.resized(3500, 900, 1, 'exit')).toBe(3600)
    expect(Timeline.nudged(60, 1, 'exit')).toBe(65)
    expect(Timeline.nudged(5, -1, 'exit')).toBe(5)
    expect(Timeline.nudged(30, -1, 'pause')).toBe(30)
  })

  it('turns a changed break into the exit’s own break, and back when it returns to the common one', () => {
    const plan = PlanParser.parse(text)
    const own = withBlockValue(plan, plan, { index: 0, kind: 'pause' }, 180)
    expect(own.exits[0].breakAfter).toBe(180)
    const back = withBlockValue(own, plan, { index: 0, kind: 'pause' }, 120)
    expect(back.exits[0].breakAfter).toBeNull()
    // The trainer's own break stays own even at the common length.
    const second = withBlockValue(plan, plan, { index: 1, kind: 'pause' }, 120)
    expect(second.exits[1].breakAfter).toBe(120)
    expect(blockValue(second, { index: 1, kind: 'pause' })).toBe(120)
    // Exits added by hand have no trainer's value: back at the common break is common.
    const manual = withBlockValue(plan, null, { index: 1, kind: 'pause' }, 120)
    expect(manual.exits[1].breakAfter).toBeNull()
    expect(withBlockValue(plan, plan, { index: 9, kind: 'exit' }, 10)).toBe(plan)
  })
})

describe('scale and zoom', () => {
  it('fits the longer of the two plans at 100 %', () => {
    const plan = PlanParser.parse(text)
    const total = TrainingPlan.estimatedDuration(plan)
    expect(Timeline.fitSpan(plan, null)).toBe(total)
    const longer = withBlockValue(plan, plan, { index: 0, kind: 'exit' }, 100)
    expect(Timeline.fitSpan(plan, longer)).toBe(total + 90)
    expect(Timeline.fitSpan({ ...plan, exits: plan.exits.slice(0, 1) }, null)).toBe(60)
    const width = 1000
    const pps = Timeline.pointsPerSecond(width, total, 1)
    expect(Timeline.contentWidth(width, total, total, pps)).toBeCloseTo(width)
    expect(Timeline.pointsPerSecond(width, total, 2)).toBeCloseTo(pps * 2)
    // Tiny widths keep a usable scale.
    expect(Timeline.pointsPerSecond(10, 120, 1)).toBe(1)
  })

  it('picks ruler steps at least ~64 px apart', () => {
    expect(Timeline.labelStep(0.6)).toBe(120)
    expect(Timeline.minorStep(0.6, 120)).toBe(30)
    expect(Timeline.labelStep(7)).toBe(10)
    expect(Timeline.minorStep(7, 10)).toBe(5)
    expect(Timeline.labelStep(0.01)).toBe(900)
    const ticks = Timeline.ticks(1, 400)
    expect(ticks[0]).toEqual({ time: 0, x: Timeline.inset, major: true })
    expect(ticks.filter((tick) => tick.major).map((tick) => tick.time)).toEqual([0, 120, 240, 360])
    expect(ticks.every((tick) => tick.x <= 400)).toBe(true)
  })

  it('steps zoom and keeps the moment under the pointer in place', () => {
    expect(Timeline.steppedZoom(1, 1)).toBe(1.5)
    expect(Timeline.steppedZoom(1.65, 1)).toBe(2)
    expect(Timeline.steppedZoom(1.65, -1)).toBe(1.5)
    expect(Timeline.steppedZoom(1, -1)).toBe(1)
    expect(Timeline.steppedZoom(12, 1)).toBe(12)
    expect(Timeline.clampZoom(40)).toBe(12)
    expect(Timeline.clampZoom(0.2)).toBe(1)

    const viewport = 1000
    const span = 1800
    const before = Timeline.pointsPerSecond(viewport, span, 2)
    const offset = 300
    const anchor = 420
    const time = Timeline.timeAt(offset, anchor, before)
    const after = Timeline.pointsPerSecond(viewport, span, 3)
    const content = Timeline.contentWidth(viewport, span, span, after)
    const next = Timeline.anchoredOffset(time, anchor, after, content, viewport)
    expect(Timeline.timeAt(next, anchor, after)).toBeCloseTo(time)
    // Never past either end.
    expect(Timeline.anchoredOffset(0, 500, after, content, viewport)).toBe(0)
    expect(Timeline.anchoredOffset(span, 0, after, content, viewport)).toBe(content - viewport)
  })
})
