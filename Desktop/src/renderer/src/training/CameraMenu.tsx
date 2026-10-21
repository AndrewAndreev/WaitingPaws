import { t } from '@shared/i18n'
import type { XiaomiQuality } from '@shared/api'
import { secondCameraDisplayName } from '@shared/settings'
import { call, ui, useStore, type CameraSlot } from '../store'
import { cameraName, cameraOnline, hasSecondCamera, visibleCamera } from '../model'
import { openCameraPicker } from '../onboarding/SetupKit'
import { AccountIcon, CameraAddIcon, ChevronDownIcon, DeleteIcon, ReloadIcon, SettingsIcon, VideoAddIcon, VideoFilledIcon, VideoOffIcon } from '../ui/icons'
import { Menu, MenuCheckItem, MenuContent, MenuItem, MenuLabel, MenuNote, MenuSeparator, MenuTrigger, Tooltip } from '../ui/kit'
import { CameraModeMenuItems } from './CameraModeMenu'

const QUALITIES: XiaomiQuality[] = ['auto', '1', '2', '3']

export function qualityTitle(quality: XiaomiQuality): string {
  switch (quality) {
    case 'auto':
      return t('Авто')
    case '1':
      return 'SD'
    case '2':
      return 'HD'
    case '3':
      return '2K'
  }
}

/// «HD · 480p» once the camera has been seen at that level, else «HD». «Авто» has no fixed resolution.
export function qualityLabel(quality: XiaomiQuality, source: string | null, seen: Record<string, Record<string, string>>): string {
  const title = qualityTitle(quality)
  if (quality === 'auto' || !source) return title
  const did = queryValue(source, 'did')
  const size = did ? seen[did]?.[quality] : undefined
  const height = size?.split('x')[1]
  return height ? `${title} · ${height}p` : title
}

function queryValue(source: string, name: string): string | null {
  const query = source.split('?')[1] ?? ''
  for (const part of query.split('&')) {
    const [key, value] = part.split('=')
    if (key === name) return decodeURIComponent(value ?? '')
  }
  return null
}

/// Camera name with status; choose camera, the second camera, Xiaomi sign-in, reconnect, quality and the camera's own
/// modes. With a second camera the name gives way to the «Прихожая · Комната» switcher and the menu opens from a
/// chevron next to it; quality and modes stay the main camera's.
export function CameraMenu() {
  const app = useStore((store) => store.app)!
  const online = cameraOnline(app)
  const quality = app.camera.xiaomiQuality
  const name = cameraName(app) || t('Камера')
  const label = quality ? `${name} · ${qualityTitle(quality)}` : name
  const hasModes = Boolean(app.cameraModes?.options?.length)
  const second = hasSecondCamera(app.settings)
  return (
    <div className="tb-cameras">
      {second && <CameraSwitcher />}
      <Menu>
        <Tooltip content={online ? t('Камера, качество и режим съёмки') : t('Камера не на связи — выбрать или переподключить')}>
          <MenuTrigger asChild>
            {second ? (
              <button className="tb-btn tb-btn--chevron" aria-label={t('Камеры')}>
                {!online && <VideoOffIcon />}
                <ChevronDownIcon style={{ width: 14, height: 14 }} />
              </button>
            ) : (
              <button className="tb-btn">
                {online ? <VideoFilledIcon /> : <VideoOffIcon />}
                <span className="ellipsis">{label}</span>
                <ChevronDownIcon style={{ width: 14, height: 14 }} />
              </button>
            )}
          </MenuTrigger>
        </Tooltip>
        <CameraMenuContent name={name} quality={quality} hasModes={hasModes} second={second} />
      </Menu>
    </div>
  )
}

