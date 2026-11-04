import { useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type PointerEvent as ReactPointerEvent } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { TrainingPlan } from '@core/models'
import { isConfigured } from '../model'
import { ui, useApp } from '../store'
import { BreakFilledIcon, FinishLineIcon, ResizeIcon, RevertIcon, StandIcon, ZoomInIcon, ZoomOutIcon } from '../ui/icons'
import { Button, ContextMenu, ContextMenuContent, ContextMenuItem, ContextMenuTrigger, Tooltip } from '../ui/kit'
import { PlanFormat, updateExit } from '../plan/planEdit'
import {
  Timeline,
  blockChanged,
  blockEnd,
  blockHelp,
  blockValue,
  differs,
  edgeKey,
  planBlocks,
  revertedToOriginal,
  sameEdge,
  withBlockValue,
  type BlockEdge,
  type PlanBlock,
} from '../plan/timelineGeometry'
import { usePendingPlan } from '../plan/usePendingPlan'
import '../styles/plan.css'

/// The waiting plan on the timeline under the camera (port of `MacPlanTimelineEditor`). Drawn like the live
/// «план и факт» timeline: pink exits, blue breaks, a ruler with time from the start, «Факт» and «Запись» lanes under
/// the plan. Edited with the mouse: drag the right edge of an exit or a break (5 s steps, everything after it moves,
/// a changed break becomes the exit's own break); right click for «Как у тренера», «Как у всех».
/// Zoom with Ctrl+wheel (or a touchpad pinch), Ctrl+−/Ctrl+=/Ctrl+0 or the buttons; scroll sideways with the wheel
/// when zoomed in, or click/drag the overview strip.

interface EdgeDrag {
  edge: BlockEdge
  startValue: number
  /// Axis span and scale frozen for the drag, so the edge stays under the pointer while the plan grows.
  span: number
  pps: number
}

const TITLE_WIDTH = 86

function laneLayout(height: number) {
  const compact = height < 150
  const planTop = 30
  const planHeight = compact ? 40 : 46
  const laneGap = compact ? 8 : 10
  const factHeight = compact ? 18 : 22
  const recordHeight = compact ? 12 : 14
  const factTop = planTop + planHeight + laneGap
  const recordTop = factTop + factHeight + laneGap
  return { planTop, planHeight, factTop, factHeight, recordTop, recordHeight }
}

