import { useEffect, useState } from 'react'
import { t } from '@shared/i18n'
import { call, toast, useApp } from '../store'
import { Button, Switch } from '../ui/kit'
import { CopyIcon, DiagnosticsIcon, LogIcon } from '../ui/icons'
import { Card, Group, PaneHeader, Row, Value } from './rows'
import { go2rtcStatusText } from './cameraText'

interface DiagnosticsInfo {
  logFile?: string | null
  go2rtcBinary?: string
  go2rtcConfig?: string
  electron?: string
  chrome?: string
  node?: string
  os?: string
}

/// Диагностика: the delay over the picture, the app log (go2rtc writes into it too) and versions for a bug report.
export function DiagnosticsPane() {
  const app = useApp()
  const [info, setInfo] = useState<DiagnosticsInfo | null>(null)
  useEffect(() => {
    void call('app.diagnostics').then((value) => setInfo((value as DiagnosticsInfo | undefined) ?? {}))
  }, [])

  const go2rtc = app.settings.connectionMode === 'external' ? `${t('свой сервер')} · ${app.settings.serverURL || '—'}` : go2rtcStatusText(app)
  const lines: [string, string][] = [
    [t('Версия'), app.version],
    ['go2rtc', go2rtc],
    ['Electron', info?.electron ? `${info.electron} · Chromium ${info.chrome ?? '?'} · Node ${info.node ?? '?'}` : '…'],
    [t('Система'), info?.os ?? '…'],
    [t('Журнал'), info?.logFile ?? '—'],
  ]
  const copy = async () => {
    await call('clipboard.writeText', ['Waiting Paws', ...lines.map(([key, value]) => `${key}: ${value}`)].join('\n'))
    toast({ title: t('Скопировано'), kind: 'success' }, 2500)
  }

  return (
    <>
      <PaneHeader title={t('Диагностика')} description={t('Если картинка отстаёт или камера не подключается.')} />
      <Group>
        <Row icon={<DiagnosticsIcon />} title={t('Показывать задержку видео')} description={t('Над камерой: на сколько секунд картинка отстаёт от камеры — сеть и буфер плеера.')}>
          <Switch checked={app.settings.showPerformance} label={t('Показывать задержку видео')} onChange={(value) => void call('settings.update', { showPerformance: value })} />
        </Row>
        <Row
          icon={<LogIcon />}
          title={t('Журнал приложения')}
          description={
            <>
              {t('Пригодится, если камера не подключается или запись оборвалась.')} {t('Сообщения go2rtc тоже пишутся в него.')}
              <span className="srow__path mono selectable" title={app.paths.logs}>
                {app.paths.logs}
              </span>
            </>
          }
        >
          <Button onClick={() => void call('shell.showItem', 'logs')}>{t('Показать в проводнике')}</Button>
        </Row>
      </Group>
      <Group title={t('Сведения о приложении')} footer={t('Приложите их к сообщению о проблеме вместе с журналом.')}>
        <Card>
          {lines.map(([key, value]) => (
            <Row key={key} title={key} className="srow--compact">
              <Value mono={key === t('Журнал')} selectable>
                <span className="ellipsis sdiag__value" title={value}>
                  {value}
                </span>
              </Value>
            </Row>
          ))}
          <Row title="" className="srow--compact">
            <Button icon={<CopyIcon />} onClick={() => void copy()}>
              {t('Скопировать сведения')}
            </Button>
          </Row>
        </Card>
      </Group>
    </>
  )
}
