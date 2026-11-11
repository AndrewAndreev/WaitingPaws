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

  const go2rtc = app.settings.connectionMode === 'external' ? `${t('own server')} · ${app.settings.serverURL || '—'}` : go2rtcStatusText(app)
  const lines: [string, string][] = [
    [t('Version'), app.version],
    ['go2rtc', go2rtc],
    ['Electron', info?.electron ? `${info.electron} · Chromium ${info.chrome ?? '?'} · Node ${info.node ?? '?'}` : '…'],
    [t('System'), info?.os ?? '…'],
    [t('Log|diagnostics'), info?.logFile ?? '—'],
  ]
  const copy = async () => {
    await call('clipboard.writeText', ['Waiting Paws', ...lines.map(([key, value]) => `${key}: ${value}`)].join('\n'))
    toast({ title: t('Copied'), kind: 'success' }, 2500)
  }

  return (
    <>
      <PaneHeader title={t('Diagnostics')} description={t('When the picture lags or the camera won’t connect.')} />
      <Group>
        <Row icon={<DiagnosticsIcon />} title={t('Show video delay')} description={t('Over the camera: how many seconds the picture trails the camera — network and player buffer.')}>
          <Switch checked={app.settings.showPerformance} label={t('Show video delay')} onChange={(value) => void call('settings.update', { showPerformance: value })} />
        </Row>
        <Row
          icon={<LogIcon />}
          title={t('App Log')}
          description={
            <>
              {t('Useful if the camera won’t connect or a recording stopped unexpectedly.')} {t('go2rtc’s messages are written to it too.')}
              <span className="srow__path mono selectable" title={app.paths.logs}>
                {app.paths.logs}
              </span>
            </>
          }
        >
          <Button onClick={() => void call('shell.showItem', 'logs')}>{t('Show in Explorer')}</Button>
        </Row>
      </Group>
      <Group title={t('App Information')} footer={t('Attach them to a problem report together with the log.')}>
        <Card>
          {lines.map(([key, value]) => (
            <Row key={key} title={key} className="srow--compact">
              <Value mono={key === t('Log|diagnostics')} selectable>
                <span className="ellipsis sdiag__value" title={value}>
                  {value}
                </span>
              </Value>
            </Row>
          ))}
          <Row title="" className="srow--compact">
            <Button icon={<CopyIcon />} onClick={() => void copy()}>
              {t('Copy Information')}
            </Button>
          </Row>
        </Card>
      </Group>
    </>
  )
}
