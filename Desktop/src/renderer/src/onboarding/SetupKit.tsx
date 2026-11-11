// Building blocks of the setup screens (welcome page, camera picker, Xiaomi sign-in, own server): which picker to
// open, the go2rtc status line, camera stills with their online state, the «Камеры Mi Home» sign-in card.
// Port of the Mac app's `SetupKit.swift` pieces, drawn the Windows way.
import type { ReactNode } from 'react'
import { create } from 'zustand'
import type { Go2RTCClient, XiaomiRegion } from '@core/go2rtcClient'
import { t } from '@shared/i18n'
import { call, ui, useStore } from '../store'
import { ServerIcon, SignInIcon, StreamIcon, VideoIcon, VideoOffIcon, WarningIcon } from '../ui/icons'
import { Button, Spinner, Tooltip } from '../ui/kit'
import { hostText, type CatalogPhase } from './catalog'
import { useStill, type StillSource, type StillState } from './stills'

// MARK: - Which dialog opens

interface PickerRequest {
  /// Only go2rtc streams (welcome page «Выбрать поток go2rtc…»).
  onlyStreams: boolean
  /// Only this Mi Home account (right after signing in to it).
  accountID: string | null
  /// The region that account was signed in with (the settings may not have caught up yet).
  region: XiaomiRegion | null
  /// Which camera the choice is for: the main one or the second (view-only) one.
  target: 'main' | 'second'
}

/// What the next camera picker shows. The dialogs themselves open through the UI store flags
/// (`showCameraPicker`, `showXiaomiSignIn`, `showServerSetup`): the welcome page hosts them before the setup,
/// GlobalDialogs after it.
export const usePickerRequest = create<PickerRequest>(() => ({ onlyStreams: false, accountID: null, region: null, target: 'main' }))

export function openCameraPicker(request: Partial<PickerRequest> = {}): void {
  usePickerRequest.setState({ onlyStreams: false, accountID: null, region: null, target: 'main', ...request })
  ui.set({ showCameraPicker: true, showXiaomiSignIn: false, showServerSetup: false })
}

export function closeCameraPicker(): void {
  ui.set({ showCameraPicker: false })
  usePickerRequest.setState({ onlyStreams: false, accountID: null, region: null, target: 'main' })
}

// MARK: - go2rtc status line

/// "● Встроенный go2rtc 1.9.14 работает" / "Запускаем…" / the error with «Попробовать снова».
export function ServerStatusLine({ probe, compact = false }: { probe?: { phase: CatalogPhase; serverVersion: string | null }; compact?: boolean }) {
  const app = useStore((store) => store.app)!
  const retry = (
    <Button variant="link" className="setup-status__action" onClick={() => void call('go2rtc.restart')}>
      {t('Try Again')}
    </Button>
  )
  let content: ReactNode
  if (app.settings.connectionMode === 'embedded') {
    switch (app.go2rtc.status) {
      case 'idle':
        content = (
          <>
            <span className="dot" />
            <span>{t('Built-in go2rtc is not running')}</span>
            <Button variant="link" className="setup-status__action" onClick={() => void call('go2rtc.restart')}>
              {t('Start')}
            </Button>
          </>
        )
        break
      case 'starting':
        content = (
          <>
            <Spinner />
            <span>{t('Starting built-in go2rtc…')}</span>
          </>
        )
        break
      case 'running': {
        const version = app.go2rtc.version ?? ''
        content = (
          <>
            <span className="dot dot--live" />
            <span>{compact ? `go2rtc ${version}` : t('Built-in go2rtc %@ is running', version)}</span>
          </>
        )
        break
      }
      case 'failed':
        content = (
          <>
            <WarningIcon className="setup-status__warning" />
            <Tooltip content={app.go2rtc.message}>
              <span className="ellipsis">{app.go2rtc.message}</span>
            </Tooltip>
            {retry}
          </>
        )
        break
      case 'unavailable':
        content = (
          <>
            <WarningIcon className="setup-status__warning" />
            <span>{t('This build has no built-in go2rtc — enter your own server')}</span>
          </>
        )
        break
    }
  } else {
    const host = app.server ? hostText(app.server.baseURL) : t('no address set')
    if (probe?.phase.kind === 'failed') {
      content = (
        <>
          <WarningIcon className="setup-status__warning" />
          <Tooltip content={probe.phase.message}>
            <span className="ellipsis">{t('%@ is not responding', host)}</span>
          </Tooltip>
        </>
      )
    } else if (probe?.serverVersion) {
      content = (
        <>
          <span className="dot dot--live" />
          <span className="ellipsis">{compact ? `go2rtc ${probe.serverVersion}` : t('Own go2rtc server %@ · %@', probe.serverVersion, host)}</span>
        </>
      )
    } else {
      content = (
        <>
          <ServerIcon className="setup-status__icon" />
          <span className="ellipsis">{t('Own go2rtc server · %@', host)}</span>
        </>
      )
    }
  }
  return <div className="setup-status">{content}</div>
}

// MARK: - Stills

/// A still (16:9) of a go2rtc stream or a Mi Home camera, or a quiet camera glyph while there is none.
export function CameraStill({
  client,
  source,
  ready,
  isCamera,
  className,
  children,
}: {
  client: Go2RTCClient | null
  source: StillSource | null
  ready: boolean
  isCamera: boolean
  className?: string
  children?: ReactNode
}) {
  const state = useStill(client, source, ready)
  const failed = state?.kind === 'failed'
  const image = state?.kind === 'loaded' ? state.image : null
  return (
    <div className={'still' + (failed ? ' still--failed' : '') + (className ? ' ' + className : '')}>
      {image ? (
        <img className="still__image" src={image} alt="" draggable={false} />
      ) : failed ? (
        <VideoOffIcon className="still__glyph" />
      ) : isCamera ? (
        <VideoIcon className="still__glyph" />
      ) : (
        <StreamIcon className="still__glyph" />
      )}
      {children}
    </div>
  )
}

/// Green when a picture came through, grey when it did not, a spinner while it loads.
export function StillDot({ state }: { state: StillState | undefined }) {
  if (!state) return <span className="still-dot-space" />
  if (state.kind === 'loading') return <Spinner />
  return (
    <Tooltip content={state.kind === 'loaded' ? t('The camera is responding') : t('No picture from the camera')}>
      <span className={'dot' + (state.kind === 'loaded' ? ' dot--live' : '')} />
    </Tooltip>
  )
}

// MARK: - Mi Home sign-in card

/// «Камеры Mi Home» when go2rtc has no Xiaomi account: one sentence and a prominent «Войти в Xiaomi…».
export function MiHomeSignInCard({ variant, disabled, onSignIn }: { variant: 'card' | 'row'; disabled?: boolean; onSignIn: () => void }) {
  return (
    <div className={'mihome-card mihome-card--' + variant}>
      <div className="mihome-card__icon">
        <SignInIcon />
      </div>
      <div className="grow">
        <div className="mihome-card__title">{t('Mi Home Cameras')}</div>
        <div className="mihome-card__text">
          {variant === 'row' ? t('Xiaomi sign-in required') : t('Sign in to your Xiaomi account — your Mi Home cameras will appear here.')}
        </div>
      </div>
      <Button variant="primary" size={variant === 'row' ? 'sm' : 'md'} disabled={disabled} onClick={onSignIn}>
        {t('Sign In to Xiaomi…')}
      </Button>
    </div>
  )
}
