import { useEffect, useState, type ReactNode } from 'react'
import { t } from '@shared/i18n'
import logo from '../assets/logo.svg'
import { call, callStrict, useApp } from '../store'
import { Button, Dialog, Spinner } from '../ui/kit'
import { CodeIcon, ExternalLinkIcon, HelpIcon, PrivacyIcon } from '../ui/icons'
import { Group, PaneHeader, Row } from './rows'

const SUPPORT_URL = 'https://github.com/AndrewAndreev/WaitingPaws'

/// О приложении: version, the privacy policy and the open-source licenses, where to ask for help.
export function AboutPane() {
  const app = useApp()
  const [legal, setLegal] = useState<'privacy' | 'licenses' | null>(null)
  return (
    <>
      <PaneHeader title={t('About')} />
      <div className="sabout card">
        <img className="sabout__logo" src={logo} alt="" draggable={false} />
        <div className="col" style={{ gap: 2, minWidth: 0 }}>
          <div className="h2">Waiting Paws</div>
          <div className="muted sabout__text">
            {t('Training for short exits from home: the trainer’s schedule, exit and break timers, a log for the trainer. A Mi Home camera or any go2rtc stream shows your dog while you’re outside.')}
          </div>
          <div className="faint tabular selectable">{t('Version %@', app.version)}</div>
        </div>
      </div>
      <Group footer={t('Waiting Paws collects nothing and sends nothing to the developer: settings, logs and videos stay on your devices.')}>
        <Row icon={<PrivacyIcon />} title={t('Privacy Policy')}>
          <Button onClick={() => setLegal('privacy')}>{t('Open…')}</Button>
        </Row>
        <Row icon={<CodeIcon />} title={t('Open-Source Licenses')} description={t('go2rtc, Electron and the other libraries inside the app.')}>
          <Button onClick={() => setLegal('licenses')}>{t('Open…')}</Button>
        </Row>
        <Row icon={<HelpIcon />} title={t('Support')} description={t('Questions and problem reports — on the project’s GitHub page.')}>
          <Button icon={<ExternalLinkIcon />} onClick={() => void call('shell.openExternal', SUPPORT_URL)}>
            GitHub
          </Button>
        </Row>
      </Group>
      {legal && <LegalDialog kind={legal} onClose={() => setLegal(null)} />}
    </>
  )
}

/// The privacy policy (Markdown: headings and paragraphs) or the licenses (plain text, monospace) over the page.
function LegalDialog({ kind, onClose }: { kind: 'privacy' | 'licenses'; onClose: () => void }) {
  const [text, setText] = useState<string | null>(null)
  useEffect(() => {
    callStrict('app.legal', kind)
      .then((value) => setText(value ?? ''))
      .catch(() => setText(''))
  }, [kind])
  return (
    <Dialog
      open
      onOpenChange={(open) => !open && onClose()}
      title={kind === 'privacy' ? t('Privacy Policy') : t('Open-Source Licenses')}
      width={760}
      height="min(760px, calc(100vh - 80px))"
      bodyClassName={'slegal' + (kind === 'licenses' ? ' slegal--mono' : '')}
      footer={
        <Button variant="primary" autoFocus onClick={onClose}>
          {t('Done')}
        </Button>
      }
    >
      {text === null ? (
        <div className="empty-state">
          <Spinner large />
        </div>
      ) : text.trim() === '' ? (
        <div className="empty-state">{t('The text wasn’t found.')}</div>
      ) : kind === 'privacy' ? (
        <Markdown text={text} />
      ) : (
        <Licenses text={text} />
      )}
    </Dialog>
  )
}

function Markdown({ text }: { text: string }) {
  const blocks = text
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
  return (
    <div className="slegal__doc selectable">
      {blocks.map((line, index) => {
        if (line.startsWith('## ')) return <h3 key={index}>{inline(line.slice(3))}</h3>
        if (line.startsWith('# ')) return <h2 key={index}>{inline(line.slice(2))}</h2>
        if (/^[-*] /.test(line)) return <p key={index} className="slegal__item">• {inline(line.slice(2))}</p>
        return <p key={index}>{inline(line)}</p>
      })}
    </div>
  )
}

/// **bold**, *italic*, `code` and [links](https://…) inside a line.
function inline(text: string): ReactNode[] {
  const parts: ReactNode[] = []
  const pattern = /\*\*([^*]+)\*\*|\*([^*]+)\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)|(https?:\/\/[^\s)]+)/g
  let last = 0
  let match: RegExpExecArray | null
  while ((match = pattern.exec(text))) {
    if (match.index > last) parts.push(text.slice(last, match.index))
    const key = parts.length
    if (match[1]) parts.push(<strong key={key}>{match[1]}</strong>)
    else if (match[2]) parts.push(<em key={key}>{match[2]}</em>)
    else if (match[3]) parts.push(<code key={key}>{match[3]}</code>)
    else {
      const label = match[4] ?? match[6]
      const url = match[5] ?? match[6]
      parts.push(
        <a key={key} href={url} onClick={(event) => (event.preventDefault(), void call('shell.openExternal', url))}>
          {label}
        </a>,
      )
    }
    last = match.index + match[0].length
  }
  if (last < text.length) parts.push(text.slice(last))
  return parts
}

function Licenses({ text }: { text: string }) {
  const paragraphs = text.split(/\n\s*\n/).filter((paragraph) => paragraph.trim() !== '')
  return (
    <div className="slegal__licenses selectable">
      {paragraphs.map((paragraph, index) => (
        <pre key={index} className={paragraph.trimStart().startsWith('====') ? 'slegal__heading' : undefined}>
          {paragraph.replace(/^\n+|\n+$/g, '')}
        </pre>
      ))}
    </div>
  )
}
