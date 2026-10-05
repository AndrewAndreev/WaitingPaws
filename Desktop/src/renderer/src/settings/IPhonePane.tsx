import { t } from '@shared/i18n'
import { call, useApp } from '../store'
import { Button, InfoBar, Switch } from '../ui/kit'
import { DesktopIcon, FirewallIcon, PhoneIcon, PhoneLaptopIcon, WarningIcon } from '../ui/icons'
import { Card, Group, PaneHeader, Row, Value } from './rows'

/// iPhone: let the iPhone app find this computer, watch its camera and drive its training; allowed devices.
export function IPhonePane() {
  const app = useApp()
  const sync = app.sync
  const enabled = app.settings.shareWithIPhone
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
            const online = sync.connectedDevices.includes(device.name)
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
                <Button onClick={() => void call('sync.forget', device.id)}>{t('Забыть')}</Button>
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
                ? t('Откройте Waiting Paws на iPhone: появится карточка «Рядом Mac с Waiting Paws» — «%@». Нажмите «Синхронизировать тренировку с Mac». Тот же выбор есть в настройках приложения на iPhone, в разделе «Mac».', sync.hostName)
                : t('Откройте Waiting Paws на iPhone: появится карточка «Рядом Mac с Waiting Paws» с именем этого компьютера. Нажмите «Синхронизировать тренировку с Mac». Тот же выбор есть в настройках приложения на iPhone, в разделе «Mac».')}
            </li>
            <li>{t('Здесь появится запрос — нажмите «Разрешить». Дальше этот iPhone будет подключаться сам.')}</li>
          </ol>
        </div>
      </Group>
    </>
  )
}
