import { useEffect, useState } from 'react'
import { t } from '@shared/i18n'
import type { XiaomiQuality } from '@shared/api'
import { availablePlayerModes, effectivePlayerMode, type PlayerMode } from '@shared/settings'
import { call, ui, useApp, useStore } from '../store'
import { cameraName, isConfigured } from '../model'
import { CameraView } from '../player/CameraView'
import type { PlayerPhase } from '../player/CameraPlayer'
import { qualityLabel } from '../training/CameraMenu'
import { useCameraModes, type CameraModeOptionView } from '../training/CameraModeMenu'
import { Button, Dialog, Segmented, Spinner, Switch, Tooltip } from '../ui/kit'
import { AccountIcon, CameraAddIcon, CameraIcon, PersonIcon, PlayerIcon, QualityIcon, ReloadIcon, ResolutionIcon, SignOutIcon, SoundOnIcon, StreamIcon, VideoOffIcon } from '../ui/icons'
import { Card, Group, PaneHeader, Row, Select, Value } from './rows'
import { activeClient, cameraKind, isXiaomiCamera, pixels, queryValue, redacted, regionTitle, serverReady, sourceBadge, sourceHost } from './cameraText'

const QUALITIES: XiaomiQuality[] = ['auto', '1', '2', '3']

/// Камера: the live picture, quality, player and sound, the camera's own modes, where the stream comes from and the
/// Xiaomi accounts signed in on go2rtc.
export function CameraPane() {
  const app = useApp()
  const showCameraPicker = useStore((store) => store.showCameraPicker)
  const showXiaomiSignIn = useStore((store) => store.showXiaomiSignIn)
  const configured = isConfigured(app.settings)
  const ready = serverReady(app)
  const streamName = app.settings.streamName
  /// The stream's source as written in the go2rtc config (null: not read yet / no camera).
  const [source, setSource] = useState<string | null>(null)
  /// Xiaomi accounts signed in on go2rtc; null while unknown (go2rtc not running, a server without the xiaomi module).
  const [accounts, setAccounts] = useState<string[] | null>(null)
  const [switchingQuality, setSwitchingQuality] = useState(false)
  const [signOutAccount, setSignOutAccount] = useState<string | null>(null)
  const [signingOut, setSigningOut] = useState<string | null>(null)
  const [accountsRevision, setAccountsRevision] = useState(0)
  /// What the preview's player is doing (null: just (re)connected).
  const [phase, setPhase] = useState<PlayerPhase | null>(null)

  // The source of the selected stream; quality and modes again on every visit (they may have changed in Mi Home).
  useEffect(() => {
    setSource(null)
    const client = activeClient(app)
    if (!configured || !client) return
    let cancelled = false
    void call('camera.refresh')
    void (async () => {
      let sources = await client.configuredSources(streamName).catch(() => [] as string[])
      if (!sources.length) sources = (await client.streams().catch(() => [])).find((stream) => stream.name === streamName)?.sources ?? []
      if (!cancelled) setSource(sources[0] ?? null)
    })()
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [streamName, configured, ready, app.server?.baseURL])

  // Accounts again after a sign-in or a camera change in a dialog.
  useEffect(() => {
    const client = activeClient(app)
    if (!client) {
      setAccounts(null)
      return
    }
    let cancelled = false
    client
      .xiaomiAccounts()
      .then((list) => !cancelled && setAccounts(list))
      .catch(() => !cancelled && setAccounts(null))
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, app.server?.baseURL, showCameraPicker, showXiaomiSignIn, accountsRevision, app.settings.xiaomiAccountID])

  const xiaomi = configured && isXiaomiCamera(app, source)
  const qualityAvailable = app.camera.xiaomiQuality !== null
  const quality = app.camera.xiaomiQuality ?? 'auto'
  const cameraSource = source ?? app.camera.xiaomiSource
  const model = cameraSource ? queryValue(cameraSource, 'model') : null

  const setQuality = async (value: XiaomiQuality) => {
    if (value === app.camera.xiaomiQuality || switchingQuality) return
    setSwitchingQuality(true)
    await call('camera.setQuality', value)
    setSwitchingQuality(false)
  }

  const signOut = async (account: string) => {
    setSignOutAccount(null)
    setSigningOut(account)
    await call('xiaomi.logout', account)
    setSigningOut(null)
    setAccountsRevision((revision) => revision + 1)
  }

  const detail = (() => {
    if (!configured) return t('Выберите камеру Mi Home или поток go2rtc.')
    if (xiaomi) return [cameraKind(model), app.settings.xiaomiAccountID ? t('аккаунт %@', app.settings.xiaomiAccountID) : null].filter(Boolean).join(' · ')
    const badge = sourceBadge(source)
    if (badge && source) return [badge, sourceHost(source)].filter(Boolean).join(' · ')
    return t('Поток go2rtc')
  })()

  const size = app.camera.videoSize
  const currentSize = size ? pixels(size.width, size.height) : configured ? '—' : t('нет камеры')
  const modes = availablePlayerModes(app.settings)

  return (
    <>
      <PaneHeader title={t('Камера')} />

      <div className="scam card">
        <CameraPreview phase={phase} onPhase={setPhase} />
        <div className="scam__info">
          <div className="h2 ellipsis">{configured ? cameraName(app) : t('Камера не выбрана')}</div>
          <Tooltip content={model ? t('Модель Mi Home: %@', model) : null}>
            <div className="muted ellipsis scam__detail">{detail}</div>
          </Tooltip>
          <PreviewProblem phase={phase} />
          <div className="row scam__actions">
            <Button variant={configured ? 'default' : 'primary'} icon={<CameraAddIcon />} onClick={() => ui.set({ showCameraPicker: true })}>
              {configured ? t('Выбрать другую камеру…') : t('Выбрать камеру…')}
            </Button>
          </div>
        </div>
      </div>

      <Group title={t('Изображение и звук')}>
        <Row
          icon={<QualityIcon />}
          title={t('Качество')}
          description={!configured ? t('Сначала выберите камеру.') : !qualityAvailable ? t('Меняется только у камер Mi Home.') : t('На экране и в записи.')}
          disabled={!qualityAvailable}
        >
          <Segmented
            value={quality}
            disabled={!qualityAvailable || switchingQuality}
            options={QUALITIES.map((value) => ({ value, label: qualityLabel(value, app.camera.xiaomiSource, app.settings.qualityResolutions) }))}
            onChange={(value) => void setQuality(value)}
          />
        </Row>
        <Row icon={<ResolutionIcon />} title={t('Сейчас')} description={t('Размер кадра, который присылает камера.')}>
          <span className="row" style={{ gap: 8 }}>
            {switchingQuality && <Spinner />}
            <Value>{currentSize}</Value>
          </span>
        </Row>
        <Row icon={<PlayerIcon />} title={t('Плеер')} description={t('Как картинка идёт с go2rtc в окно. Если видео не показывается или отстаёт, попробуйте другой.')}>
          <Select<PlayerMode>
            label={t('Плеер')}
            value={effectivePlayerMode(app.settings)}
            options={modes.map((mode) => ({ value: mode, label: playerTitle(mode) }))}
            onChange={(mode) => void call('settings.update', { playerMode: mode })}
            width={240}
          />
        </Row>
        <Row icon={<SoundOnIcon />} title={t('Звук с камеры в приложении')} description={t('Только для плеера: запись всегда со звуком.')}>
          <Switch checked={app.settings.audioEnabled} label={t('Звук с камеры в приложении')} onChange={(value) => void call('settings.update', { audioEnabled: value })} />
        </Row>
      </Group>

      <CameraModesGroup xiaomi={xiaomi} />

      <Group title={t('Источник')}>
        <Row icon={<StreamIcon />} title={t('Поток go2rtc')} description={source && !source.startsWith('xiaomi://') ? <span className="mono ellipsis selectable" title={redacted(source)}>{redacted(source)}</span> : undefined}>
          <Value mono selectable>
            {configured ? streamName : '—'}
          </Value>
        </Row>
        {xiaomi && (
          <Row icon={<AccountIcon />} title={t('Аккаунт Xiaomi')}>
            <Value>{app.settings.xiaomiAccountID ? `ID ${app.settings.xiaomiAccountID} · ${regionTitle(app.settings.xiaomiRegion)}` : '—'}</Value>
          </Row>
        )}
      </Group>

      <XiaomiAccountsGroup accounts={accounts} signingOut={signingOut} onSignOut={setSignOutAccount} />

      <Dialog
        open={signOutAccount !== null}
        onOpenChange={(open) => !open && setSignOutAccount(null)}
        title={t('Выйти из аккаунта Xiaomi?')}
        description={t('Камеры этого аккаунта перестанут показываться. Войти снова можно в любой момент.')}
        hideClose
        width={460}
        footer={
          <>
            <Button onClick={() => setSignOutAccount(null)}>{t('Отмена')}</Button>
            <Button variant="danger-solid" autoFocus onClick={() => signOutAccount && void signOut(signOutAccount)}>
              {t('Выйти')}
            </Button>
          </>
        }
      />
    </>
  )
}

function playerTitle(mode: PlayerMode): string {
  switch (mode) {
    case 'webrtc':
      return t('WebRTC (минимальная задержка)')
    case 'mse':
      return 'MSE'
    case 'hls':
      return t('HLS (запасной)')
  }
}

/// The live picture (the same go2rtc player as the training page, muted) with «В эфире · 2304×1296», «Подключение…»,
/// «Нет новых кадров» or «Камера не отвечает» over it. The player's phase goes up to the pane (the reason is shown
/// next to the picture).
function CameraPreview({ phase, onPhase }: { phase: PlayerPhase | null; onPhase: (phase: PlayerPhase | null) => void }) {
  const app = useApp()
  const [reload, setReload] = useState(0)
  const [liveSize, setLiveSize] = useState<{ width: number; height: number } | null>(null)
  const configured = isConfigured(app.settings)
  const playing = configured && serverReady(app) && app.server !== null
  const generation = app.camera.playerGeneration
  const stream = app.settings.streamName
  const mode = effectivePlayerMode(app.settings)

  // Every reconnect starts over.
  useEffect(() => {
    setLiveSize(null)
    onPhase(null)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stream, generation, reload, mode, playing])

  if (!playing || !app.server) {
    const text = !configured
      ? t('Здесь будет картинка с камеры')
      : app.go2rtc.status === 'starting'
        ? t('Запускаем go2rtc…')
        : app.settings.connectionMode === 'embedded' && app.go2rtc.status !== 'running'
          ? t('go2rtc не запущен')
          : t('Нет картинки')
    return (
      <div className="scam__preview scam__preview--empty">
        <VideoOffIcon style={{ width: 32, height: 32 }} />
        <span>{text}</span>
      </div>
    )
  }

  return (
    <div className="scam__preview">
      <CameraView
        baseURL={app.server.baseURL}
        stream={stream}
        mode={mode}
        muted
        fill
        showStatus={false}
        reloadToken={reload + generation}
        onPhase={onPhase}
        onVideoSize={(width, height) => {
          setLiveSize({ width, height })
          void call('camera.reportVideoSize', width, height)
        }}
      >
        <PreviewChip phase={phase} size={liveSize} />
        <Tooltip content={t('Переподключить камеру')}>
          <button className="scam__reload" aria-label={t('Переподключить камеру')} onClick={() => setReload((value) => value + 1)}>
            <ReloadIcon />
          </button>
        </Tooltip>
      </CameraView>
    </div>
  )
}

function PreviewChip({ phase, size }: { phase: PlayerPhase | null; size: { width: number; height: number } | null }) {
  const small = { width: 12, height: 12, borderWidth: 1.5 }
  if (phase?.kind === 'failed') {
    return (
      <div className="scam__chip scam__chip--failed">
        <span className="dot" style={{ background: 'var(--danger)' }} />
        {t('Камера не отвечает')}
      </div>
    )
  }
  if (phase?.kind === 'stalled') {
    return (
      <div className="scam__chip">
        <span className="spinner" style={small} />
        {t('Нет новых кадров — ждём камеру')}
      </div>
    )
  }
  const live = size !== null && (phase === null || phase.kind === 'playing')
  return (
    <div className="scam__chip tabular">
      {live ? <span className="dot dot--live" /> : <span className="spinner" style={small} />}
      {live ? t('В эфире · %@', pixels(size.width, size.height)) : t('Подключение…')}
    </div>
  )
}

/// The reason go2rtc gave for a camera that does not answer ("I/O timeout. Пробуем снова…"), go2rtc's own words
/// in the tooltip.
function PreviewProblem({ phase }: { phase: PlayerPhase | null }) {
  if (phase?.kind !== 'failed') return null
  const reason = t(phase.reason)
  return (
    <Tooltip content={phase.raw || null}>
      <div className="scam__problem">{t('%@. Пробуем снова…', reason ? reason[0].toUpperCase() + reason.slice(1) : reason)}</div>
    </Tooltip>
  )
}

/// Night mode, image flip, status light… as the camera's MIoT spec declares them (Mi Home cameras only).
function CameraModesGroup({ xiaomi }: { xiaomi: boolean }) {
  const modes = useCameraModes()
  if (!modes.options.length) {
    if (xiaomi && modes.state === 'loading') {
      return (
        <Group title={t('Режим камеры')}>
          <Row icon={<CameraIcon />} title={<span className="muted">{t('Читаю настройки камеры…')}</span>}>
            <Spinner />
          </Row>
        </Group>
      )
    }
    return null
  }
  const ordered = [...modes.options.filter((option) => option.isPicture), ...modes.options.filter((option) => !option.isPicture)]
  const footer = modes.error ? (
    <span style={{ color: 'var(--danger)' }}>{modes.error}</span>
  ) : modes.state === 'unavailable' && modes.reason ? (
    <span style={{ color: 'var(--warning)' }}>{modes.reason}</span>
  ) : (
    t('Настройки хранятся в самой камере и меняются через облако Xiaomi, как в Mi Home.')
  )
  return (
    <Group title={t('Режим камеры')} busy={modes.state === 'loading' || modes.options.some((option) => !option.canChange && modes.state === 'ready')} footer={footer}>
      {ordered.map((option) => (
        <CameraModeRow key={option.key} option={option} />
      ))}
    </Group>
  )
}

function CameraModeRow({ option }: { option: CameraModeOptionView }) {
  if (option.kind === 'toggle') {
    return (
      <Row title={option.title} description={option.hint ?? undefined} disabled={!option.canChange}>
        <Switch checked={option.value === true} disabled={!option.canChange} label={option.title} onChange={(value) => void call('camera.setMode', option.key, value)} />
      </Row>
    )
  }
  const value = option.value === null ? '' : String(option.value)
  return (
    <Row title={option.title} description={option.hint ?? undefined} disabled={!option.canChange}>
      <select className="select" aria-label={option.title} value={value} disabled={!option.canChange} style={{ minWidth: 200 }} onChange={(event) => void call('camera.setMode', option.key, Number(event.target.value))}>
        {option.value === null && <option value="">{option.valueText || '—'}</option>}
        {option.choices.map((choice) => (
          <option key={choice.value} value={String(choice.value)}>
            {choice.title}
          </option>
        ))}
      </select>
    </Row>
  )
}

/// Accounts signed in on go2rtc with «Выйти…»; without any, the way to Mi Home cameras.
function XiaomiAccountsGroup({ accounts, signingOut, onSignOut }: { accounts: string[] | null; signingOut: string | null; onSignOut: (account: string) => void }) {
  const app = useApp()
  const signIn = () => ui.set({ showXiaomiSignIn: true })
  // Unknown (go2rtc not running or no xiaomi module): the saved account, if any.
  const list = accounts ?? (app.settings.xiaomiAccountID ? [app.settings.xiaomiAccountID] : [])
  if (list.length === 0) {
    return (
      <Group title={t('Аккаунты Xiaomi')}>
        <Row icon={<AccountIcon />} title={t('Камеры Mi Home')} description={t('Войдите в аккаунт Xiaomi — здесь появятся камеры из Mi Home.')}>
          <Button onClick={signIn} disabled={!serverReady(app)}>
            {t('Войти в Xiaomi…')}
          </Button>
        </Row>
      </Group>
    )
  }
  return (
    <Group title={t('Аккаунты Xiaomi')} footer={t('После выхода ключ доступа Xiaomi удаляется с этого компьютера, а камеры аккаунта — из приложения.')}>
      <Card>
        {list.map((account) => (
          <Row
            key={account}
            icon={<PersonIcon />}
            title={`ID ${account}`}
            description={account === app.settings.xiaomiAccountID ? regionTitle(app.settings.xiaomiRegion) : undefined}
          >
            {signingOut === account ? (
              <Spinner />
            ) : (
              <Button icon={<SignOutIcon />} disabled={signingOut !== null} onClick={() => onSignOut(account)}>
                {t('Выйти…')}
              </Button>
            )}
          </Row>
        ))}
        <Row title={<span className="muted">{t('Ещё один аккаунт — камеры из другого дома Mi Home.')}</span>}>
          <Button variant="subtle" onClick={signIn} disabled={!serverReady(app)}>
            {t('Войти в другой аккаунт Xiaomi…')}
          </Button>
        </Row>
      </Card>
    </Group>
  )
}
