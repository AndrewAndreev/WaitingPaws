import { useRef, useState } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { ui, useApp, useNow } from '../store'
import { StopFilledIcon } from '../ui/icons'
import { Button, Tooltip } from '../ui/kit'

type Position = 'top-left' | 'top' | 'top-right' | 'bottom-left' | 'bottom' | 'bottom-right'
const POSITION_KEY = 'wp.clipHUDPosition'
const MARGIN = 24

function savedPosition(): Position {
  try {
    return (localStorage.getItem(POSITION_KEY) as Position | null) ?? 'bottom'
  } catch {
    return 'bottom'
  }
}

/// Recording without a training: the clock and «Остановить» on a panel floating over the picture. Drag it anywhere;
/// it settles in the nearest corner or edge middle and stays there next time.
export function ClipRecordingHUD() {
  const app = useApp()
  const now = useNow(1000)
  const [position, setPosition] = useState<Position>(savedPosition)
  const [drag, setDrag] = useState<{ dx: number; dy: number } | null>(null)
  const start = useRef<{ x: number; y: number } | null>(null)
  const panel = useRef<HTMLDivElement>(null)
  const since = app.recording.since

  const onPointerDown = (event: React.PointerEvent) => {
    if ((event.target as HTMLElement).closest('button')) return
    start.current = { x: event.clientX, y: event.clientY }
    ;(event.currentTarget as HTMLElement).setPointerCapture(event.pointerId)
  }
  const onPointerMove = (event: React.PointerEvent) => {
    if (!start.current) return
    setDrag({ dx: event.clientX - start.current.x, dy: event.clientY - start.current.y })
  }
  const onPointerUp = () => {
    const element = panel.current
    const area = element?.parentElement?.parentElement
    if (start.current && drag && element && area) {
      const box = area.getBoundingClientRect()
      const rect = element.getBoundingClientRect()
      const cx = rect.left + rect.width / 2 - box.left
      const cy = rect.top + rect.height / 2 - box.top
      const column = cx < box.width / 3 ? 'left' : cx > (box.width * 2) / 3 ? 'right' : ''
      const row = cy < box.height / 2 ? 'top' : 'bottom'
      const next = (column ? `${row}-${column}` : row) as Position
      setPosition(next)
      try {
        localStorage.setItem(POSITION_KEY, next)
      } catch {
        // Remembering the corner is a nicety.
      }
    }
    start.current = null
    setDrag(null)
  }

  return (
    <div className={`clip-hud-area clip-hud-area--${position}`} style={{ padding: MARGIN }}>
      <Tooltip content={t('Drag the panel to any corner')}>
        <div
          ref={panel}
          className="clip-hud"
          style={drag ? { transform: `translate(${drag.dx}px, ${drag.dy}px)`, transition: 'none' } : undefined}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
        >
          <span className="dot dot--rec" style={{ width: 12, height: 12 }} />
          <span className="clip-hud__time tabular">{since ? DurationText.clock((now - since) / 1000) : '0:00'}</span>
          <div className="clip-hud__text">
            <strong>{t('Recording without training')}</strong>
            <span>{app.recording.resuming ? t("The camera dropped out — recording resumes when it's back") : t('The video will appear in History')}</span>
          </div>
          <Button variant="danger-solid" size="lg" icon={<StopFilledIcon />} shortcut="Ctrl+R" onClick={() => ui.set({ confirmStopRecording: true })}>
            {t('Stop')}
          </Button>
        </div>
      </Tooltip>
    </div>
  )
}
