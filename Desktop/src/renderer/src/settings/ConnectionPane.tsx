import { useEffect, useState } from 'react'
import { t } from '@shared/i18n'
import type { ConnectionMode, Settings } from '@shared/settings'
import { Go2RTCClient, Go2RTCError, Go2RTCServer } from '@core/go2rtcClient'
import { bridgeFetch } from '../platform/bridge'
import { call, ui, useApp } from '../store'
import { isRecording } from '../model'
import { Button, Spinner } from '../ui/kit'
import { DocumentIcon, FailedFilledIcon, GlobeIcon, ReloadIcon, ServerIcon, SuccessFilledIcon } from '../ui/icons'
import { Card, Group, PaneHeader, RadioRow, Row, Value } from './rows'
import { go2rtcStatusText } from './cameraText'

type Check = { kind: 'idle' } | { kind: 'checking' } | { kind: 'ok'; version: string } | { kind: 'failed'; message: string; detail: string }

/// Подключение: the bundled go2rtc (status, address, restart) or the user's own server (address, login, check).
export function ConnectionPane() {
  const app = useApp()
  const mode = app.settings.connectionMode
  // Another server under a training or a recording (one waiting for the camera too) would cut its video off.
  const locked = app.session !== null || isRecording(app)
  const setMode = (next: ConnectionMode) => {
    if (next === mode || locked) return
    // Without an address the app is not set up and falls back to the first-launch screen: the server form switches
    // the mode once an address is checked and saved.
    if (next === 'external' && !app.settings.serverURL.trim()) return ui.set({ showServerSetup: true })
    void call('settings.update', { connectionMode: next })
  }
  return (
    <>
      <PaneHeader title={t('Connection')} description={t('Where go2rtc runs — the server that pulls video from the Xiaomi camera.')} />
      <Group footer={locked ? t('The server can’t be changed during a training or recording.') : undefined}>
        <div role="radiogroup" className="sgroup__items" aria-label={t('Mode')}>
          <RadioRow
            checked={mode === 'embedded'}
            disabled={locked}
            onSelect={() => setMode('embedded')}
            title={t('Built-in go2rtc')}
            description={t('go2rtc runs inside the app; the camera must be on the same Wi‑Fi network. Video and recording work while the app is open.')}
          />
          <RadioRow
            checked={mode === 'external'}
            disabled={locked}
            onSelect={() => setMode('external')}
            title={t('Own go2rtc Server')}
            description={t('A separate go2rtc server on the network: for round-the-clock recording or access from outside your home.')}
          />
        </div>
      </Group>
      {mode === 'embedded' ? <EmbeddedGroup /> : <ServerGroup locked={locked} />}
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
    <Group title={t('Built-in go2rtc')}>
      <Row
        icon={<ServerIcon />}
        title={t('Status')}
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
          {t('Restart')}
        </Button>
      </Row>
      <Row
        icon={<GlobeIcon />}
        title={t('Address')}
        description={app.go2rtc.lanEnabled ? t('Also open on the local network — for iPhone, with a password.') : t('This computer only.')}
      >
        <Value mono selectable>
          127.0.0.1:{app.go2rtc.port}
        </Value>
      </Row>
      <Row
        icon={<DocumentIcon />}
        title={t('go2rtc.yaml File')}
        description={
          <>
            {t('Streams and the Xiaomi sign-in. Don’t share it: it contains tokens.')}
            {configPath && (
              <span className="srow__path mono selectable" title={configPath}>
                {configPath}
              </span>
            )}
          </>
        }
      >
        <Button onClick={() => void call('shell.showItem', 'go2rtcConfig')}>{t('Show in Explorer')}</Button>
      </Row>
    </Group>
  )
}

/// Address, login and password of the user's server; saved when a field is left (Enter too), checked on demand.
function ServerGroup({ locked }: { locked: boolean }) {
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
    // Text that isn't an address (a cleared field, one being retyped) stays in the field only: saved, it would leave
    // the app without a server and drop it to the first-launch screen.
    if (url.trim() !== saved.serverURL && Go2RTCServer.parse(url)) changes.serverURL = url.trim()
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
      setCheck({ kind: 'failed', message: t('Invalid address'), detail: '' })
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
      setCheck({ kind: 'failed', message: unreachable ? t('%@ is not responding', new URL(server.baseURL).host) : detail, detail })
    }
  }

  const onKey = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Enter') void commit()
  }

  return (
    <Group title={t('Own Server')}>
      <Card>
        <Row
          icon={<ServerIcon />}
          title={t('go2rtc Server')}
          description={t('Its network address, plus the username and password if go2rtc has them set.')}
          below={
            <div className="sform">
              <label className="field">
                <span className="field__label">{t('Address')}</span>
                <input
                  className="input"
                  value={url}
                  placeholder="http://192.168.1.10:1984"
                  spellCheck={false}
                  disabled={locked}
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
                  <span className="field__label">{t('Username')}</span>
                  <input className="input" value={username} placeholder={t('Optional')} spellCheck={false} autoComplete="off" disabled={locked} onChange={(event) => setUsername(event.target.value)} onBlur={() => void commit()} onKeyDown={onKey} />
                </label>
                <label className="field">
                  <span className="field__label">{t('Password')}</span>
                  <input
                    className="input"
                    type="password"
                    value={password}
                    placeholder={t('Optional')}
                    autoComplete="new-password"
                    disabled={locked}
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
          <Button disabled={locked || check.kind === 'checking' || !parsed} onClick={() => void runCheck()}>
            {t('Check')}
          </Button>
        </Row>
      </Card>
    </Group>
  )
}

function CheckResult({ check }: { check: Check }) {
  switch (check.kind) {
    case 'idle':
      return <span className="muted sconn__result">{t('Requires version 1.9.11 or later with the xiaomi module.')}</span>
    case 'checking':
      return (
        <span className="row muted sconn__result">
          <Spinner />
          {t('Checking…')}
        </span>
      )
    case 'ok':
      return (
        <span className="row sconn__result" style={{ color: 'var(--success)' }}>
          <SuccessFilledIcon />
          {check.version ? t('go2rtc %@ is responding', check.version) : t('Server is responding')}
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