/// «Прихожая · Комната»: which camera is on screen (Ctrl+1 / Ctrl+2). The hidden one keeps its connection — a green
/// dot says it is live.
function CameraSwitcher() {
  const app = useStore((store) => store.app)!
  const chosen = useStore((store) => store.camera)
  const live = useStore((store) => store.cameraLive)
  const shown = visibleCamera(app.settings, chosen)
  const names: Record<CameraSlot, string> = { main: cameraName(app) || t('Камера'), second: secondCameraDisplayName(app.settings) }
  const segment = (slot: CameraSlot, keys: string) => (
    <Tooltip
      key={slot}
      content={
        shown === slot
          ? `${names[slot]} (${keys})`
          : t('%1$@ — %2$@ (%3$@)', names[slot], live[slot] ? t('на связи') : t('подключается…'), keys)
      }
    >
      <button type="button" className="tb-seg__item" aria-pressed={shown === slot} onClick={() => ui.set({ camera: slot })}>
        {shown === slot ? <VideoFilledIcon /> : <span className={'dot' + (live[slot] ? ' dot--live' : '')} />}
        <span className="ellipsis">{names[slot]}</span>
      </button>
    </Tooltip>
  )
  return (
    <div className="tb-seg" role="group" aria-label={t('Камера на экране')}>
      {segment('main', 'Ctrl+1')}
      {segment('second', 'Ctrl+2')}
    </div>
  )
}

function CameraMenuContent({ name, quality, hasModes, second }: { name: string; quality: XiaomiQuality | null; hasModes: boolean; second: boolean }) {
  const app = useStore((store) => store.app)!
  return (
    <MenuContent align="end">
      <MenuItem icon={<CameraAddIcon />} onSelect={() => ui.set({ showCameraPicker: true })}>
        {second ? t('Основная камера…') : t('Выбрать камеру…')}
      </MenuItem>
      <MenuItem icon={<VideoAddIcon />} onSelect={() => openCameraPicker({ target: 'second' })}>
        {t('Вторая камера…')}
      </MenuItem>
      {second && (
        <MenuItem
          icon={<DeleteIcon />}
          onSelect={() => {
            ui.set({ camera: 'main' })
            void call('settings.update', { secondStreamName: '', secondCameraTitle: '' })
          }}
        >
          {t('Убрать вторую камеру')}
        </MenuItem>
      )}
      <MenuItem icon={<AccountIcon />} onSelect={() => ui.set({ showXiaomiSignIn: true })}>
        {app.settings.xiaomiAccountID ? t('Войти в другой аккаунт Xiaomi…') : t('Войти в Xiaomi…')}
      </MenuItem>
      <MenuSeparator />
      <MenuItem
        icon={<ReloadIcon />}
        onSelect={() => {
          void call('camera.reconnect')
          if (second) ui.set({ secondCameraReload: ui.get().secondCameraReload + 1 })
        }}
      >
        {t('Переподключить')}
      </MenuItem>
      {quality && (
        <>
          <MenuSeparator />
          <MenuLabel>{second ? t('Качество — %@', name) : t('Качество')}</MenuLabel>
          {QUALITIES.map((value) => (
            <MenuCheckItem key={value} checked={value === quality} onSelect={() => void call('camera.setQuality', value)}>
              {qualityLabel(value, app.camera.xiaomiSource, app.settings.qualityResolutions)}
            </MenuCheckItem>
          ))}
          <MenuNote>
            {t('Записи — в этом же качестве')}
            {app.camera.videoSize && (
              <>
                <br />
                {t('Сейчас %lld×%lld', app.camera.videoSize.width, app.camera.videoSize.height)}
              </>
            )}
          </MenuNote>
        </>
      )}
      {hasModes && (
        <>
          <MenuSeparator />
          <CameraModeMenuItems />
        </>
      )}
      <MenuSeparator />
      <MenuItem icon={<SettingsIcon />} onSelect={() => ui.set({ route: 'settings', settingsPane: 'camera' })}>
        {t('Настройки камеры…')}
      </MenuItem>
    </MenuContent>
  )
}
