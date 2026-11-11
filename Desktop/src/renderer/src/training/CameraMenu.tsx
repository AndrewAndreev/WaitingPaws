import { t } from '@shared/i18n'
import type { XiaomiQuality } from '@shared/api'
import { secondCameraDisplayName } from '@shared/settings'
import { queryValue } from '@core/go2rtcClient'
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
      return t('Auto')
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

/// Camera name with status; choose camera, the second camera, Xiaomi sign-in, reconnect, quality and the camera's own
/// modes. With a second camera the name gives way to the «Прихожая · Комната» switcher and the menu opens from a
/// chevron next to it; quality and modes stay the main camera's.
export function CameraMenu() {
  const app = useStore((store) => store.app)!
  const online = cameraOnline(app)
  const quality = app.camera.xiaomiQuality
  const name = cameraName(app) || t('Camera')
  const label = quality ? `${name} · ${qualityTitle(quality)}` : name
  const hasModes = Boolean(app.cameraModes?.options?.length)
  const second = hasSecondCamera(app.settings)
  return (
    <div className="tb-cameras">
      {second && <CameraSwitcher />}
      <Menu>
        <Tooltip content={online ? t('Camera, quality and shooting mode') : t('Camera offline — choose or reconnect')}>
          <MenuTrigger asChild>
            {second ? (
              <button className="tb-btn tb-btn--chevron" aria-label={t('Cameras')}>
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
  const names: Record<CameraSlot, string> = { main: cameraName(app) || t('Camera'), second: secondCameraDisplayName(app.settings) }
  const segment = (slot: CameraSlot, keys: string) => (
    <Tooltip
      key={slot}
      content={
        shown === slot
          ? `${names[slot]} (${keys})`
          : t('%1$@ — %2$@ (%3$@)', names[slot], live[slot] ? t('online') : t('connecting…'), keys)
      }
    >
      <button type="button" className="tb-seg__item" aria-pressed={shown === slot} onClick={() => ui.set({ camera: slot })}>
        {shown === slot ? <VideoFilledIcon /> : <span className={'dot' + (live[slot] ? ' dot--live' : '')} />}
        <span className="ellipsis">{names[slot]}</span>
      </button>
    </Tooltip>
  )
  return (
    <div className="tb-seg" role="group" aria-label={t('Camera on screen')}>
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
        {second ? t('Main Camera…') : t('Choose Camera…')}
      </MenuItem>
      <MenuItem icon={<VideoAddIcon />} onSelect={() => openCameraPicker({ target: 'second' })}>
        {t('Second Camera…')}
      </MenuItem>
      {second && (
        <MenuItem
          icon={<DeleteIcon />}
          onSelect={() => {
            ui.set({ camera: 'main' })
            void call('settings.update', { secondStreamName: '', secondCameraTitle: '' })
          }}
        >
          {t('Remove Second Camera')}
        </MenuItem>
      )}
      <MenuItem icon={<AccountIcon />} onSelect={() => ui.set({ showXiaomiSignIn: true })}>
        {app.settings.xiaomiAccountID ? t('Sign In to Another Xiaomi Account…') : t('Sign In to Xiaomi…')}
      </MenuItem>
      <MenuSeparator />
      <MenuItem
        icon={<ReloadIcon />}
        onSelect={() => {
          void call('camera.reconnect')
          if (second) ui.set({ secondCameraReload: ui.get().secondCameraReload + 1 })
        }}
      >
        {t('Reconnect')}
      </MenuItem>
      {quality && (
        <>
          <MenuSeparator />
          <MenuLabel>{second ? t('Quality — %@', name) : t('Quality')}</MenuLabel>
          {QUALITIES.map((value) => (
            <MenuCheckItem key={value} checked={value === quality} onSelect={() => void call('camera.setQuality', value)}>
              {qualityLabel(value, app.camera.xiaomiSource, app.settings.qualityResolutions)}
            </MenuCheckItem>
          ))}
          <MenuNote>
            {t('Recordings use this quality too')}
            {app.camera.videoSize && (
              <>
                <br />
                {t('Current: %lld×%lld', app.camera.videoSize.width, app.camera.videoSize.height)}
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
        {t('Camera Settings…')}
      </MenuItem>
    </MenuContent>
  )
}
