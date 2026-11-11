import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from 'react'
import { plural, t } from '@shared/i18n'
import logo from '../assets/logo.svg'
import { call, ui, useApp, useStore } from '../store'
import { ChevronRightIcon, ReloadIcon, ServerIcon, SignInIcon, StreamIcon, TimerIcon, VideoAddIcon, VideoOffIcon, WarningIcon, WifiIcon } from '../ui/icons'
import { Button, ContextMenu, ContextMenuContent, ContextMenuItem, ContextMenuTrigger, Spinner, Tooltip } from '../ui/kit'
import {
  Camera,
  cameraID,
  currentID,
  errorText,
  findChoice,
  hostText,
  otherStreams,
  pixels,
  prepareChoice,
  streamDetail,
  streamID,
  useCatalog,
  useSetupServer,
  type Catalog,
  type CatalogData,
  type SetupServer,
} from './catalog'
import { refreshStills, stillSourceOf, useStill, useStillsSession, type StillSource } from './stills'
import { CameraStill, MiHomeSignInCard, ServerStatusLine, StillDot, closeCameraPicker, openCameraPicker } from './SetupKit'
import { CameraPickerDialog } from './CameraPickerDialog'
import { XiaomiSignInDialog } from './XiaomiSignInDialog'
import { ServerSetupDialog } from './ServerSetupDialog'
import '../styles/onboarding.css'

