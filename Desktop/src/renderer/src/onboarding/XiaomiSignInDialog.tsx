import { useEffect, useMemo, useRef, useState } from 'react'
import type { XiaomiLoginStep, XiaomiRegion } from '@core/go2rtcClient'
import { t } from '@shared/i18n'
import { call, useApp, useNow } from '../store'
import { CaptchaIcon, LockIcon, PersonCircleIcon, ReloadIcon, WarningIcon } from '../ui/icons'
import { Button, Dialog, Spinner } from '../ui/kit'
import { REGIONS, errorText, regionTitle, useSetupServer } from './catalog'
import { ServerStatusLine, openCameraPicker } from './SetupKit'
import '../styles/onboarding.css'

type Step = { kind: 'account' } | { kind: 'code'; phone: string | null; email: string | null }
type Request = 'login' | 'captcha' | 'code'

/// Xiaomi allows a new code about once a minute.
const RESEND_DELAY = 60_000
const CODE_LENGTH = 6

/// «Войти в Xiaomi…»: e-mail or phone, password and region, then the code Xiaomi sends by SMS or e-mail. A captcha
/// appears only when go2rtc's answer carries one (Xiaomi's anti-bot check after failed attempts, for a new device or
/// before sending the SMS) — as a block inside the current step. Everything goes to go2rtc (`POST /api/xiaomi`); the
/// app never stores the password. After the sign-in the cameras of that account open in the picker (unless
/// `onSignedIn` handles it: the picker's own «Войти в другой аккаунт…»).
export function XiaomiSignInDialog({ onClose, onSignedIn }: { onClose: () => void; onSignedIn?: (accountID: string | null, region: XiaomiRegion) => void }) {
  const app = useApp()
  const setup = useSetupServer()
  const [step, setStep] = useState<Step>({ kind: 'account' })
  const [login, setLogin] = useState('')
  const [password, setPassword] = useState('')
  const [region, setRegion] = useState<XiaomiRegion>(app.settings.xiaomiRegion)
  /// The picture Xiaomi wants solved before going on; null almost always.
  const [captchaImage, setCaptchaImage] = useState<Uint8Array | null>(null)
  /// The login the captcha belongs to: another login needs a fresh attempt.
  const [captchaLogin, setCaptchaLogin] = useState('')
  const [captcha, setCaptcha] = useState('')
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [resendAt, setResendAt] = useState(0)
  const [resent, setResent] = useState(false)
  const accountsBefore = useRef<Set<string>>(new Set())
  const passwordField = useRef<HTMLInputElement>(null)
  const captchaField = useRef<HTMLInputElement>(null)
  const embedded = app.settings.connectionMode === 'embedded'

  // UI checks: `--eval="__wpSetupDemo={signIn:'captcha'}"` shows a step with sample data (nothing is sent).
  useEffect(() => {
    const demo = (window as unknown as { __wpSetupDemo?: { signIn?: 'captcha' | 'verify' } }).__wpSetupDemo?.signIn
    if (!demo) return
    setLogin('anna.k@example.com')
    setPassword('demo-password')
    if (demo === 'captcha') {
      setCaptchaLogin('anna.k@example.com')
      setCaptchaImage(demoCaptcha())
      setCaptcha('x7K')
    } else {
      setStep({ kind: 'code', phone: '+7 *** ***-**-42', email: null })
      setCode('4819')
      setResendAt(Date.now() + 42_000)
    }
  }, [])

  useEffect(() => {
    if (captchaImage && step.kind === 'account' && login !== captchaLogin) setCaptchaImage(null)
  }, [login, captchaImage, captchaLogin, step.kind])

  useEffect(() => {
    if (captchaImage) captchaField.current?.focus()
  }, [captchaImage])

  const captchaURL = useMemo(() => (captchaImage ? URL.createObjectURL(new Blob([captchaImage as Uint8Array<ArrayBuffer>])) : null), [captchaImage])
  useEffect(() => () => (captchaURL ? URL.revokeObjectURL(captchaURL) : undefined), [captchaURL])

  const canSubmit = (() => {
    if (busy || !setup.ready) return false
    if (captchaImage) return captcha.trim() !== ''
    return step.kind === 'account' ? login.trim() !== '' && password !== '' : code.length >= 4
  })()

  const primaryTitle = captchaImage ? t('Продолжить') : step.kind === 'account' ? t('Войти') : t('Подтвердить')
  const busyText = captchaImage ? t('Проверяем…') : step.kind === 'account' ? t('Входим…') : t('Проверяем код…')

  const backToAccount = () => {
    setStep({ kind: 'account' })
    setCaptchaImage(null)
    setCaptcha('')
    setCode('')
    setError(null)
    setTimeout(() => passwordField.current?.focus(), 0)
  }

  /// `typed`: the code as just typed (the state has not caught up with the last digit yet).
  const send = async (request: Request, { resending = false, typed }: { resending?: boolean; typed?: string } = {}) => {
    const client = setup.client
    if (!client) return
    setBusy(true)
    setError(null)
    try {
      let answer: XiaomiLoginStep
      switch (request) {
        case 'login':
          accountsBefore.current = new Set(await client.xiaomiAccounts().catch(() => [] as string[]))
          answer = await client.xiaomiLogin(login.trim(), password)
          break
        case 'captcha':
          answer = await client.xiaomiSubmitCaptcha(captcha.trim())
          break
        case 'code':
          answer = await client.xiaomiSubmitVerify(typed ?? code)
          break
      }
      setCaptcha('')
      switch (answer.kind) {
        case 'success':
          await finish()
          break
        case 'captcha':
          setCaptchaLogin(login)
          setCaptchaImage(answer.image)
          break
        case 'verify':
          setCaptchaImage(null)
          setCode('')
          setStep({ kind: 'code', phone: answer.phone, email: answer.email })
          setResendAt(Date.now() + RESEND_DELAY)
          setResent(resending)
          break
      }
    } catch (caught) {
      if (request === 'code') setCode('')
      setError(errorText(caught))
    } finally {
      setBusy(false)
    }
  }

  const finish = async () => {
    const client = setup.client!
    setPassword('')
    const accounts = await client.xiaomiAccounts().catch(() => [] as string[])
    const fresh = accounts.filter((id) => !accountsBefore.current.has(id))
    let accountID: string | null
    if (fresh[0] ?? (accounts.length === 1 ? accounts[0] : undefined)) {
      accountID = fresh[0] ?? accounts[0]
    } else if (accounts.length > 0) {
      // Signed in again to one of the accounts go2rtc already had.
      accountID = null
    } else {
      backToAccount()
      setError(t('Вход прошёл, но go2rtc не вернул аккаунт. Попробуйте ещё раз.'))
      return
    }
    await call('settings.update', accountID ? { xiaomiAccountID: accountID, xiaomiRegion: region } : { xiaomiRegion: region })
    window.wp.log(`[setup] signed in to Xiaomi account ${accountID ?? '(one of the known)'}`)
    if (onSignedIn) onSignedIn(accountID, region)
    else openCameraPicker({ accountID, region })
  }

  const submit = () => {
    if (!canSubmit) return
    void send(captchaImage ? 'captcha' : step.kind === 'account' ? 'login' : 'code')
  }

  const passwordNote = (
    <div className="signin__note">
      <LockIcon />
      <span>
        {embedded
          ? t('Пароль уходит только встроенному go2rtc, Waiting Paws его не хранит. Токен входа go2rtc держит у себя, на этом компьютере.')
          : t('Пароль уходит только вашему серверу go2rtc, Waiting Paws его не хранит. Токен входа остаётся на сервере.')}
      </span>
    </div>
  )

  const errorLine = error && (
    <div className="setup-error selectable" role="alert">
      <WarningIcon />
      <span>{error}</span>
    </div>
  )

  const subtitle =
    step.kind === 'account'
      ? t('После входа go2rtc получит список камер Mi Home.')
      : step.phone
        ? t('Xiaomi отправил код на %@.', step.phone)
        : step.email
          ? t('Xiaomi отправил код на %@.', step.email)
          : t('Xiaomi отправил код по SMS или на почту.')

  return (
    <Dialog
      open
      onOpenChange={(open) => !open && onClose()}
      title={step.kind === 'account' ? t('Вход в аккаунт Xiaomi') : t('Введите код')}
      description={subtitle}
      width={500}
      footer={
        <>
          {busy && (
            <span className="row muted signin__busy">
              <Spinner />
              {busyText}
            </span>
          )}
          <span className="spacer" />
          <Button onClick={onClose}>{t('Отменить')}</Button>
          <Button variant="primary" disabled={!canSubmit} onClick={submit}>
            {primaryTitle}
          </Button>
        </>
      }
    >
      <form
        className="signin"
        onSubmit={(event) => {
          event.preventDefault()
          submit()
        }}
      >
        <fieldset className="signin__fields" disabled={busy}>
          {!setup.ready && (
            <div className="signin__server">
              <ServerStatusLine />
            </div>
          )}
          {step.kind === 'account' ? (
            <>
              <label className="field">
                <span className="field__label">{t('E-mail или телефон')}</span>
                <input
                  className="input"
                  value={login}
                  autoFocus
                  autoComplete="username"
                  spellCheck={false}
                  placeholder={t('name@example.com или +7…')}
                  onChange={(event) => setLogin(event.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' && !password) {
                      event.preventDefault()
                      passwordField.current?.focus()
                    }
                  }}
                />
              </label>
              <label className="field">
                <span className="field__label">{t('Пароль')}</span>
                <input
                  ref={passwordField}
                  className="input"
                  type="password"
                  value={password}
                  autoComplete="current-password"
                  placeholder={t('Пароль Mi Home')}
                  onChange={(event) => setPassword(event.target.value)}
                />
              </label>
              <label className="field">
                <span className="field__label">{t('Регион аккаунта')}</span>
                <select className="select" value={region} onChange={(event) => setRegion(event.target.value as XiaomiRegion)}>
                  {REGIONS.map((item) => (
                    <option key={item} value={item}>
                      {regionTitle(item)}
                    </option>
                  ))}
                </select>
              </label>
              {passwordNote}
              {!captchaImage && errorLine}
            </>
          ) : (
            <>
              <div className="signin__account">
                <PersonCircleIcon className="signin__account-icon" />
                <div className="grow">
                  <div className="ellipsis">{login || t('Аккаунт Xiaomi')}</div>
                  <div className="muted signin__account-region">{t('Регион: %@', regionTitle(region))}</div>
                </div>
                <Button variant="subtle" size="sm" onClick={backToAccount}>
                  {t('Изменить…')}
                </Button>
              </div>
              <CodeField
                code={code}
                disabled={captchaImage !== null || busy}
                onChange={setCode}
                onComplete={(value) => {
                  if (!busy && setup.ready) void send('code', { typed: value })
                }}
              />
              <div className="signin__resend">
                <span className="muted">{resent ? t('Новый код отправлен.') : t('Код приходит в течение минуты.')}</span>
                <span className="spacer" />
                <ResendButton
                  resendAt={resendAt}
                  disabled={busy || password === '' || captchaImage !== null}
                  onResend={() => {
                    setResent(false)
                    void send('login', { resending: true })
                  }}
                />
              </div>
              {passwordNote}
              {!captchaImage && errorLine}
            </>
          )}
          {captchaImage && captchaURL && (
            <div className="signin__captcha">
              <div className="signin__captcha-title">
                <CaptchaIcon />
                {t('Xiaomi попросил подтвердить, что вы не робот')}
              </div>
              <div className="row signin__captcha-row">
                <div className="signin__captcha-image" aria-label={t('Капча')}>
                  <img src={captchaURL} alt={t('Капча')} draggable={false} />
                </div>
                <Button variant="subtle" size="sm" icon={<ReloadIcon />} disabled={busy || password === ''} onClick={() => void send('login')}>
                  {t('Другая картинка')}
                </Button>
              </div>
              <label className="field">
                <span className="field__label">{t('Символы с картинки')}</span>
                <input
                  ref={captchaField}
                  className="input"
                  value={captcha}
                  spellCheck={false}
                  autoComplete="off"
                  placeholder={t('Как на картинке')}
                  onChange={(event) => setCaptcha(event.target.value)}
                />
              </label>
              {errorLine}
            </div>
          )}
        </fieldset>
        {/* Enter submits from any field. */}
        <button type="submit" hidden tabIndex={-1} />
      </form>
    </Dialog>
  )
}

