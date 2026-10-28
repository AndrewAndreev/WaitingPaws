import { useState } from 'react'
import { t } from '@shared/i18n'
import type { PairedDeviceInfo } from '@shared/api'
import { call, useApp } from '../store'
import { Button, Dialog, InfoBar, Switch } from '../ui/kit'
import { DesktopIcon, FirewallIcon, PhoneIcon, PhoneLaptopIcon, VideoOffIcon, WarningIcon } from '../ui/icons'
import { Card, Group, PaneHeader, Row, Value } from './rows'

/// iPhone: let the iPhone app find this computer, watch its camera and drive its training; allowed devices.
export function IPhonePane() {
  const app = useApp()
  const sync = app.sync
  const enabled = app.settings.shareWithIPhone
  /// The iPhone «Забыть» asks about: forgetting it also drops its link and changes go2rtc's network password.
  const [forgetting, setForgetting] = useState<PairedDeviceInfo | null>(null)
  const isOnline = (device: PairedDeviceInfo) => device.connected ?? sync.connectedDevices.includes(device.name)
  // As it is now, not when «Забыть» was clicked.
  const forgettingOnline = forgetting ? isOnline(sync.pairedDevices.find((device) => device.id === forgetting.id) ?? forgetting) : false
  return (
    <>
      <PaneHeader title="iPhone" description={t('iPhone в той же сети показывает камеру этого компьютера и ведёт тренировку.')} />
      <Group>
        <Row icon={<PhoneLaptopIcon />} title={t('Разрешить подключение с iPhone')} description={t('Компьютер виден приложению Waiting Paws на iPhone в той же Wi‑Fi сети.')}>
          <Switch checked={enabled} label={t('Разрешить подключение с iPhone')} onChange={(value) => void call('sync.setEnabled', value)} />
        </Row>
        {sync.hostName && (
          <Row icon={<DesktopIcon />} title={t('Имя на iPhone')} description={t('Под этим именем компьютер появится в приложении на iPhone.')}>
            <Value selectable>{sync.hostName}</Value>
          </Row>
        )}
        {sync.error && enabled && <InfoBar kind="warning" icon={<WarningIcon style={{ color: 'var(--warning)', flex: 'none' }} />} title={t('iPhone не сможет подключиться')}>{sync.error}</InfoBar>}
        {/* The iPhone gets the built-in go2rtc's address, never the user's server. */}
        {enabled && app.settings.connectionMode === 'external' && (
          <InfoBar kind="neutral" icon={<VideoOffIcon style={{ color: 'var(--info)', flex: 'none' }} />}>
            {t('Со своим сервером go2rtc iPhone ведёт тренировку, но видео с камеры на нём не показывается.')}
          </InfoBar>
        )}
        <InfoBar kind="neutral" icon={<FirewallIcon style={{ color: 'var(--info)', flex: 'none' }} />} title={t('Брандмауэр Windows')}>
          {t('При первом включении Windows спросит, можно ли go2rtc и Waiting Paws работать в сети. Разрешите доступ в частных сетях — иначе iPhone не увидит этот компьютер.')}
        </InfoBar>
      </Group>

      <Group
        title={t('Разрешённые iPhone')}
        footer={t('Первое подключение каждого iPhone нужно разрешить на этом компьютере. Запись и лог остаются на компьютере. После «Забыть» iPhone снова попросит разрешения.')}
      >
        <Card>
          {sync.pairedDevices.length === 0 && <Row icon={<PhoneIcon />} title={<span className="muted">{t('Пока ни один iPhone не подключался.')}</span>} />}
          {sync.pairedDevices.map((device) => {
            const online = isOnline(device)
            return (
              <Row
                key={device.id}
                icon={<PhoneIcon style={online ? { color: 'var(--success)' } : undefined} />}
                title={device.name}
                description={
                  <span className="row" style={{ gap: 6 }}>
                    {online && <span className="dot dot--live" />}
                    {online ? t('Подключён сейчас') : t('Подключение разрешено')}
                  </span>
                }
              >
                <Button onClick={() => setForgetting(device)}>{t('Забыть')}</Button>
              </Row>
            )
          })}
        </Card>
      </Group>

      <Group title={t('Как подключить iPhone')}>
        <div className="card siphone__steps">
          <ol>
            <li>{t('Включите «Разрешить подключение с iPhone» и разрешите доступ в окне брандмауэра Windows.')}</li>
            <li>{t('Подключите iPhone к той же Wi‑Fi сети, что и этот компьютер.')}</li>
            <li>
              {sync.hostName
                ? t('Откройте Waiting Paws на iPhone: появится карточка «Рядом ПК с Waiting Paws» — «%@». Нажмите «Синхронизировать тренировку с ПК». Тот же выбор есть в настройках приложения на iPhone, в разделе «Синхронизация».', sync.hostName)
                : t('Откройте Waiting Paws на iPhone: появится карточка «Рядом ПК с Waiting Paws» с именем этого компьютера. Нажмите «Синхронизировать тренировку с ПК». Тот же выбор есть в настройках приложения на iPhone, в разделе «Синхронизация».')}
            </li>
            <li>{t('Здесь появится запрос — нажмите «Разрешить». Дальше этот iPhone будет подключаться сам.')}</li>
          </ol>
        </div>
      </Group>

      <Dialog
        open={forgetting !== null}
        onOpenChange={(open) => !open && setForgetting(null)}
        title={t('Забыть «%@»?', forgetting?.name ?? '')}
        description={(forgettingOnline ? t('iPhone отключится.') + ' ' : '') + t('Чтобы снова подключиться, iPhone попросит разрешения на этом компьютере.')}
        hideClose
        width={460}
        footer={
          <>
            <Button onClick={() => setForgetting(null)}>{t('Отмена')}</Button>
            <Button
              variant="danger-solid"
              autoFocus
              onClick={() => {
                if (forgetting) void call('sync.forget', forgetting.id)
                setForgetting(null)
              }}
            >
              {t('Забыть')}
            </Button>
          </>
        }
      />
    </>
  )
}
