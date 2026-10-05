import { useEffect, useState } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { SessionLogFormatter, ExitResult, type TrainingRecord } from '@core/sessionLog'
import type { RecordingClip } from '@shared/api'
import { call, toast, ui, useApp, useStore } from '../store'
import { formatTime } from '../model'
import { CheckIcon, ClipIcon, CopyIcon, ErrorIcon, FolderIcon, HistoryIcon, PhoneIcon } from '../ui/icons'
import { Button, Dialog } from '../ui/kit'
import { PlanReviewDialog } from '../plan/PlanReviewDialog'
import { CameraPickerDialog } from '../onboarding/CameraPickerDialog'
import { XiaomiSignInDialog } from '../onboarding/XiaomiSignInDialog'
import { formatBytes } from '../format'

/// Dialogs that can open over any page: finishing, errors, the summary after a training, a saved clip, an iPhone
/// asking to pair, the schedule review, the camera picker and the Xiaomi sign-in.
/// Button order follows Windows: the action first (accent = Enter), Cancel last (Esc).
export function GlobalDialogs() {
  const app = useApp()
  const confirmFinish = useStore((store) => store.confirmFinish)
  const reviewingPlan = useStore((store) => store.reviewingPlan)
  const showCameraPicker = useStore((store) => store.showCameraPicker)
  const showXiaomiSignIn = useStore((store) => store.showXiaomiSignIn)
  const request = app.sync.pairingRequests[0]
  return (
    <>
      <Dialog
        open={confirmFinish && app.session !== null}
        onOpenChange={(open) => ui.set({ confirmFinish: open })}
        title={t('Завершить тренировку?')}
        description={t('Запись остановится, лог и видео сохранятся в истории.')}
        hideClose
        width={460}
        footer={
          <>
            <Button
              variant="primary"
              autoFocus
              onClick={() => {
                ui.set({ confirmFinish: false })
                void call('session.command', 'finish')
              }}
            >
              {t('Завершить и сохранить')}
            </Button>
            <Button
              variant="danger"
              onClick={() => {
                ui.set({ confirmFinish: false })
                void call('session.abandon')
              }}
            >
              {t('Отменить без сохранения')}
            </Button>
            <span className="spacer" />
            <Button onClick={() => ui.set({ confirmFinish: false })}>{t('Продолжить')}</Button>
          </>
        }
      />

      <Dialog
        open={app.errorMessage !== null}
        onOpenChange={(open) => !open && void call('state.dismissError')}
        icon={<ErrorIcon style={{ color: 'var(--danger)', width: 24, height: 24, marginTop: 2 }} />}
        title={t('Ошибка')}
        description={app.errorMessage ?? ''}
        width={440}
        hideClose
        footer={
          <Button variant="primary" autoFocus onClick={() => void call('state.dismissError')}>
            {t('Ок')}
          </Button>
        }
      />

      {request && (
        <Dialog
          open
          onOpenChange={(open) => !open && void call('sync.respond', request.id, false)}
          icon={<PhoneIcon style={{ color: 'var(--info)', width: 24, height: 24, marginTop: 2 }} />}
          title={t('«%@» хочет подключиться', request.deviceName)}
          description={t('iPhone увидит камеру и сможет вести тренировку на этом компьютере. Разрешайте только своим устройствам.')}
          hideClose
          width={460}
          footer={
            <>
              <Button variant="primary" onClick={() => void call('sync.respond', request.id, true)}>
                {t('Разрешить')}
              </Button>
              <Button onClick={() => void call('sync.respond', request.id, false)}>{t('Отклонить')}</Button>
            </>
          }
        />
      )}

      {app.lastRecord && !app.session && <SummaryDialog record={app.lastRecord as TrainingRecord} />}
      {app.lastClip && !app.session && !app.lastRecord && <ClipSavedDialog clip={app.lastClip} />}
      {reviewingPlan && app.pendingPlan && !app.session && <PlanReviewDialog />}
      {showCameraPicker && <CameraPickerDialog onClose={() => ui.set({ showCameraPicker: false })} />}
      {showXiaomiSignIn && <XiaomiSignInDialog onClose={() => ui.set({ showXiaomiSignIn: false })} />}
    </>
  )
}