/// «Отправить ещё раз»: the login again makes Xiaomi send a fresh code (the password is kept until success).
function ResendButton({ resendAt, disabled, onResend }: { resendAt: number; disabled: boolean; onResend: () => void }) {
  const now = useNow(1000)
  const left = Math.ceil((resendAt - now) / 1000)
  return (
    <Button variant="link" className="tabular" disabled={left > 0 || disabled} onClick={onResend}>
      {left > 0 ? t('Отправить ещё раз через %lld с', left) : t('Отправить ещё раз')}
    </Button>
  )
}

/// Six-digit code entry: one box per digit, a real (transparent) input on top takes the typing and pasting.
function CodeField({
  code,
  disabled,
  onChange,
  onComplete,
}: {
  code: string
  disabled: boolean
  onChange: (code: string) => void
  onComplete: (code: string) => void
}) {
  const [focused, setFocused] = useState(false)
  const input = useRef<HTMLInputElement>(null)
  // Back to typing once a check is over (a wrong code is cleared).
  useEffect(() => {
    if (!disabled) input.current?.focus()
  }, [disabled])
  return (
    <div className={'code-field' + (disabled ? ' code-field--disabled' : '')}>
      <div className="code-field__boxes" aria-hidden="true">
        {Array.from({ length: CODE_LENGTH }, (_, index) => {
          const current = focused && index === Math.min(code.length, CODE_LENGTH - 1) && code.length < CODE_LENGTH
          return (
            <span key={index} className="code-field__cell">
              <span className={'code-field__box tabular' + (current ? ' code-field__box--current' : '')}>{code[index] ?? ''}</span>
              {index === CODE_LENGTH / 2 - 1 && <span className="code-field__dash">–</span>}
            </span>
          )
        })}
      </div>
      <input
        ref={input}
        className="code-field__input"
        value={code}
        inputMode="numeric"
        autoComplete="one-time-code"
        autoFocus
        disabled={disabled}
        aria-label={t('Код подтверждения')}
        maxLength={CODE_LENGTH + 4}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        onChange={(event) => {
          const digits = event.target.value.replace(/\D/g, '').slice(0, CODE_LENGTH)
          onChange(digits)
          if (digits.length === CODE_LENGTH && digits !== code) onComplete(digits)
        }}
      />
    </div>
  )
}

