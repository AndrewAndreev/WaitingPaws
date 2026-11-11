import { t } from '@shared/i18n'
import { call, useStore } from '../store'
import { CameraIcon } from '../ui/icons'
import { MenuCheckItem, MenuLabel, MenuNote, MenuSeparator, SubMenu } from '../ui/kit'

/// What the backend sends about the camera's own settings (night mode, flip…), already in the UI language.
export interface CameraModesState {
  state: 'none' | 'loading' | 'ready' | 'unavailable'
  reason: string | null
  error: string | null
  options: CameraModeOptionView[]
}

export interface CameraModeOptionView {
  /// "siid.piid" of the MIoT property.
  key: string
  setting: string
  title: string
  hint: string | null
  kind: 'toggle' | 'choice'
  choices: { value: number; title: string }[]
  isPicture: boolean
  isNight: boolean
  /// Current value: boolean for switches, the choice's number for modes.
  value: boolean | number | null
  valueText: string
  canChange: boolean
}

export function useCameraModes(): CameraModesState {
  return (useStore((store) => store.app?.cameraModes) as CameraModesState | undefined) ?? { state: 'none', reason: null, error: null, options: [] }
}

/// Camera modes inside the camera menu: night mode on its own, everything else the camera declares in a submenu.
export function CameraModeMenuItems() {
  const modes = useCameraModes()
  if (!modes.options.length) return null
  const night = modes.options.find((option) => option.isNight)
  const others = modes.options.filter((option) => !option.isNight)
  return (
    <>
      {night && <ModeItems option={night} />}
      {others.length > 0 && (
        <SubMenu icon={<CameraIcon />} label={t('Camera Settings')}>
          {others
            .filter((option) => option.isPicture)
            .map((option) => (
              <ModeItems key={option.key} option={option} nested />
            ))}
          <MenuSeparator />
          {others
            .filter((option) => !option.isPicture)
            .map((option) => (
              <ModeItems key={option.key} option={option} nested />
            ))}
          {modes.state === 'unavailable' && modes.reason && <MenuNote>{modes.reason}</MenuNote>}
        </SubMenu>
      )}
    </>
  )
}

function ModeItems({ option, nested }: { option: CameraModeOptionView; nested?: boolean }) {
  if (option.kind === 'toggle') {
    return (
      <MenuCheckItem checked={option.value === true} disabled={!option.canChange} onSelect={() => void call('camera.setMode', option.key, !(option.value === true))}>
        {option.title}
      </MenuCheckItem>
    )
  }
  const items = option.choices.map((choice) => (
    <MenuCheckItem key={choice.value} checked={option.value === choice.value} disabled={!option.canChange} onSelect={() => void call('camera.setMode', option.key, choice.value)}>
      {choice.title}
    </MenuCheckItem>
  ))
  if (nested) {
    return (
      <SubMenu label={`${option.title} · ${option.valueText}`}>
        {items}
      </SubMenu>
    )
  }
  return (
    <>
      <MenuLabel>{option.title}</MenuLabel>
      {items}
    </>
  )
}