export function PlanTimelineEditor() {
  const app = useApp()
  const { plan, original, setPlan } = usePendingPlan()
  const [zoom, setZoom] = useState(1)
  const [drag, setDrag] = useState<EdgeDrag | null>(null)
  const [keyboardEdge, setKeyboardEdge] = useState<BlockEdge | null>(null)
  const [hovered, setHovered] = useState<string | null>(null)
  const [size, setSize] = useState({ width: 0, height: 0 })
  const [offset, setOffset] = useState(0)
  const scrollRef = useRef<HTMLDivElement>(null)
  const pendingScroll = useRef<number | null>(null)

  const total = plan ? TrainingPlan.estimatedDuration(plan) : 0
  const span = drag?.span ?? (plan ? Timeline.fitSpan(plan, original) : 60)
  const viewport = size.width
  const pps = drag?.pps ?? Timeline.pointsPerSecond(viewport, span, zoom)
  const full = Timeline.contentWidth(viewport, span, total, pps)

  // The latest values for listeners (wheel, keys) that outlive a render.
  const latest = useRef({ zoom, offset, viewport, span, total, dragging: false })
  latest.current = { zoom, offset, viewport, span, total, dragging: drag !== null }

  useLayoutEffect(() => {
    const element = scrollRef.current
    if (!element) return
    const observer = new ResizeObserver(() => setSize({ width: element.clientWidth, height: element.clientHeight }))
    observer.observe(element)
    setSize({ width: element.clientWidth, height: element.clientHeight })
    return () => observer.disconnect()
  }, [plan === null || plan.exits.length === 0])

  /// Changes the zoom keeping the moment under `anchor` (x in the visible area) where it was.
  const applyZoom = (value: number, anchor?: number) => {
    const state = latest.current
    if (state.viewport <= 0 || state.dragging) return
    const next = Timeline.clampZoom(value)
    const at = anchor ?? state.viewport / 2
    const time = Timeline.timeAt(state.offset, at, Timeline.pointsPerSecond(state.viewport, state.span, state.zoom))
    const nextPps = Timeline.pointsPerSecond(state.viewport, state.span, next)
    const x = Timeline.anchoredOffset(time, at, nextPps, Timeline.contentWidth(state.viewport, state.span, state.total, nextPps), state.viewport)
    latest.current = { ...state, zoom: next, offset: x }
    pendingScroll.current = x
    setZoom(next)
    setOffset(x)
  }
  const applyZoomRef = useRef(applyZoom)
  applyZoomRef.current = applyZoom

  useLayoutEffect(() => {
    if (pendingScroll.current === null || !scrollRef.current) return
    scrollRef.current.scrollLeft = pendingScroll.current
    pendingScroll.current = null
  }, [zoom])

  // Ctrl+wheel (and a touchpad pinch, which Chromium reports as one) zooms around the pointer; the plain wheel
  // scrolls sideways when zoomed in.
  useEffect(() => {
    const element = scrollRef.current
    if (!element) return
    const onWheel = (event: WheelEvent) => {
      if (event.ctrlKey) {
        event.preventDefault()
        const box = element.getBoundingClientRect()
        const delta = event.deltaMode === 1 ? event.deltaY * 16 : event.deltaY
        applyZoomRef.current(latest.current.zoom * Math.exp(-delta * 0.0025), event.clientX - box.left)
      } else if (Math.abs(event.deltaY) > Math.abs(event.deltaX) && element.scrollWidth > element.clientWidth + 1) {
        event.preventDefault()
        element.scrollLeft += event.deltaMode === 1 ? event.deltaY * 16 : event.deltaY
      }
    }
    element.addEventListener('wheel', onWheel, { passive: false })
    return () => element.removeEventListener('wheel', onWheel)
  }, [plan === null || plan.exits.length === 0])

  // Ctrl+− / Ctrl+= / Ctrl+0 on the training page (not in text fields or over a dialog).
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!(event.ctrlKey || event.metaKey) || event.shiftKey || event.altKey) return
      const target = event.target as HTMLElement | null
      if (target && (target.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName))) return
      if (document.querySelector('[role="dialog"]') || ui.get().route !== 'training') return
      const state = latest.current
      if (event.key === '-' || event.key === '_') {
        event.preventDefault()
        applyZoomRef.current(Timeline.steppedZoom(state.zoom, -1))
      } else if (event.key === '=' || event.key === '+') {
        event.preventDefault()
        applyZoomRef.current(Timeline.steppedZoom(state.zoom, 1))
      } else if (event.key === '0') {
        event.preventDefault()
        applyZoomRef.current(1)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  if (!plan) return null
  const blocks = planBlocks(plan, original)
  const lanes = laneLayout(size.height)
  const zoomed = zoom > 1.001
  const changed = original !== null && differs(plan, original)
  const configured = isConfigured(app.settings)
  const recording = configured && app.settings.autoRecord
  const active = drag?.edge ?? keyboardEdge
  const activeBlock = active ? blocks.find((block) => sameEdge(block.edge, active)) ?? null : null
  // Captions in the empty lanes stay at the visible left edge while scrolling.
  const sticky = Math.min(Math.max(0, offset - Timeline.inset), Math.max(0, total * pps - 210))

  const startResize = (event: ReactPointerEvent, block: PlanBlock) => {
    if (event.button !== 0) return
    event.preventDefault()
    event.stopPropagation()
    setKeyboardEdge(null)
    const frozen: EdgeDrag = { edge: block.edge, startValue: block.duration, span, pps }
    const startX = event.clientX
    setDrag(frozen)
    document.body.classList.add('is-resizing-columns')
    const move = (moveEvent: PointerEvent) => {
      // By the second; with Shift the 5 s grid (as on the live timeline).
      const value = Timeline.resized(frozen.startValue, moveEvent.clientX - startX, frozen.pps, frozen.edge.kind, moveEvent.shiftKey ? Timeline.snap : 1)
      setPlan((current) => (blockValue(current, frozen.edge) === value ? current : withBlockValue(current, original, frozen.edge, value)))
    }
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      window.removeEventListener('pointercancel', up)
      document.body.classList.remove('is-resizing-columns')
      setDrag(null)
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
    window.addEventListener('pointercancel', up)
  }

  const nudge = (event: ReactKeyboardEvent, block: PlanBlock) => {
    const direction = event.key === 'ArrowRight' || event.key === 'ArrowUp' ? 1 : event.key === 'ArrowLeft' || event.key === 'ArrowDown' ? -1 : 0
    if (!direction) return
    event.preventDefault()
    event.stopPropagation()
    setKeyboardEdge(block.edge)
    setPlan((current) => withBlockValue(current, original, block.edge, Timeline.nudged(blockValue(current, block.edge), direction, block.edge.kind)))
  }

  const scrollTo = (x: number) => {
    const element = scrollRef.current
    if (!element) return
    element.scrollLeft = Math.min(Math.max(0, x), Math.max(0, element.scrollWidth - element.clientWidth))
  }

  return (
    <div className="timeline pte">
      <div className={'timeline__header pte__header' + (changed ? ' pte__header--changed' : '')}>
        <span className="h3">{t('План')}</span>
        <span className="muted tabular pte__total">
          {PlanFormat.exits(plan.exits.length)} · {PlanFormat.approx(total)}
        </span>
        {original && changed && (
          <>
            <span className="badge badge--accent tabular">
              {total === TrainingPlan.estimatedDuration(original) ? t('изменён') : t('%@ к плану тренера', PlanFormat.signed(total - TrainingPlan.estimatedDuration(original)))}
            </span>
            <Tooltip content={t('Вернуть выходы и перерывы из текста тренера: %@', PlanFormat.approx(TrainingPlan.estimatedDuration(original)))}>
              <Button size="sm" icon={<RevertIcon />} onClick={() => setPlan((current) => revertedToOriginal(current, original))}>
                {t('Как у тренера')}
              </Button>
            </Tooltip>
          </>
        )}
        <span className="spacer" />
        {plan.exits.length > 0 && (
          <>
            <span className="pte__hint pte__hint--long">
              <ResizeIcon />
              {t('Тяните край блока, чтобы изменить длительность')}
            </span>
            <span className="pte__hint pte__hint--short">
              <ResizeIcon />
              {t('Тяните край блока')}
            </span>
            <span className="pte__sep" />
            <span className="faint tabular pte__zoom">{Math.round(zoom * 100)}%</span>
            <div className="row" style={{ gap: 2 }}>
              <Tooltip content={t('Уменьшить (Ctrl+−, Ctrl+колесо мыши)')}>
                <Button variant="subtle" size="sm" iconOnly className="pte__zoom-button" icon={<ZoomOutIcon />} aria-label={t('Уменьшить')} disabled={!zoomed} onClick={() => applyZoom(Timeline.steppedZoom(zoom, -1))} />
              </Tooltip>
              <Tooltip content={t('Увеличить (Ctrl+=, Ctrl+колесо мыши)')}>
                <Button variant="subtle" size="sm" iconOnly className="pte__zoom-button" icon={<ZoomInIcon />} aria-label={t('Увеличить')} disabled={zoom >= Timeline.maxZoom - 0.001} onClick={() => applyZoom(Timeline.steppedZoom(zoom, 1))} />
              </Tooltip>
            </div>
            <Tooltip content={t('Вся тренировка по ширине') + ' (Ctrl+0)'}>
              <Button size="sm" disabled={!zoomed} onClick={() => applyZoom(1)}>
                {t('По ширине')}
              </Button>
            </Tooltip>
          </>
        )}
      </div>
      {plan.exits.length === 0 ? (
        <div className="empty-state" style={{ flex: 1 }}>
          {t('В расписании нет выходов')}
        </div>
      ) : (
        <div className="pte__body">
          <div className="pte__titles" style={{ width: TITLE_WIDTH }}>
            <span className="pte__title" style={{ top: lanes.planTop, height: lanes.planHeight }}>
              {t('План')}
            </span>
            <span className="pte__title" style={{ top: lanes.factTop, height: lanes.factHeight }}>
              {t('Факт')}
            </span>
            <span className="pte__title" style={{ top: lanes.recordTop, height: lanes.recordHeight }}>
              {t('Запись')}
            </span>
          </div>
          <div className="pte__main">
            <div className={'pte__scroll' + (zoomed ? '' : ' pte__scroll--fit')} ref={scrollRef} onScroll={(event) => setOffset(event.currentTarget.scrollLeft)}>
              {viewport > 0 && (
                <div className={'pte__content' + (drag ? ' is-dragging' : '')} style={{ width: full }}>
                  <Ruler pps={pps} total={total} width={full} height={size.height} lanes={lanes} />
                  {blocks.map((block) => (
                    <Block
                      key={edgeKey(block.edge)}
                      block={block}
                      pps={pps}
                      top={lanes.planTop}
                      height={lanes.planHeight}
                      active={sameEdge(active, block.edge)}
                      lit={sameEdge(active, block.edge) || (!drag && hovered === edgeKey(block.edge))}
                      help={drag ? null : blockHelp(block)}
                      plan={plan}
                      onRevert={(value) => setPlan((current) => withBlockValue(current, original, block.edge, value))}
                      onCommonBreak={() => setPlan((current) => updateExit(current, current.exits[block.edge.index].id, { breakAfter: null }))}
                    />
                  ))}
                  <div className="pte-lane pte-lane--fact" style={{ left: Timeline.inset, top: lanes.factTop, width: Math.max(2, total * pps), height: lanes.factHeight }}>
                    <span className="pte-lane__text" style={{ transform: `translateX(${sticky}px)` }}>
                      {t('появится после старта')}
                    </span>
                  </div>
                  <div
                    className={'pte-lane' + (recording ? ' pte-lane--rec' : ' pte-lane--fact')}
                    style={{ left: Timeline.inset, top: lanes.recordTop, width: Math.max(2, total * pps), height: lanes.recordHeight }}
                  >
                    {configured && (
                      <span className="pte-lane__text pte-lane__text--small" style={{ transform: `translateX(${sticky}px)` }}>
                        {recording ? t('REC · начнётся со стартом') : t('без записи — включите «Записывать видео»')}
                      </span>
                    )}
                  </div>
                  {blocks.map((block) => (
                    <div
                      key={edgeKey(block.edge)}
                      className={'pte-handle' + (sameEdge(active, block.edge) ? ' is-active' : '')}
                      style={{ left: Timeline.inset + blockEnd(block) * pps - 7, top: lanes.planTop, height: lanes.planHeight }}
                      role="slider"
                      tabIndex={0}
                      aria-label={blockHelp(block)}
                      aria-valuenow={block.duration}
                      aria-valuemin={0}
                      aria-valuemax={Timeline.maxDuration}
                      aria-valuetext={DurationText.short(block.duration)}
                      onPointerDown={(event) => startResize(event, block)}
                      onPointerEnter={() => setHovered(edgeKey(block.edge))}
                      onPointerLeave={() => setHovered((current) => (current === edgeKey(block.edge) ? null : current))}
                      onKeyDown={(event) => nudge(event, block)}
                      onBlur={() => setKeyboardEdge(null)}
                    >
                      <span className="pte-handle__grip">
                        <i />
                        <i />
                        <i />
                      </span>
                    </div>
                  ))}
                  {activeBlock && <EditGuide block={activeBlock} pps={pps} full={full} lanes={lanes} reference={activeBlock.original ?? (drag && sameEdge(drag.edge, activeBlock.edge) ? drag.startValue : null)} />}
                </div>
              )}
            </div>
            <div className="pte__footer">
              {zoomed && viewport > 0 ? (
                <Overview blocks={blocks} pps={pps} full={full} offset={offset} viewport={viewport} onScroll={scrollTo} />
              ) : (
                <div className="pte__legend">
                  <span className="legend">
                    <span className="legend__swatch pte-swatch--exit" />
                    {t('выход')}
                  </span>
                  <span className="legend">
                    <span className="legend__swatch pte-swatch--break" />
                    {t('перерыв')}
                  </span>
                  <span className="legend">
                    <span className="legend__swatch pte-swatch--own" />
                    {t('свой перерыв')}
                  </span>
                  {original && (
                    <span className="legend">
                      <span className="pte-swatch--changed" />
                      {t('изменено относительно тренера')}
                    </span>
                  )}
                </div>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

type Lanes = ReturnType<typeof laneLayout>

/// Ruler with time from the start (the clock time is unknown until then), grid lines and the finish flag.
function Ruler({ pps, total, width, height, lanes }: { pps: number; total: number; width: number; height: number; lanes: Lanes }) {
  const ticks = Timeline.ticks(pps, width)
  const end = Timeline.inset + total * pps
  let minor = ''
  let major = ''
  let grid = ''
  for (const tick of ticks) {
    const x = Math.round(tick.x) + 0.5
    if (tick.major) {
      major += `M${x} 14V24`
      grid += `M${x} 26V${height}`
    } else {
      minor += `M${x} 19V24`
    }
  }
  return (
    <>
      <svg className="pte-ruler" width={width} height={height} aria-hidden>
        <path d={grid} className="pte-ruler__grid" />
        <path d={minor} className="pte-ruler__minor" />
        <path d={major} className="pte-ruler__major" />
        <path d={`M${end} 2V${lanes.recordTop + lanes.recordHeight}`} className="pte-ruler__finish" />
      </svg>
      {ticks
        .filter((tick) => tick.major && (tick.x < end - 46 || tick.x > end + 64))
        .map((tick) => (
          <span key={tick.time} className="pte-ruler__label tabular" style={{ left: tick.x + 3 }}>
            {tick.time === 0 ? t('старт') : '+' + DurationText.clock(tick.time)}
          </span>
        ))}
      <span className="pte-ruler__end tabular" style={{ left: end + 4 }}>
        <FinishLineIcon />
        {DurationText.clock(total)}
      </span>
    </>
  )
}

function Block({
  block,
  pps,
  top,
  height,
  active,
  lit,
  help,
  plan,
  onRevert,
  onCommonBreak,
}: {
  block: PlanBlock
  pps: number
  top: number
  height: number
  active: boolean
  lit: boolean
  /// Hidden while an edge is dragged (the guide shows the value).
  help: string | null
  plan: TrainingPlan
  onRevert: (value: number) => void
  onCommonBreak: () => void
}) {
  const width = Math.max(2, block.duration * pps - 1)
  const exit = block.edge.kind === 'exit'
  const changed = blockChanged(block)
  const className = 'pte-block ' + (exit ? 'pte-block--exit' : block.own ? 'pte-block--pause pte-block--own' : 'pte-block--pause') + (active ? ' is-active' : '') + (lit ? ' is-lit' : '')
  const hasMenu = (changed && block.original !== null) || (!exit && block.own)
  const element = (
    <div className={className} style={{ left: Timeline.inset + block.start * pps, top, width, height }}>
      {exit ? (
        <span className="pte-block__exit tabular" style={{ opacity: width >= 11 ? 1 : 0 }}>
          <span className="pte-block__number">
            {block.number}
            {block.untilStanding && width >= 46 && <StandIcon />}
          </span>
          {width >= 34 && <span className="pte-block__time">{DurationText.clock(block.duration)}</span>}
        </span>
      ) : (
        <span className="pte-block__pause tabular" style={{ opacity: width >= 48 ? 1 : 0 }}>
          <BreakFilledIcon />
          {PlanFormat.cell(block.duration)}
          {block.own && width >= 96 && <span className="pte-block__own">{t(' · свой')}</span>}
        </span>
      )}
      {changed && width > 18 && <span className="pte-block__dot" />}
    </div>
  )
  if (!hasMenu) {
    return (
      <Tooltip content={help} side="top">
        {element}
      </Tooltip>
    )
  }
  return (
    <ContextMenu>
      <Tooltip content={help} side="top">
        <ContextMenuTrigger asChild>{element}</ContextMenuTrigger>
      </Tooltip>
      <ContextMenuContent>
        {changed && block.original !== null && (
          <ContextMenuItem icon={<RevertIcon />} onSelect={() => onRevert(block.original!)}>
            {t('Как у тренера — %@', DurationText.short(block.original))}
          </ContextMenuItem>
        )}
        {!exit && block.own && <ContextMenuItem onSelect={onCommonBreak}>{t('Как у всех — %@', DurationText.short(plan.defaultBreak))}</ContextMenuItem>}
      </ContextMenuContent>
    </ContextMenu>
  )
}

/// Vertical guide through the lanes plus the live label «Выход 6 · 2:30 (+0:30)».
function EditGuide({ block, pps, full, lanes, reference }: { block: PlanBlock; pps: number; full: number; lanes: Lanes; reference: number | null }) {
  const x = Timeline.inset + blockEnd(block) * pps
  const name = block.edge.kind === 'exit' ? t('Выход %lld', block.number) : t('Перерыв после %lld', block.number)
  const delta = reference !== null ? block.duration - reference : 0
  return (
    <>
      <div className="pte-guide" style={{ left: x - 0.5, top: 24, height: lanes.recordTop + lanes.recordHeight + 4 - 24 }} />
      <div className="pte-tip tabular" style={{ left: Math.min(Math.max(x, 110), full - 110) }}>
        {name} · <b>{DurationText.clock(block.duration)}</b>
        {delta !== 0 && <span className="pte-tip__extra"> ({PlanFormat.signed(delta)})</span>}
        {block.edge.kind === 'pause' && block.own && <span className="pte-tip__extra">{t(' · свой')}</span>}
      </div>
    </>
  )
}

/// Zoomed in: the whole plan in miniature with the visible part framed (click or drag to scroll).
function Overview({ blocks, pps, full, offset, viewport, onScroll }: { blocks: PlanBlock[]; pps: number; full: number; offset: number; viewport: number; onScroll: (x: number) => void }) {
  const ref = useRef<HTMLDivElement>(null)
  const [width, setWidth] = useState(0)
  useLayoutEffect(() => {
    const element = ref.current
    if (!element) return
    const observer = new ResizeObserver(() => setWidth(element.clientWidth))
    observer.observe(element)
    setWidth(element.clientWidth)
    return () => observer.disconnect()
  }, [])
  const inset = Timeline.inset
  const extent = Math.max(1, (full - inset * 2) / pps)
  const scale = Math.max(1, width - inset * 2) / extent
  const from = Math.max(0, (offset - inset) / pps)
  const to = Math.min(extent, (offset + viewport - inset) / pps)
  const scrollAt = (clientX: number) => {
    const box = ref.current?.getBoundingClientRect()
    if (!box) return
    const time = (clientX - box.left - inset) / scale
    onScroll(inset + time * pps - viewport / 2)
  }
  return (
    <Tooltip content={t('Вся тренировка — щёлкните или тяните, чтобы прокрутить')} side="top">
      <div
        className="pte-overview"
        ref={ref}
        onPointerDown={(event) => {
          if (event.button !== 0) return
          event.preventDefault()
          scrollAt(event.clientX)
          const move = (moveEvent: PointerEvent) => scrollAt(moveEvent.clientX)
          const up = () => {
            window.removeEventListener('pointermove', move)
            window.removeEventListener('pointerup', up)
          }
          window.addEventListener('pointermove', move)
          window.addEventListener('pointerup', up)
        }}
      >
        {width > 0 &&
          blocks.map((block) => (
            <span
              key={edgeKey(block.edge)}
              className={'pte-overview__block ' + (block.edge.kind === 'exit' ? 'pte-overview__block--exit' : block.own ? 'pte-overview__block--own' : 'pte-overview__block--break')}
              style={{ left: inset + block.start * scale, width: Math.max(1, block.duration * scale - 0.5) }}
            />
          ))}
        {width > 0 && <span className="pte-overview__frame" style={{ left: inset + from * scale - 2, width: Math.max(12, (to - from) * scale + 4) }} />}
      </div>
    </Tooltip>
  )
}