/// A Xiaomi-style captcha drawn on a canvas, as PNG bytes (goes through the same path as the real picture).
function demoCaptcha(): Uint8Array {
  const canvas = document.createElement('canvas')
  canvas.width = 420
  canvas.height = 128
  const context = canvas.getContext('2d')!
  const gradient = context.createLinearGradient(0, 0, canvas.width, canvas.height)
  gradient.addColorStop(0, '#f5f2e6')
  gradient.addColorStop(1, '#e0edf2')
  context.fillStyle = gradient
  context.fillRect(0, 0, canvas.width, canvas.height)
  let seed = 11
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647
  for (let i = 0; i < 700; i++) {
    context.fillStyle = `rgba(40,50,110,${0.1 + random() * 0.3})`
    context.fillRect(random() * canvas.width, random() * canvas.height, 2, 2)
  }
  const inks = ['#1f338c', '#73192e', '#1a6138', '#59287f', '#804d14']
  ;[...'x7Kp4'].forEach((char, index) => {
    context.save()
    context.translate(70 + index * 66, 64 + (random() - 0.5) * 20)
    context.rotate((random() - 0.5) * 0.8)
    context.font = `bold ${64 + random() * 16}px Georgia, serif`
    context.fillStyle = inks[index % inks.length]
    context.textAlign = 'center'
    context.textBaseline = 'middle'
    context.fillText(char, 0, 0)
    context.restore()
  })
  context.strokeStyle = 'rgba(31,51,140,0.85)'
  context.lineWidth = 4
  context.beginPath()
  for (let x = 0; x <= canvas.width; x += 6) context.lineTo(x, 70 + Math.sin(x / 40) * 18)
  context.stroke()
  const base64 = canvas.toDataURL('image/png').split(',')[1]
  return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0))
}
