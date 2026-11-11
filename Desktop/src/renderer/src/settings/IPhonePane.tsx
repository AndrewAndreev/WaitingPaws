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
      <PaneHeader title="iPhone" description={t('An iPhone on the same network shows this computer’s camera and runs the training.')} />
      <Group>
        <Row icon={<PhoneLaptopIcon />} title={t('Allow connections from iPhone')} description={t('Waiting Paws on an iPhone on the same Wi‑Fi network can see this computer.')}>
          <Switch checked={enabled} label={t('Allow connections from iPhone')} onChange={(value) => void call('sync.setEnabled', value)} />
        </Row>
        {sync.hostName && (
          <Row icon={<DesktopIcon />} title={t('Name on iPhone')} description={t('The iPhone app shows this computer under this name.')}>
            <Value selectable>{sync.hostName}</Value>
          </Row>
        )}
        {sync.error && enabled && <InfoBar kind="warning" icon={<WarningIcon style={{ color: 'var(--warning)', flex: 'none' }} />} title={t('iPhone can’t connect')}>{sync.error}</InfoBar>}
        {/* The iPhone gets the built-in go2rtc's address, never the user's server. */}
        {enabled && app.settings.connectionMode === 'external' && (
          <InfoBar kind="neutral" icon={<VideoOffIcon style={{ color: 'var(--info)', flex: 'none' }} />}>
            {t('With your own go2rtc server, the iPhone runs the training but doesn’t show the camera.')}
          </InfoBar>
        )}
        <InfoBar kind="neutral" icon={<FirewallIcon style={{ color: 'var(--info)', flex: 'none' }} />} title={t('Windows Firewall')}>
          {t('The first time you turn this on, Windows asks whether go2rtc and Waiting Paws may use the network. Allow access on private networks, or the iPhone won’t see this computer.')}
        </InfoBar>
      </Group>

      <Group
        title={t('Allowed iPhones')}
        footer={t('Each iPhone’s first connection must be allowed on this computer. The recording and log stay on the computer. After “Forget”, the iPhone will ask for permission again.')}
      >
        <Card>
          {sync.pairedDevices.length === 0 && <Row icon={<PhoneIcon />} title={<span className="muted">{t('No iPhone has connected yet.')}</span>} />}
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
                    {online ? t('Connected now') : t('Connection allowed')}
                  </span>
                }
              >
                <Button onClick={() => setForgetting(device)}>{t('Forget')}</Button>
              </Row>
            )
          })}
        </Card>
      </Group>

      <Group title={t('How to Connect an iPhone')}>
        <div className="card siphone__steps">
          <ol>
            <li>{t('Turn on “Allow connections from iPhone” and allow access when Windows Firewall asks.')}</li>
            <li>{t('Connect the iPhone to the same Wi‑Fi network as this computer.')}</li>
            <li>
              {sync.hostName
                ? t('Open Waiting Paws on the iPhone: a “PC with Waiting Paws Nearby” card appears — “%@”. Tap “Sync Training with PC”. The same choice is in the iPhone app’s settings, in the “Sync” section.', sync.hostName)
                : t('Open Waiting Paws on the iPhone: a “PC with Waiting Paws Nearby” card appears with this computer’s name. Tap “Sync Training with PC”. The same choice is in the iPhone app’s settings, in the “Sync” section.')}
            </li>
            <li>{t('A request appears here — click “Allow”. After that, this iPhone connects by itself.')}</li>
          </ol>
        </div>
      </Group>

      <Dialog
        open={forgetting !== null}
        onOpenChange={(open) => !open && setForgetting(null)}
        title={t('Forget “%@”?', forgetting?.name ?? '')}
        description={(forgettingOnline ? t('The iPhone will disconnect.') + ' ' : '') + t('To connect again, the iPhone will ask for permission on this computer.')}
        hideClose
        width={460}
        footer={
          <>
            <Button onClick={() => setForgetting(null)}>{t('Cancel')}</Button>
            <Button
              variant="danger-solid"
              autoFocus
              onClick={() => {
                if (forgetting) void call('sync.forget', forgetting.id)
                setForgetting(null)
              }}
            >
              {t('Forget')}
            </Button>
          </>
        }
      />
    </>
  )
}
