import { useEffect, useState } from 'react'
import { Go2RTCClient, Go2RTCServer } from '@core/go2rtcClient'
import { t } from '@shared/i18n'
import { call, useApp } from '../store'
import { bridgeFetch } from '../platform/bridge'
import { ErrorIcon, SuccessFilledIcon } from '../ui/icons'
import { Button, Dialog, Spinner, Tooltip } from '../ui/kit'
import { errorText, hostText, isUnreachable } from './catalog'
import { openCameraPicker } from './SetupKit'
import '../styles/onboarding.css'

/// What the settings show instead of a saved server password.
const PASSWORD_MARKER = '••••••'

type Check = { kind: 'idle' } | { kind: 'checking' } | { kind: 'ok'; version: string } | { kind: 'failed'; message: string; detail: string }

/// «Свой сервер go2rtc…»: address, login and password of a go2rtc on the network, checked before switching to it.
/// Once saved, the camera picker opens with that server's streams (unless `onSaved` handles it).
export function ServerSetupDialog({ onClose, onSaved }: { onClose: () => void; onSaved?: () => void }) {
  const app = useApp()
  const settings = app.settings
  const [urlText, setURLText] = useState(settings.serverURL)
  const [username, setUsername] = useState(settings.serverUsername)
  const [password, setPassword] = useState(settings.serverPassword)
  const [check, setCheck] = useState<Check>({ kind: 'idle' })
  const [saving, setSaving] = useState(false)
  const parsed = Go2RTCServer.parse(urlText)

  useEffect(() => setCheck({ kind: 'idle' }), [urlText, username, password])

  /// The server as typed. The saved password never reaches the page: for the saved server the backend adds it.
  const server = (): Go2RTCServer | null => {
    if (!parsed) return null
    if (password === PASSWORD_MARKER) {
      const saved = app.server && sameHost(app.server.baseURL, parsed) && settings.connectionMode === 'external'
      return saved ? Go2RTCServer.make(parsed) : Go2RTCServer.make(parsed, username, '')
    }
    return Go2RTCServer.make(parsed, username, password)
  }

  const runCheck = async (): Promise<Check> => {
    const target = server()
    if (!target) return { kind: 'idle' }
    setCheck({ kind: 'checking' })
    let result: Check
    try {
      result = { kind: 'ok', version: await new Go2RTCClient(target, { fetch: bridgeFetch, timeoutMs: 10_000 }).version() }
    } catch (error) {
      const detail = errorText(error)
      result = { kind: 'failed', message: isUnreachable(error) ? t('%@ is not responding', hostText(target.baseURL)) : detail, detail }
    }
    setCheck(result)
    return result
  }

  /// Checks (unless just checked), saves and switches the app to this server.
  const connect = async () => {
    if (!parsed || saving) return
    const result = check.kind === 'ok' ? check : await runCheck()
    if (result.kind !== 'ok') return
    setSaving(true)
    await call('settings.update', { connectionMode: 'external', serverURL: urlText.trim(), serverUsername: username, serverPassword: password })
    window.wp.log(`[setup] own go2rtc server ${urlText.trim()}`)
    setSaving(false)
    onClose()
    if (onSaved) onSaved()
    else openCameraPicker()
  }

  const backToEmbedded = async () => {
    await call('settings.update', { connectionMode: 'embedded' })
    onClose()
  }

  const busy = check.kind === 'checking' || saving
  return (
    <Dialog
      open
      onOpenChange={(open) => !open && onClose()}
      title={t('Own go2rtc Server')}
      description={t('go2rtc on a computer or NAS on your network instead of the built-in one.')}
      width={520}
      footer={
        <>
          {settings.connectionMode === 'external' && app.go2rtc.status !== 'unavailable' && (
            <Tooltip content={t('go2rtc inside the app, without a separate server')}>
              <Button onClick={() => void backToEmbedded()}>{t('Switch Back to Built-in')}</Button>
            </Tooltip>
          )}
          <span className="spacer" />
          <Button onClick={onClose}>{t('Cancel|verb')}</Button>
          <Button variant="primary" disabled={busy || !parsed} onClick={() => void connect()}>
            {t('Connect')}
          </Button>
        </>
      }
    >
      <form
        className="col server-setup"
        onSubmit={(event) => {
          event.preventDefault()
          void connect()
        }}
      >
        <label className="field">
          <span className="field__label">{t('Address')}</span>
          <input
            className="input"
            value={urlText}
            autoFocus
            spellCheck={false}
            placeholder="http://192.168.1.10:1984"
            onChange={(event) => setURLText(event.target.value)}
          />
        </label>
        <div className="server-setup__pair">
          <label className="field grow">
            <span className="field__label">{t('Username')}</span>
            <input
              className="input"
              value={username}
              spellCheck={false}
              autoComplete="off"
              placeholder={t('Optional')}
              onChange={(event) => setUsername(event.target.value)}
            />
          </label>
          <label className="field grow">
            <span className="field__label">{t('Password')}</span>
            <input
              className="input"
              type="password"
              value={password}
              autoComplete="new-password"
              placeholder={t('Optional')}
              onFocus={(event) => password === PASSWORD_MARKER && event.target.select()}
              onChange={(event) => setPassword(event.target.value)}
            />
          </label>
        </div>
        <div className="server-setup__check">
          <CheckResult check={check} />
          <span className="spacer" />
          <Button disabled={busy || !parsed} onClick={() => void runCheck()}>
            {t('Check Connection')}
          </Button>
        </div>
        <div className="field__hint">
          {t('Requires version 1.9.11 or later with the xiaomi module. The server password is stored encrypted on this computer.')}
        </div>
        <button type="submit" hidden tabIndex={-1} />
      </form>
    </Dialog>
  )
}

function CheckResult({ check }: { check: Check }) {
  switch (check.kind) {
    case 'idle':
      return null
    case 'checking':
      return (
        <span className="row muted">
          <Spinner />
          {t('Checking…')}
        </span>
      )
    case 'ok':
      return (
        <span className="server-setup__ok">
          <SuccessFilledIcon />
          {check.version ? t('go2rtc %@ is responding', check.version) : t('Server is responding')}
        </span>
      )
    case 'failed':
      return (
        <Tooltip content={check.detail}>
          <span className="server-setup__failed">
            <ErrorIcon />
            <span className="ellipsis">{check.message}</span>
          </span>
        </Tooltip>
      )
  }
}

function sameHost(a: string, b: string): boolean {
  try {
    return new URL(a).host === new URL(b).host
  } catch {
    return false
  }
}
