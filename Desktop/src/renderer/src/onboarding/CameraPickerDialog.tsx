import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Popover } from 'radix-ui'
import type { Go2RTCStream } from '@core/go2rtcClient'
import { t } from '@shared/i18n'
import { call, ui, useApp } from '../store'
import { AddIcon, ReloadIcon, SelectedIcon, SignInIcon, VideoOffIcon, WarningIcon } from '../ui/icons'
import { Button, Dialog, Spinner, Tooltip } from '../ui/kit'
import {
  Camera,
  addSourceStream,
  cameraID,
  choiceID,
  currentID,
  errorText,
  findChoice,
  otherStreams,
  pixels,
  prepareChoice,
  regionTitle,
  sourceBadge,
  streamDetail,
  streamID,
  useCatalog,
  useSetupServer,
  type CatalogAccount,
  type Choice,
  type SetupServer,
} from './catalog'
import { refreshStills, stillSourceOf, useStill, useStillsSession, type StillSource } from './stills'
import { CameraStill, MiHomeSignInCard, ServerStatusLine, usePickerRequest } from './SetupKit'
import { XiaomiSignInDialog } from './XiaomiSignInDialog'
import '../styles/onboarding.css'

/// «Выбрать камеру…»: Mi Home cameras and other go2rtc streams as tiles. Choosing one registers its stream in go2rtc
/// when needed, saves it as the app's camera and closes the dialog. Mi Home cameras that are not streams yet get a
/// preview on demand. Without a Xiaomi account on go2rtc the Mi Home part is a card with «Войти в Xiaomi…»: after the
/// sign-in its cameras appear right here. What it lists (only streams, one account) and which camera it is for (the
/// main one or «Вторая камера…», which only becomes `secondStreamName`) comes from `openCameraPicker`.
export function CameraPickerDialog({ onClose }: { onClose: () => void }) {
  const app = useApp()
  const [request] = useState(() => usePickerRequest.getState())
  // The request is for this opening only (the camera menu opens the picker without one).
  useEffect(() => () => usePickerRequest.setState({ onlyStreams: false, accountID: null, region: null, target: 'main' }), [])
  const onlyStreams = request.onlyStreams
  const forSecond = request.target === 'second'
  /// The settings this picker reads and writes: the second camera's look like the main camera's to the catalog.
  const current = forSecond ? { ...app.settings, streamName: app.settings.secondStreamName } : app.settings
  /// After a sign-in here every account is listed, not only `request.accountID`.
  const [allAccounts, setAllAccounts] = useState(false)
  const [signedInRegion, setSignedInRegion] = useState(request.region)
  const setup = useSetupServer()
  const catalog = useCatalog(setup, { account: onlyStreams || allAccounts ? null : request.accountID, region: signedInRegion })
  const [selection, setSelection] = useState<string | null>(null)
  /// An account just signed in to: its first camera gets selected.
  const [selectAccount, setSelectAccount] = useState<string | null>(request.accountID)
  const [choosing, setChoosing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [signingIn, setSigningIn] = useState(false)
  useStillsSession()
  // The first focus goes to the content, not the ✕: set when the portal attaches it, before the dialog's own focus
  // handling (which then leaves it there).
  const focused = useRef(false)
  const focusTarget = useCallback((element: HTMLDivElement | null) => {
    if (!element || focused.current) return
    focused.current = true
    element.focus()
  }, [])

  const accounts = onlyStreams ? [] : catalog.accounts
  const others = useMemo(() => otherStreams(catalog), [catalog])
  const loading = catalog.refreshing || catalog.phase.kind === 'loading'

  useEffect(() => {
    if (catalog.phase.kind !== 'ready') return
    const fresh = selectAccount ? catalog.accounts.find((account) => account.id === selectAccount)?.cameras[0] : undefined
    if (fresh) {
      setSelection(cameraID(fresh))
      setSelectAccount(null)
    } else if (!findChoice(catalog, selection)) {
      const chosen = currentID(catalog, current)
      const visible = chosen && (!onlyStreams || others.some((stream) => streamID(stream.name) === chosen))
      // For the second camera the first one that is not the main camera.
      const main = forSecond ? currentID(catalog, app.settings) : null
      setSelection(visible ? chosen : firstID(accounts, others, main))
    }
    // Only when the lists change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [catalog.accounts, catalog.streams, catalog.phase.kind])

  const refresh = async () => {
    const data = await catalog.reload()
    if (data && setup.client) refreshStills(setup.client, onlyStreams ? { ...data, accounts: [] } : data)
  }

  const choose = async (id: string | null) => {
    const choice = findChoice(catalog, id)
    if (!choice || choosing || !setup.client) return
    if (forSecond && id === currentID(catalog, app.settings)) {
      setError(t('This is already the main camera — choose another one'))
      return
    }
    setChoosing(true)
    setError(null)
    try {
      const patch = await prepareChoice(choice, setup.client)
      if (forSecond) {
        if (patch.streamName === app.settings.streamName) {
          setError(t('This is already the main camera — choose another one'))
          setChoosing(false)
          return
        }
        // View-only: the stream and its name, nothing of the main camera's account, quality or modes.
        onClose()
        ui.set({ camera: 'second' })
        await call('settings.update', { secondStreamName: patch.streamName ?? '', secondCameraTitle: patch.cameraTitle ?? '' })
        return
      }
      // Closed before the settings change: the page behind may switch (welcome → training) right away.
      onClose()
      await call('streams.select', patch)
    } catch (caught) {
      setError(t('Couldn’t add the camera: %@', errorText(caught)))
      setChoosing(false)
    }
  }

  const tile = (choice: Choice) => (
    <PickerTile
      key={choiceID(choice)}
      choice={choice}
      setup={setup}
      selected={selection === choiceID(choice)}
      onSelect={setSelection}
      onChoose={(id) => void choose(id)}
    />
  )

  let content: ReactNode
  const phase = catalog.phase
  if (phase.kind === 'idle' || phase.kind === 'loading') {
    content = (
      <div className="picker__empty">
        <Spinner large />
        <span className="muted">{t('Looking for cameras…')}</span>
      </div>
    )
  } else if (phase.kind === 'waiting') {
    content = (
      <div className="picker__empty">
        <VideoOffIcon className="picker__empty-icon" />
        <div className="empty-state__title">{t('go2rtc is not running')}</div>
        <div className="muted">{t('The camera list will appear once go2rtc is running.')}</div>
      </div>
    )
  } else if (phase.kind === 'failed') {
    content = (
      <div className="picker__empty">
        <WarningIcon className="picker__empty-icon" />
        <div className="empty-state__title">{t('No Connection to go2rtc')}</div>
        <div className="muted selectable">{phase.message}</div>
        <Button onClick={() => void catalog.reload()}>{t('Try Again|short')}</Button>
      </div>
    )
  } else if (onlyStreams && others.length === 0) {
    content = (
      <div className="picker__empty">
        <VideoOffIcon className="picker__empty-icon" />
        <div className="empty-state__title">{t('No Streams in go2rtc')}</div>
        <div className="muted">{t('Add a source by an rtsp:// or http:// address (an ONVIF camera by its rtsp:// address).')}</div>
        <AddStreamButton setup={setup} variant="default" onAdded={(stream) => void catalog.reload().then(() => setSelection(streamID(stream.name)))} />
      </div>
    )
  } else {
    content = (
      <div className="picker__sections">
        {!onlyStreams && catalog.accounts.length === 0 && <MiHomeSignInCard variant="card" disabled={!setup.ready} onSignIn={() => setSigningIn(true)} />}
        {accounts.map((account, index) => (
          <Section
            key={account.id}
            title="Mi Home"
            detail={`ID ${account.id} · ${regionTitle(account.region)}`}
            accessory={
              index === 0 ? (
                <Tooltip content={t('Add cameras from another Xiaomi account')}>
                  <Button variant="subtle" size="sm" icon={<SignInIcon />} disabled={!setup.ready} onClick={() => setSigningIn(true)}>
                    {t('Sign In to Another Account…')}
                  </Button>
                </Tooltip>
              ) : null
            }
          >
            <AccountCameras account={account} tile={tile} />
          </Section>
        ))}
        <Section
          title={accounts.length === 0 ? t('go2rtc Streams') : t('Other go2rtc Streams')}
          accessory={
            <AddStreamButton setup={setup} variant="subtle" onAdded={(stream) => void catalog.reload().then(() => setSelection(streamID(stream.name)))} />
          }
        >
          {others.length === 0 ? (
            <div className="picker__note muted">{t('RTSP, HTTP and other go2rtc sources will appear here.')}</div>
          ) : (
            <div className="picker__grid">{others.map((stream) => tile({ kind: 'stream', stream }))}</div>
          )}
        </Section>
      </div>
    )
  }

  return (
    <Dialog
      open
      onOpenChange={(open) => !open && !choosing && onClose()}
      title={forSecond ? t('Second Camera') : onlyStreams ? t('Choose a go2rtc Stream') : t('Choose a Camera')}
      description={
        forSecond
          ? t('To see another room: switch in the top bar or with Ctrl+1 / Ctrl+2. Recording, quality and modes stay with the main camera.')
          : onlyStreams
            ? t('RTSP, HTTP and other sources already in go2rtc.')
            : t('Pick the one facing the front door. Video travels over the local network through go2rtc.')
      }
      width={800}
      height={onlyStreams ? 520 : 640}
      bodyClassName="picker"
      footer={
        <>
          <div className="picker__footer-status grow">
            {error ? (
              <Tooltip content={error}>
                <span className="picker__error ellipsis">
                  <WarningIcon />
                  <span className="ellipsis">{error}</span>
                </span>
              </Tooltip>
            ) : choosing ? (
              <span className="row muted">
                <Spinner />
                {t('Adding the camera to go2rtc…')}
              </span>
            ) : (
              <ServerStatusLine probe={catalog} />
            )}
          </div>
          <Tooltip content={t('Refresh the camera list')}>
            <Button iconOnly className="picker__refresh" aria-label={t('Refresh')} disabled={!setup.ready || loading} onClick={() => void refresh()}>
              {loading ? <Spinner /> : <ReloadIcon />}
            </Button>
          </Tooltip>
          <Button onClick={onClose} disabled={choosing}>
            {t('Cancel|verb')}
          </Button>
          <Button variant="primary" disabled={!findChoice(catalog, selection) || choosing} onClick={() => void choose(selection)}>
            {t('Choose')}
          </Button>
        </>
      }
    >
      <div className="picker__content" tabIndex={-1} ref={focusTarget}>
        {content}
      </div>
      {signingIn && (
        <XiaomiSignInDialog
          onClose={() => setSigningIn(false)}
          onSignedIn={(accountID, region) => {
            setSigningIn(false)
            setAllAccounts(true)
            setSignedInRegion(region)
            setSelectAccount(accountID)
          }}
        />
      )}
    </Dialog>
  )
}

/// The first camera go2rtc already plays (or the first stream): a sensible default to confirm with Enter. `except`:
/// the main camera, when choosing the second one.
function firstID(accounts: CatalogAccount[], others: Go2RTCStream[], except: string | null = null): string | null {
  const cameras = accounts.flatMap((account) => account.cameras).filter((item) => cameraID(item) !== except)
  const camera = cameras.find((item) => item.streamName !== null) ?? cameras[0]
  if (camera) return cameraID(camera)
  const stream = others.find((item) => streamID(item.name) !== except)
  return stream ? streamID(stream.name) : null
}

function Section({ title, detail, accessory, children }: { title: string; detail?: string; accessory?: ReactNode; children: ReactNode }) {
  return (
    <section className="picker__section">
      <div className="picker__section-header">
        <span className="h3">{title}</span>
        {detail && <span className="muted picker__section-detail">{detail}</span>}
        <span className="spacer" />
        {accessory}
      </div>
      {children}
    </section>
  )
}

function AccountCameras({ account, tile }: { account: CatalogAccount; tile: (choice: Choice) => ReactNode }) {
  if (account.error) {
    return (
      <div className="picker__account-error">
        <WarningIcon />
        <span className="selectable">{t('Couldn’t load cameras: %@', account.error)}</span>
      </div>
    )
  }
  if (account.cameras.length === 0) return <div className="picker__note muted">{t('This account has no cameras.')}</div>
  return <div className="picker__grid">{account.cameras.map((camera) => tile({ kind: 'camera', camera }))}</div>
}

/// Still with a status chip, selection ring and check, name and one line of detail.
function PickerTile({
  choice,
  setup,
  selected,
  onSelect,
  onChoose,
}: {
  choice: Choice
  setup: SetupServer
  selected: boolean
  onSelect: (id: string) => void
  onChoose: (id: string) => void
}) {
  const id = choiceID(choice)
  const source: StillSource = choice.kind === 'camera' ? stillSourceOf(choice.camera) : { kind: 'stream', name: choice.stream.name }
  const still = useStill(setup.client, source, setup.ready)
  const isCamera = choice.kind === 'camera'
  const title = isCamera ? choice.camera.source.name : choice.stream.name
  // "2304×1296 · Камера Xiaomi" (the raw model id only in the tooltip) or the stream's source.
  const subtitle = isCamera
    ? still?.kind === 'loaded'
      ? `${pixels(still.width, still.height)} · ${Camera.kind(choice.camera)}`
      : Camera.kind(choice.camera)
    : streamDetail(choice.stream)
  const tooltip = isCamera ? Camera.technicalDetails(choice.camera) || Camera.kind(choice.camera) : subtitle
  const badge = isCamera ? null : sourceBadge(choice.stream.sources[0])

  let chip: ReactNode
  if (still?.kind === 'loaded') {
    chip = (
      <>
        <span className="dot dot--live" />
        {isCamera ? t('Online') : (badge ?? t('Online'))}
      </>
    )
  } else if (still?.kind === 'failed') {
    chip = (
      <>
        <span className="dot" />
        {isCamera ? t('Offline') : badge ? t('%@ · no connection', badge) : t('No connection')}
      </>
    )
  } else {
    chip = (
      <>
        <Spinner />
        {isCamera ? t('Connecting…') : (badge ?? t('Connecting…'))}
      </>
    )
  }

  return (
    <button
      type="button"
      className={'tile' + (still?.kind === 'failed' ? ' tile--offline' : '')}
      aria-pressed={selected}
      onClick={() => onSelect(id)}
      onDoubleClick={() => onChoose(id)}
      onKeyDown={(event) => {
        if (event.key === 'Enter') {
          event.preventDefault()
          onChoose(id)
        }
      }}
    >
      <CameraStill client={setup.client} source={source} ready={setup.ready} isCamera={isCamera} className="tile__still">
        <span className="tile__chip">{chip}</span>
        {selected && <SelectedIcon className="tile__check" />}
      </CameraStill>
      <span className="tile__title ellipsis">{title}</span>
      <span className={'tile__subtitle ellipsis' + (isCamera ? '' : ' mono')} title={tooltip}>
        {subtitle}
      </span>
    </button>
  )
}

/// «Добавить поток…»: any go2rtc source by its address, in a flyout.
function AddStreamButton({ setup, variant, onAdded }: { setup: SetupServer; variant: 'default' | 'subtle'; onAdded: (stream: Go2RTCStream) => void }) {
  const [open, setOpen] = useState(false)
  const [name, setName] = useState('')
  const [source, setSource] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const valid = name.trim() !== '' && source.includes('://')

  const add = async () => {
    if (!valid || busy || !setup.client) return
    setBusy(true)
    setError(null)
    try {
      const stream = await addSourceStream(setup.client, name, source)
      setOpen(false)
      setName('')
      setSource('')
      onAdded(stream)
    } catch (caught) {
      setError(errorText(caught))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <Tooltip content={t('Add a source by an rtsp:// or http:// address (an ONVIF camera by its rtsp:// address)')}>
        <Popover.Trigger asChild>
          <Button variant={variant} size={variant === 'subtle' ? 'sm' : 'md'} icon={<AddIcon />} disabled={!setup.ready}>
            {t('Add Stream…')}
          </Button>
        </Popover.Trigger>
      </Tooltip>
      <Popover.Portal>
        <Popover.Content className="popover add-stream" side="bottom" align="end" sideOffset={6} collisionPadding={12}>
          <form
            className="col"
            style={{ gap: 12 }}
            onSubmit={(event) => {
              event.preventDefault()
              void add()
            }}
          >
            <div className="h3">{t('New go2rtc Stream')}</div>
            <label className="field">
              <span className="field__label">{t('Name')}</span>
              <input className="input" value={name} placeholder="testcam" autoFocus spellCheck={false} onChange={(event) => setName(event.target.value)} />
            </label>
            <label className="field">
              <span className="field__label">{t('Address')}</span>
              <input
                className="input mono"
                value={source}
                placeholder="rtsp://192.168.1.20:554/live"
                spellCheck={false}
                onChange={(event) => setSource(event.target.value)}
              />
            </label>
            {error && <div className="setup-error selectable">{error}</div>}
            <div className="row">
              {busy && <Spinner />}
              <span className="spacer" />
              <Button type="submit" variant="primary" disabled={!valid || busy}>
                {t('Add')}
              </Button>
            </div>
          </form>
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  )
}