function SummaryDialog({ record }: { record: TrainingRecord }) {
  const app = useApp()
  const [copied, setCopied] = useState(false)
  const log = SessionLogFormatter.text(record)
  const longest = Math.max(0, ...record.results.filter((result) => !result.falseStart).map((result) => ExitResult.awayDuration(result)))
  const completed = record.results.filter((result) => !result.falseStart).length
  const falseStarts = record.results.length - completed
  const duration = (record.finishedAt - record.startedAt) / 1000
  const close = () => void call('state.dismissLastRecord')
  const video = record.recordingFileName
  const finalizing = video ? app.finalizing.includes(video) : false
  return (
    <Dialog
      open
      onOpenChange={(open) => !open && close()}
      icon={<CheckIcon style={{ color: 'var(--success)', width: 28, height: 28, marginTop: 2 }} />}
      title={t('Тренировка завершена')}
      description={`${record.plan.title} · ${formatTime(record.startedAt)}–${formatTime(record.finishedAt)} (${DurationText.short(Math.max(60, Math.round(duration / 60) * 60))})`}
      width={620}
      footer={
        <>
          <Button variant="primary" autoFocus onClick={close}>
            {t('Готово')}
          </Button>
          <Button
            icon={<HistoryIcon />}
            onClick={() => {
              ui.set({ route: 'history', historySelection: { kind: 'record', id: record.id } })
              close()
            }}
          >
            {t('История')}
          </Button>
        </>
      }
    >
      <div className="col" style={{ gap: 16 }}>
        <div className="summary-stats">
          <SummaryStat value={t('%lld из %lld', completed, record.plan.exits.length)} label={t('выходов')} />
          <SummaryStat value={String(falseStarts)} label={t('фальстартов')} warn={falseStarts > 0} />
          <SummaryStat value={DurationText.clock(longest)} label={t('дольше всего за дверью')} />
        </div>
        <PlanFactChart record={record} />
        <div className="col" style={{ gap: 6 }}>
          <div className="row">
            <span className="h3">{t('Лог для тренера')}</span>
            <span className="spacer" />
            <Button
              size="sm"
              icon={copied ? <CheckIcon /> : <CopyIcon />}
              onClick={() => {
                void call('clipboard.writeText', log)
                setCopied(true)
              }}
            >
              {copied ? t('Скопировано') : t('Скопировать')}
            </Button>
          </div>
          <pre className="log-box selectable">{log}</pre>
        </div>
        {video && (
          <div className="row file-row">
            <ClipIcon style={{ color: 'var(--text-secondary)' }} />
            <div className="grow">
              <div className="ellipsis">{video}</div>
              <div className="faint" style={{ fontSize: 12 }}>
                {DurationText.clock(duration)}
                {finalizing ? ' · ' + t('готовится…') : ''}
              </div>
            </div>
            <Button size="sm" icon={<FolderIcon />} onClick={() => void call('shell.showItem', 'recording', video)}>
              {t('Показать в проводнике')}
            </Button>
          </div>
        )}
      </div>
    </Dialog>
  )
}

function SummaryStat({ value, label, warn }: { value: string; label: string; warn?: boolean }) {
  return (
    <div className="summary-stat">
      <div className="summary-stat__value tabular" style={warn ? { color: 'var(--warning)' } : undefined}>
        {value}
      </div>
      <div className="summary-stat__label">{label}</div>
    </div>
  )
}

