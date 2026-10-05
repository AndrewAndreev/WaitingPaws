import { useEffect, useState } from 'react'
import { t } from '@shared/i18n'
import type { ConnectionMode, Settings } from '@shared/settings'
import { Go2RTCClient, Go2RTCError, Go2RTCServer } from '@core/go2rtcClient'
import { bridgeFetch } from '../platform/bridge'
import { call, useApp } from '../store'
import { Button, Spinner } from '../ui/kit'
import { DocumentIcon, FailedFilledIcon, GlobeIcon, ReloadIcon, ServerIcon, SuccessFilledIcon } from '../ui/icons'
import { Card, Group, PaneHeader, RadioRow, Row, Value } from './rows'
import { go2rtcStatusText } from './cameraText'

type Check = { kind: 'idle' } | { kind: 'checking' } | { kind: 'ok'; version: string } | { kind: 'failed'; message: string; detail: string }

/// Подключение: the bundled go2rtc (status, address, restart) or the user's own server (address, login, check).
export function ConnectionPane() {
  const app = useApp()
  const mode = app.settings.connectionMode
  const setMode = (next: ConnectionMode) => {
    if (next !== mode) void call('settings.update', { connectionMode: next })
  }
  return (
    <>
      <PaneHeader title={t('Подключение')} description={t('Где работает go2rtc — сервер, который забирает видео с камеры Xiaomi.')} />
      <Group>
        <div role="radiogroup" className="sgroup__items" aria-label={t('Режим')}>
          <RadioRow
            checked={mode === 'embedded'}
            onSelect={() => setMode('embedded')}
            title={t('Встроенный go2rtc')}
            description={t('go2rtc работает внутри приложения, камера должна быть в той же Wi‑Fi сети. Видео и запись идут, пока приложение открыто.')}
          />
          <RadioRow
            checked={mode === 'external'}
            onSelect={() => setMode('external')}
            title={t('Свой сервер go2rtc')}
            description={t('Отдельный сервер go2rtc в сети: подходит, если нужна постоянная запись или доступ не из дома.')}
          />
        </div>
      </Group>
      {mode === 'embedded' ? <EmbeddedGroup /> : <ServerGroup />}
    </>
  )
}

function EmbeddedGroup() {
  const app = useApp()
  const status = app.go2rtc.status
  const [configPath, setConfigPath] = useState<string | null>(null)
  const [restarting, setRestarting] = useState(false)
  useEffect(() => {
    void call('app.diagnostics').then((info) => setConfigPath((info as { go2rtcConfig?: string } | undefined)?.go2rtcConfig ?? null))
  }, [])
  const statusText = go2rtcStatusText(app)
  const restart = async () => {
    setRestarting(true)
    await call('go2rtc.restart')
    setRestarting(false)
  }
  return (
    <Group title={t('Встроенный go2rtc')}>
      <Row
        icon={<ServerIcon />}
        title={t('Состояние')}
        description={
          <span className="row sconn__status" style={{ gap: 6 }}>
            {status === 'starting' || restarting ? (
              <Spinner />
            ) : (
              <span className={'dot' + (status === 'running' ? ' dot--live' : '')} style={status === 'failed' || status === 'unavailable' ? { background: 'var(--danger)' } : undefined} />
            )}
            <span className="selectable">{statusText}</span>
          </span>
        }
      >
        <Button icon={<ReloadIcon />} disabled={restarting || status === 'starting'} onClick={() => void restart()}>
          {t('Перезапустить')}
        </Button>
      </Row>
      <Row
        icon={<GlobeIcon />}
        title={t('Адрес')}
        description={app.go2rtc.lanEnabled ? t('Открыт и в локальной сети — для iPhone, с паролем.') : t('Только для этого компьютера.')}
      >
        <Value mono selectable>
          127.0.0.1:{app.go2rtc.port}
        </Value>
      </Row>
      <Row
        icon={<DocumentIcon />}
        title={t('Файл go2rtc.yaml')}
        description={
          <>
            {t('Потоки и вход в Xiaomi. Не пересылайте его: в нём токены.')}
            {configPath && (
              <span className="srow__path mono selectable" title={configPath}>
                {configPath}
              </span>
            )}
          </>
        }
      >
        <Button onClick={() => void call('shell.showItem', 'go2rtcConfig')}>{t('Показать в проводнике')}</Button>
      </Row>
    </Group>
  )
}