/// The first launch (Mac: the welcome window): the app and the ways to get a camera on the left, what go2rtc already
/// knows (signed-in Mi Home accounts with cameras, other streams) on the right. Shown full-window until a camera is
/// chosen or the user goes on without one. Hosts its own dialogs (GlobalDialogs only exists after the setup).
export function WelcomePage() {
  const app = useApp()
  const setup = useSetupServer()
  const catalog = useCatalog(setup)
  const [selection, setSelection] = useState<string | null>(null)
  const [opening, setOpening] = useState(false)
  const [openError, setOpenError] = useState<string | null>(null)
  useStillsSession()

  const external = app.settings.connectionMode === 'external'
  const hasItems = catalog.phase.kind === 'ready' && (catalog.accounts.length > 0 || otherStreams(catalog).length > 0)
  const serverSubtitle = external && app.server ? t('Current: %@', hostText(app.server.baseURL)) : t('For example, http://192.168.1.10:1984')

  // Keep a valid selection: the camera in use, else the first one.
  useEffect(() => {
    if (catalog.phase.kind !== 'ready') return
    if (findChoice(catalog, selection)) return
    setSelection(currentID(catalog, app.settings) ?? firstID(catalog))
    // Only when the lists change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [catalog.accounts, catalog.streams, catalog.phase.kind])

  // A sign-in or a new stream may have changed what go2rtc knows.
  const dialogOpen = useStore((store) => store.showCameraPicker || store.showXiaomiSignIn || store.showServerSetup)
  const wasOpen = useRef(dialogOpen)
  useEffect(() => {
    if (wasOpen.current && !dialogOpen) void catalog.reload()
    wasOpen.current = dialogOpen
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dialogOpen])

  const refresh = async () => {
    const data = await catalog.reload()
    if (data && setup.client) refreshStills(setup.client, data)
  }

  /// Registers the chosen camera and saves it; the settings change then swaps the page for the training.
  const open = async (id: string | null) => {
    const choice = findChoice(catalog, id)
    if (!choice || opening || !setup.client) return
    setOpening(true)
    setOpenError(null)
    try {
      const patch = await prepareChoice(choice, setup.client)
      closeCameraPicker()
      await call('streams.select', patch)
    } catch (error) {
      setOpenError(t('Couldn’t add the camera: %@', errorText(error)))
    } finally {
      setOpening(false)
    }
  }

  return (
    <div className="welcome">
      <section className="welcome__identity">
        <div className="welcome__hero">
          <img className="welcome__logo" src={logo} alt="" draggable={false} />
          <h1 className="welcome__name">Waiting Paws</h1>
          <div className="welcome__version">{`${t('Version')} ${app.version}`}</div>
          <ServerStatusLine probe={catalog} />
        </div>
        <div className="welcome__actions">
          <ActionRow
            icon={<SignInIcon />}
            title={t('Sign In to Xiaomi…')}
            subtitle={t('Cameras from the Mi Home app')}
            onClick={() => ui.set({ showXiaomiSignIn: true })}
          />
          <ActionRow
            icon={<StreamIcon />}
            title={t('Choose go2rtc Stream…')}
            subtitle={t('RTSP, HTTP and other sources')}
            onClick={() => openCameraPicker({ onlyStreams: true })}
          />
          <ActionRow icon={<ServerIcon />} title={t('Own go2rtc Server…')} subtitle={serverSubtitle} onClick={() => ui.set({ showServerSetup: true })} />
          <ActionRow
            icon={<TimerIcon />}
            title={t('Continue Without Camera')}
            subtitle={t('Timer, schedule and log')}
            onClick={() => void call('camera.continueWithout')}
          />
        </div>
        <div className="welcome__note">
          <WifiIcon />
          {t('The camera and the computer must be on the same Wi‑Fi network')}
        </div>
      </section>

      <section className="welcome__found" aria-label={t('Already in go2rtc')}>
        <div className="welcome__found-header">
          <h2 className="welcome__found-title">{catalog.accounts.length ? t('Already Signed In on the Server') : t('Already in go2rtc')}</h2>
          <span className="spacer" />
          <Tooltip content={t('Refresh the list')}>
            <Button
              variant="subtle"
              iconOnly
              aria-label={t('Refresh')}
              disabled={!setup.ready || catalog.refreshing || catalog.phase.kind === 'loading'}
              onClick={() => void refresh()}
            >
              {catalog.refreshing ? <Spinner /> : <ReloadIcon />}
            </Button>
          </Tooltip>
        </div>
        <FoundContent catalog={catalog} setup={setup} selection={selection} onSelect={setSelection} onOpen={(id) => void open(id)} />
        {(hasItems || openError || opening) && (
          <div className="welcome__footer">
            {openError ? (
              <Tooltip content={openError}>
                <span className="welcome__error ellipsis">
                  <WarningIcon />
                  {openError}
                </span>
              </Tooltip>
            ) : opening ? (
              <span className="row muted welcome__progress">
                <Spinner />
                {t('Adding the camera…')}
              </span>
            ) : null}
            <span className="spacer" />
            <Button variant="primary" disabled={!findChoice(catalog, selection) || opening} onClick={() => void open(selection)}>
              {t('Open')}
            </Button>
          </div>
        )}
      </section>

      <WelcomeDialogs />
    </div>
  )
}

/// Before the setup the welcome page hosts the setup dialogs (GlobalDialogs takes over afterwards).
function WelcomeDialogs() {
  const showCameraPicker = useStore((store) => store.showCameraPicker)
  const showXiaomiSignIn = useStore((store) => store.showXiaomiSignIn)
  const showServerSetup = useStore((store) => store.showServerSetup)
  return (
    <>
      {showCameraPicker && <CameraPickerDialog onClose={closeCameraPicker} />}
      {showXiaomiSignIn && <XiaomiSignInDialog onClose={() => ui.set({ showXiaomiSignIn: false })} />}
      {showServerSetup && <ServerSetupDialog onClose={() => ui.set({ showServerSetup: false })} />}
    </>
  )
}

function firstID(data: CatalogData): string | null {
  const camera = data.accounts.flatMap((account) => account.cameras)[0]
  if (camera) return cameraID(camera)
  const stream = otherStreams(data)[0]
  return stream ? streamID(stream.name) : null
}

/// One of the ways to a camera: icon, title, one quiet line of detail.
function ActionRow({ icon, title, subtitle, onClick }: { icon: ReactNode; title: string; subtitle: string; onClick: () => void }) {
  return (
    <button type="button" className="welcome-action" onClick={onClick}>
      <span className="welcome-action__icon">{icon}</span>
      <span className="welcome-action__text">
        <span className="welcome-action__title">{title}</span>
        <span className="welcome-action__subtitle ellipsis">{subtitle}</span>
      </span>
      <ChevronRightIcon className="welcome-action__chevron" />
    </button>
  )
}

function FoundContent({
  catalog,
  setup,
  selection,
  onSelect,
  onOpen,
}: {
  catalog: Catalog
  setup: SetupServer
  selection: string | null
  onSelect: (id: string) => void
  onOpen: (id: string) => void
}) {
  const app = useApp()
  const others = useMemo(() => otherStreams(catalog), [catalog])
  const order = useMemo(
    () => [...catalog.accounts.flatMap((account) => account.cameras.map(cameraID)), ...others.map((stream) => streamID(stream.name))],
    [catalog.accounts, others],
  )
  const list = useRef<HTMLDivElement>(null)

  const phase = catalog.phase
  if (phase.kind === 'idle' || phase.kind === 'loading') {
    return (
      <div className="welcome__empty">
        <Spinner />
        <span className="muted">{t('Looking for cameras…')}</span>
      </div>
    )
  }
  if (phase.kind === 'waiting') {
    if (app.settings.connectionMode === 'external') {
      return <Empty icon={<ServerIcon />} title={t('No Server Set')} text={t('Enter the address of your go2rtc: “Own go2rtc Server…” on the left.')} />
    }
    if (app.go2rtc.status === 'failed')
      return <Empty icon={<VideoOffIcon />} title={t('No Cameras Yet')} text={t('go2rtc didn’t start. Click “Try Again” on the left.')} />
    if (app.go2rtc.status === 'unavailable')
      return <Empty icon={<VideoOffIcon />} title={t('No Cameras Yet')} text={t('This build has no built-in go2rtc. Enter your own server.')} />
    // go2rtc is on its way: the sign-in dialog waits for it.
    return <SignInEmpty />
  }
  if (phase.kind === 'failed') return <Empty icon={<WarningIcon />} title={t('No Connection to go2rtc')} text={phase.message} />
  if (catalog.accounts.length === 0 && others.length === 0) return <SignInEmpty />

  const move = (event: KeyboardEvent) => {
    if (event.key === 'Enter' && selection) {
      event.preventDefault()
      onOpen(selection)
      return
    }
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return
    event.preventDefault()
    const index = selection ? order.indexOf(selection) : -1
    const next = order[Math.max(0, Math.min(order.length - 1, index + (event.key === 'ArrowDown' ? 1 : -1)))]
    if (next) {
      onSelect(next)
      list.current?.querySelector(`[data-id="${CSS.escape(next)}"]`)?.scrollIntoView({ block: 'nearest' })
    }
  }

  return (
    <div className="welcome__list" role="listbox" tabIndex={0} ref={list} onKeyDown={move} aria-activedescendant={selection ?? undefined}>
      {catalog.accounts.length === 0 && (
        <div className="welcome__section">
          <div className="welcome__section-header">
            <span>Mi Home</span>
          </div>
          <MiHomeSignInCard variant="row" onSignIn={() => ui.set({ showXiaomiSignIn: true })} />
        </div>
      )}
      {catalog.accounts.map((account) => (
        <div className="welcome__section" key={account.id}>
          <div className="welcome__section-header">
            <span>{`Mi Home · ID ${account.id}`}</span>
            <span className="spacer" />
            <span className="faint">{plural(account.cameras.length, ['%d camera', '%d cameras'], ['%d камера', '%d камеры', '%d камер'])}</span>
          </div>
          {account.error && (
            <div className="welcome__account-error">
              <WarningIcon />
              <span>{t('Couldn’t load cameras: %@', account.error)}</span>
            </div>
          )}
          {account.cameras.map((camera) => (
            <SourceRow
              key={cameraID(camera)}
              id={cameraID(camera)}
              setup={setup}
              title={camera.source.name}
              detail={Camera.kind(camera)}
              tooltip={Camera.technicalDetails(camera) || Camera.kind(camera)}
              source={stillSourceOf(camera)}
              isCamera
              selected={selection === cameraID(camera)}
              onSelect={onSelect}
              onOpen={onOpen}
            />
          ))}
        </div>
      ))}
      {others.length > 0 && (
        <div className="welcome__section">
          <div className="welcome__section-header">
            <span>{t('go2rtc Streams')}</span>
          </div>
          {others.map((stream) => (
            <SourceRow
              key={stream.name}
              id={streamID(stream.name)}
              setup={setup}
              title={stream.name}
              detail={streamDetail(stream)}
              tooltip={streamDetail(stream)}
              source={{ kind: 'stream', name: stream.name }}
              isCamera={false}
              selected={selection === streamID(stream.name)}
              onSelect={onSelect}
              onOpen={onOpen}
            />
          ))}
        </div>
      )}
    </div>
  )
}

/// A Mi Home camera or a go2rtc stream: still (a preview for a camera that is not a stream yet), name, kind of
/// camera or source, and whether a picture came through.
function SourceRow({
  id,
  setup,
  title,
  detail,
  tooltip,
  source,
  isCamera,
  selected,
  onSelect,
  onOpen,
}: {
  id: string
  setup: SetupServer
  title: string
  detail: string
  tooltip: string
  source: StillSource
  isCamera: boolean
  selected: boolean
  onSelect: (id: string) => void
  onOpen: (id: string) => void
}) {
  const still = useStill(setup.client, source, setup.ready)
  const failed = still?.kind === 'failed'
  const text = failed && isCamera ? t('Offline') : still?.kind === 'loaded' && isCamera ? `${pixels(still.width, still.height)} · ${detail}` : detail
  return (
    <ContextMenu>
      <ContextMenuTrigger asChild>
        <div
          className={'source-row' + (failed ? ' source-row--offline' : '')}
          role="option"
          id={id}
          data-id={id}
          aria-selected={selected}
          title={tooltip}
          onMouseDown={() => onSelect(id)}
          onDoubleClick={() => onOpen(id)}
        >
          <CameraStill client={setup.client} source={source} ready={setup.ready} isCamera={isCamera} className="source-row__still" />
          <div className="grow">
            <div className="source-row__title ellipsis">{title}</div>
            <div className={'source-row__detail ellipsis' + (isCamera ? '' : ' mono')}>{text}</div>
          </div>
          <StillDot state={still} />
        </div>
      </ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem onSelect={() => onOpen(id)}>{t('Open')}</ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  )
}

function Empty({ icon, title, text }: { icon: ReactNode; title: string; text: string }) {
  return (
    <div className="welcome__empty">
      <span className="welcome__empty-icon">{icon}</span>
      <div className="empty-state__title">{title}</div>
      <div className="muted welcome__empty-text">{text}</div>
    </div>
  )
}

/// Nothing in go2rtc yet: the way to the cameras is the Xiaomi account (a stream is the second option).
function SignInEmpty() {
  return (
    <div className="welcome__empty">
      <span className="welcome__empty-icon">
        <VideoAddIcon />
      </span>
      <div className="empty-state__title">{t('No Cameras Yet')}</div>
      <div className="muted welcome__empty-text">{t('Sign in to your Xiaomi account — cameras from the Mi Home app will appear here.')}</div>
      <Button variant="primary" size="lg" className="welcome__empty-action" onClick={() => ui.set({ showXiaomiSignIn: true })}>
        {t('Sign In to Xiaomi…')}
      </Button>
      <Button variant="link" onClick={() => openCameraPicker({ onlyStreams: true })}>
        {t('Or Add an RTSP Stream…')}
      </Button>
    </div>
  )
}