/// Plan (light bars) and what happened (green, false starts orange) per exit, minutes on the Y axis.
export function PlanFactChart({ record }: { record: TrainingRecord }) {
  const exits = record.plan.exits
  if (!exits.length) return null
  const values = [...exits.map((exit) => exit.duration), ...record.results.map((result) => ExitResult.awayDuration(result))]
  const max = Math.max(30, ...values)
  const height = 120
  return (
    <div className="col" style={{ gap: 6 }}>
      <div className="row">
        <span className="h3">{t('План и факт')}</span>
        <span className="spacer" />
        <span className="legend">
          <span className="legend__swatch seg--exit" style={{ opacity: 0.45 }} />
          {t('план')}
        </span>
        <span className="legend">
          <span className="legend__swatch seg--outside" />
          {t('за дверью')}
        </span>
        <span className="legend">
          <span className="legend__swatch seg--false" />
          {t('фальстарт')}
        </span>
      </div>
      <div className="bars" style={{ height }}>
        <div className="bars__axis tabular">
          <span>{DurationText.clock(max)}</span>
          <span>{DurationText.clock(max / 2)}</span>
          <span>0:00</span>
        </div>
        {exits.map((exit) => {
          const attempts = record.results.filter((result) => result.number === exit.number)
          return (
            <div className="bars__group" key={exit.id}>
              <div className="bars__plot">
                <div className="bars__plan" style={{ height: `${(exit.duration / max) * 100}%` }} />
                <div className="bars__facts">
                  {attempts.map((result) => (
                    <div key={result.id} className={'bars__fact' + (result.falseStart ? ' bars__fact--false' : '')} style={{ height: `${(ExitResult.awayDuration(result) / max) * 100}%` }} title={DurationText.clock(ExitResult.awayDuration(result))} />
                  ))}
                </div>
              </div>
              <span className="bars__label tabular">{exit.number}</span>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function ClipSavedDialog({ clip }: { clip: RecordingClip }) {
  const app = useApp()
  const close = () => void call('state.dismissLastClip')
  const finalizing = app.finalizing.includes(clip.fileName)
  const [size, setSize] = useState(clip.size)
  useEffect(() => {
    if (!finalizing) void call('history.list').then((list) => setSize(list?.clips.find((item) => item.fileName === clip.fileName)?.size ?? clip.size))
  }, [finalizing, clip])
  return (
    <Dialog
      open
      onOpenChange={(open) => !open && close()}
      icon={<ClipIcon style={{ color: 'var(--danger)', width: 24, height: 24, marginTop: 2 }} />}
      title={t('Запись сохранена')}
      description={t('Видео без тренировки — в истории.')}
      width={480}
      footer={
        <>
          <Button variant="primary" autoFocus onClick={close}>
            {t('Готово')}
          </Button>
          <Button
            icon={<HistoryIcon />}
            onClick={() => {
              ui.set({ route: 'history', historySelection: { kind: 'clip', id: clip.fileName } })
              close()
            }}
          >
            {t('История')}
          </Button>
        </>
      }
    >
      <div className="file-row file-row--stacked">
        <div className="row">
          <ClipIcon style={{ color: 'var(--text-secondary)', flex: 'none' }} />
          <div className="grow">
            <div className="ellipsis">{clip.fileName}</div>
            <div className="faint" style={{ fontSize: 12 }}>
              {finalizing ? t('готовится…') : formatBytes(size)}
            </div>
          </div>
        </div>
        <div className="row">
        <Button
          size="sm"
          icon={<CopyIcon />}
          disabled={finalizing}
          onClick={() => {
            void call('shell.copyFile', clip.fileName).then(() => toast({ title: t('Видео скопировано — вставьте его в мессенджер или папку'), kind: 'success' }))
          }}
        >
          {t('Копировать файл')}
        </Button>
        <Button size="sm" icon={<FolderIcon />} onClick={() => void call('shell.showItem', 'recording', clip.fileName)}>
          {t('Показать в проводнике')}
        </Button>
        </div>
      </div>
    </Dialog>
  )
}
