import { t } from '@shared/i18n'
import type { PendingUpdate } from '@shared/updates'
import logo from '../assets/logo.svg'
import { call, ui, useStore } from '../store'
import { UpdateIcon } from '../ui/icons'
import { Button, Popover, PopoverContent, PopoverTrigger, Tooltip } from '../ui/kit'

/// «Обновление» in the title bar (the app installed from GitHub): a new version waits. A click shows what is new and
/// «Перезапустить» (downloaded) or «Загрузить и установить» (only found), with «При выходе» / «Позже». Not shown in a
/// training or a recording — the Mac's `UpdateGroup` (Design/updates-lab, variant B).
export function UpdateButton() {
  const pending = useStore((store) => store.app?.updates?.pending ?? null)
  const open = useStore((store) => store.showUpdatePopover)
  if (!pending) return null
  return (
    <Popover open={open} onOpenChange={(value) => ui.set({ showUpdatePopover: value })}>
      <Tooltip content={open ? null : t('Waiting Paws %@: what’s new and installing', pending.version)}>
        <PopoverTrigger asChild>
          <button className="tb-btn tb-update">
            <span className="tb-update__icon">
              <UpdateIcon />
              <span className="tb-update__dot" />
            </span>
            {t('Update')}
          </button>
        </PopoverTrigger>
      </Tooltip>
      <PopoverContent width={340} label={`Waiting Paws ${pending.version}`}>
        <UpdatePopover pending={pending} close={() => ui.set({ showUpdatePopover: false })} />
      </PopoverContent>
    </Popover>
  )
}

/// What is new in the waiting version, and when to install it.
function UpdatePopover({ pending, close }: { pending: PendingUpdate; close: () => void }) {
  const downloading = !pending.downloaded && pending.progress !== null
  return (
    <div className="uppop">
      <div className="uppop__head">
        <img className="uppop__icon" src={logo} alt="" draggable={false} />
        <div className="col" style={{ gap: 1, minWidth: 0 }}>
          <div className="uppop__title">Waiting Paws {pending.version}</div>
          <div className="uppop__status">{updateStatus(pending)}</div>
        </div>
      </div>
      {downloading && <ProgressBar value={pending.progress ?? 0} />}
      {pending.notes.length > 0 && (
        <ul className="uppop__notes selectable">
          {pending.notes.map((line) => (
            <li key={line}>{line}</li>
          ))}
        </ul>
      )}
      <Button variant="link" className="uppop__more" onClick={() => void call('shell.openExternal', pending.releasePage)}>
        {t('All Changes…')}
      </Button>
      <div className="uppop__buttons">
        <Button onClick={close}>{pending.downloaded ? t('On Quit') : t('Later')}</Button>
        <Button
          variant="primary"
          autoFocus
          disabled={downloading}
          onClick={() => {
            // Downloaded: the app restarts now. Only found: the popover stays to show the download.
            if (pending.downloaded) close()
            void call('updates.install')
          }}
        >
          {pending.downloaded ? t('Restart') : t('Download and Install')}
        </Button>
      </div>
    </div>
  )
}

/// «Загружена и готова к установке», «Загружается… 40 %» or «Доступна новая версия».
export function updateStatus(pending: PendingUpdate): string {
  if (pending.downloaded) return t('Downloaded and ready to install')
  if (pending.progress !== null) return t('Downloading… %lld%%', pending.progress)
  return t('A new version is available')
}

export function ProgressBar({ value }: { value: number }) {
  return (
    <div className="progressbar" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={value}>
      <div className="progressbar__value" style={{ width: `${Math.max(2, Math.min(100, value))}%` }} />
    </div>
  )
}
