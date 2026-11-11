import { useEffect, useRef, useState, type ReactNode } from 'react'
import { t } from '@shared/i18n'
import { go2rtcModes, type PlayerMode } from '@shared/settings'
import { createPlayer, type PlayerPhase, type WaitingPawsPlayer } from './CameraPlayer'
import { VideoOffIcon } from '../ui/icons'

export interface CameraViewProps {
  /// go2rtc base URL ("http://127.0.0.1:11984/").
  baseURL: string
  stream: string
  mode: PlayerMode
  muted: boolean
  /// Crop to fill instead of showing the whole frame.
  fill?: boolean
  /// Bump to reconnect.
  reloadToken?: number
  /// Off where the caller shows its own status (the settings preview).
  showStatus?: boolean
  zoomable?: boolean
  onVideoSize?: (width: number, height: number) => void
  onDelay?: (buffer: number, network: number | null) => void
  /// What the player is doing (connecting, playing, failed…), for callers with their own status line.
  onPhase?: (phase: PlayerPhase) => void
  children?: ReactNode
}

function socketURL(baseURL: string, stream: string): string {
  const url = new URL('api/ws', baseURL)
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  url.searchParams.set('src', stream)
  return url.href
}

/// Live view of a go2rtc stream with what is going on over it while there is no picture yet (or it froze), instead
/// of a black screen. Wheel or Ctrl+wheel zooms around the cursor, dragging pans, double-click resets.
export function CameraView({ baseURL, stream, mode, muted, fill = false, reloadToken = 0, showStatus = true, zoomable = false, onVideoSize, onDelay, onPhase, children }: CameraViewProps) {
  const host = useRef<HTMLDivElement>(null)
  const player = useRef<WaitingPawsPlayer | null>(null)
  const [phase, setPhase] = useState<PlayerPhase>({ kind: 'connecting' })
  const callbacks = useRef({ onVideoSize, onDelay, onPhase })
  callbacks.current = { onVideoSize, onDelay, onPhase }
  const zoom = useZoom(host, zoomable)

  // One player per server/stream/mode/reload: changing any of them reconnects.
  useEffect(() => {
    const element = createPlayer()
    element.muted = muted
    element.fit = fill ? 'cover' : 'contain'
    element.events = {
      phase: (next) => {
        setPhase(next)
        callbacks.current.onPhase?.(next)
      },
      delay: (buffer, network) => callbacks.current.onDelay?.(buffer, network),
      videoSize: (width, height) => callbacks.current.onVideoSize?.(width, height),
      log: (text) => window.wp.log(`[player] ${new Date().toLocaleTimeString('en-GB', { hour12: false })} ${text}`),
    }
    element.mode = go2rtcModes(mode)
    element.background = true
    element.style.display = 'block'
    element.style.width = '100%'
    element.style.height = '100%'
    setPhase({ kind: 'connecting' })
    host.current?.appendChild(element)
    element.src = socketURL(baseURL, stream)
    player.current = element
    return () => {
      element.dispose()
      element.remove()
      player.current = null
    }
    // `muted` is applied below without a reconnect.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [baseURL, stream, mode, fill, reloadToken])

  useEffect(() => {
    player.current?.setMuted(muted)
  }, [muted])

  return (
    <div className="camera">
      <div className="camera__video" ref={host} style={zoom.style} onDoubleClick={zoom.reset} />
      {showStatus && <CameraStatusOverlay phase={phase} />}
      {zoom.scale > 1.01 && (
        <button className="camera__zoom-badge" onClick={zoom.reset}>
          {Math.round(zoom.scale * 100)}% · {t('Reset')}
        </button>
      )}
      {children}
    </div>
  )
}

/// Spinner and a line of text while the camera connects, a pill over a frozen picture, the reason when go2rtc
/// cannot reach the camera.
export function CameraStatusOverlay({ phase }: { phase: PlayerPhase }) {
  const [slow, setSlow] = useState(false)
  useEffect(() => {
    setSlow(false)
    if (phase.kind !== 'connecting') return
    const timer = window.setTimeout(() => setSlow(true), 10_000)
    return () => window.clearTimeout(timer)
  }, [phase.kind])

  if (phase.kind === 'playing') return null
  if (phase.kind === 'stalled') {
    return (
      <div className="camera__pill">
        <span className="spinner" />
        {t('No new frames — waiting for the camera')}
      </div>
    )
  }
  const failed = phase.kind === 'failed'
  return (
    <div className="camera__status">
      {failed ? <VideoOffIcon style={{ width: 32, height: 32, opacity: 0.7 }} /> : <span className="spinner spinner--lg" />}
      <div className="camera__status-title">{failed ? t('The camera doesn’t respond') : phase.kind === 'connecting' ? t('Connecting to the camera…') : t('Camera connected, waiting for the first frame…')}</div>
      {failed && <div className="camera__status-detail">{t('%@. Trying again…', capitalize(t(phase.reason)))}</div>}
      {failed && window.wp.platform === 'win32' && /udp.*timeout/i.test(phase.raw) && (
        <div className="camera__status-hint">
          {t("The camera doesn't answer over UDP — this happens when Windows Firewall blocks go2rtc. Allow Waiting Paws on private networks.")}
          <button className="btn btn--sm" onClick={() => void window.wp.call('shell.openFirewall')}>
            {t('Open Firewall Settings')}
          </button>
        </div>
      )}
      {!failed && slow && <div className="camera__status-detail">{t('Taking longer than usual: the camera may be offline or busy with another app.')}</div>}
    </div>
  )
}

function capitalize(text: string): string {
  return text ? text[0].toUpperCase() + text.slice(1) : text
}

/// Placeholder shown when no camera is configured.
export function CameraPlaceholder({ text, children }: { text: string; children?: ReactNode }) {
  return (
    <div className="camera camera--placeholder">
      <VideoOffIcon style={{ width: 36, height: 36 }} />
      <div>{text}</div>
      {children}
    </div>
  )
}

/// Zoom and pan of the picture: wheel zooms around the cursor, drag pans while zoomed, double-click resets.
function useZoom(ref: React.RefObject<HTMLDivElement | null>, enabled: boolean) {
  const [state, setState] = useState({ scale: 1, x: 0, y: 0 })
  useEffect(() => {
    const element = ref.current?.parentElement
    if (!element || !enabled) return
    const onWheel = (event: WheelEvent) => {
      event.preventDefault()
      const rect = element.getBoundingClientRect()
      const cx = event.clientX - rect.left - rect.width / 2
      const cy = event.clientY - rect.top - rect.height / 2
      setState((current) => {
        const factor = Math.exp(-event.deltaY * (event.ctrlKey ? 0.01 : 0.0015))
        const scale = Math.min(6, Math.max(1, current.scale * factor))
        const k = scale / current.scale
        const x = scale === 1 ? 0 : cx - (cx - current.x) * k
        const y = scale === 1 ? 0 : cy - (cy - current.y) * k
        return clamp({ scale, x, y }, rect)
      })
    }
    let drag: { x: number; y: number; startX: number; startY: number } | null = null
    const onDown = (event: PointerEvent) => {
      if (event.button !== 0) return
      setState((current) => {
        if (current.scale > 1) {
          drag = { x: event.clientX, y: event.clientY, startX: current.x, startY: current.y }
          element.setPointerCapture(event.pointerId)
        }
        return current
      })
    }
    const onMove = (event: PointerEvent) => {
      if (!drag) return
      const start = drag
      const rect = element.getBoundingClientRect()
      setState((current) => clamp({ scale: current.scale, x: start.startX + event.clientX - start.x, y: start.startY + event.clientY - start.y }, rect))
    }
    const onUp = () => {
      drag = null
    }
    element.addEventListener('wheel', onWheel, { passive: false })
    element.addEventListener('pointerdown', onDown)
    element.addEventListener('pointermove', onMove)
    element.addEventListener('pointerup', onUp)
    element.addEventListener('pointercancel', onUp)
    return () => {
      element.removeEventListener('wheel', onWheel)
      element.removeEventListener('pointerdown', onDown)
      element.removeEventListener('pointermove', onMove)
      element.removeEventListener('pointerup', onUp)
      element.removeEventListener('pointercancel', onUp)
    }
  }, [ref, enabled])

  return {
    scale: state.scale,
    style: state.scale > 1 ? { transform: `translate(${state.x}px, ${state.y}px) scale(${state.scale})`, cursor: 'grab' } : undefined,
    reset: () => setState({ scale: 1, x: 0, y: 0 }),
  }
}

function clamp(state: { scale: number; x: number; y: number }, rect: DOMRect) {
  const maxX = ((state.scale - 1) * rect.width) / 2
  const maxY = ((state.scale - 1) * rect.height) / 2
  return { scale: state.scale, x: Math.max(-maxX, Math.min(maxX, state.x)), y: Math.max(-maxY, Math.min(maxY, state.y)) }
}