/// Address, login and password of the user's server; saved when a field is left (Enter too), checked on demand.
function ServerGroup() {
  const app = useApp()
  const saved = app.settings
  const [url, setURL] = useState(saved.serverURL)
  const [username, setUsername] = useState(saved.serverUsername)
  // The backend only says whether a password is set (a placeholder of dots); typing replaces it.
  const [password, setPassword] = useState(saved.serverPassword)
  const [check, setCheck] = useState<Check>({ kind: 'idle' })

  useEffect(() => setURL(saved.serverURL), [saved.serverURL])
  useEffect(() => setUsername(saved.serverUsername), [saved.serverUsername])
  useEffect(() => setPassword(saved.serverPassword), [saved.serverPassword])

  const patch = (): Partial<Settings> => {
    const changes: Partial<Settings> = {}
    if (url.trim() !== saved.serverURL) changes.serverURL = url.trim()
    if (username !== saved.serverUsername) changes.serverUsername = username
    if (password !== saved.serverPassword) changes.serverPassword = password
    return changes
  }
  const commit = async () => {
    const changes = patch()
    if (Object.keys(changes).length) await call('settings.update', changes)
  }

  const parsed = Go2RTCServer.parse(url)
  const runCheck = async () => {
    // What is in the fields now; the password field holds only a placeholder while the saved one is untouched.
    const keptPassword = saved.serverPassword !== '' && password === saved.serverPassword
    const server = parsed ? (keptPassword ? Go2RTCServer.make(parsed) : Go2RTCServer.make(parsed, username, password)) : null
    // Saved as well (a field is left when the button is clicked anyway): changes apply at once.
    await commit()
    if (!server) {
      setCheck({ kind: 'failed', message: t('Некорректный адрес'), detail: '' })
      return
    }
    setCheck({ kind: 'checking' })
    try {
      // With the placeholder the backend adds the saved login and password (it is the saved server by now).
      const version = await new Go2RTCClient(server, { fetch: bridgeFetch }).version()
      setCheck({ kind: 'ok', version })
    } catch (error) {
      const detail = String((error as Error)?.message ?? error).replace(/^Error invoking remote method '[^']+': (Error: )?/, '')
      // A refused connection or a timeout says no more than this; the raw text stays in the tooltip.
      const unreachable = error instanceof Go2RTCError && error.kind === 'network'
      setCheck({ kind: 'failed', message: unreachable ? t('%@ не отвечает', new URL(server.baseURL).host) : detail, detail })
    }
  }

  const onKey = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Enter') void commit()
  }

  return (
    <Group title={t('Свой сервер')}>
      <Card>
        <Row
          icon={<ServerIcon />}
          title={t('Сервер go2rtc')}
          description={t('Адрес в сети, логин и пароль, если они заданы в go2rtc.')}
          below={
            <div className="sform">
              <label className="field">
                <span className="field__label">{t('Адрес')}</span>
                <input
                  className="input"
                  value={url}
                  placeholder="http://192.168.1.10:1984"
                  spellCheck={false}
                  onChange={(event) => {
                    setURL(event.target.value)
                    setCheck({ kind: 'idle' })
                  }}
                  onBlur={() => void commit()}
                  onKeyDown={onKey}
                />
              </label>
              <div className="sform__pair">
                <label className="field">
                  <span className="field__label">{t('Логин')}</span>
                  <input className="input" value={username} placeholder={t('Необязательно')} spellCheck={false} autoComplete="off" onChange={(event) => setUsername(event.target.value)} onBlur={() => void commit()} onKeyDown={onKey} />
                </label>
                <label className="field">
                  <span className="field__label">{t('Пароль')}</span>
                  <input
                    className="input"
                    type="password"
                    value={password}
                    placeholder={t('Необязательно')}
                    autoComplete="new-password"
                    onFocus={(event) => event.target.select()}
                    onChange={(event) => setPassword(event.target.value)}
                    onBlur={() => void commit()}
                    onKeyDown={onKey}
                  />
                </label>
              </div>
            </div>
          }
        />
        <Row title={<CheckResult check={check} />}>
          <Button disabled={check.kind === 'checking' || !parsed} onClick={() => void runCheck()}>
            {t('Проверить')}
          </Button>
        </Row>
      </Card>
    </Group>
  )
}

function CheckResult({ check }: { check: Check }) {
  switch (check.kind) {
    case 'idle':
      return <span className="muted sconn__result">{t('Нужна версия 1.9.11 или новее с модулем xiaomi.')}</span>
    case 'checking':
      return (
        <span className="row muted sconn__result">
          <Spinner />
          {t('Проверяем…')}
        </span>
      )
    case 'ok':
      return (
        <span className="row sconn__result" style={{ color: 'var(--success)' }}>
          <SuccessFilledIcon />
          {check.version ? t('go2rtc %@ отвечает', check.version) : t('Сервер отвечает')}
        </span>
      )
    case 'failed':
      return (
        <span className="row sconn__result" style={{ color: 'var(--danger)' }} title={check.detail || check.message}>
          <FailedFilledIcon style={{ flex: 'none' }} />
          <span className="sconn__message selectable">{check.message}</span>
        </span>
      )
  }
}
