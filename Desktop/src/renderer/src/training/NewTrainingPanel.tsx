import { useEffect, useState } from 'react'
import { t, plural } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { TrainingPlan } from '@core/models'
import { PlanParser } from '@core/planParser'
import { call, ui, useApp, useStore } from '../store'
import { formatShortDate, formatTime, isConfigured } from '../model'
import { lastPlan, pasteSchedule, repeatLast, startPending } from '../actions'
import { PasteIcon, PlayFilledIcon, RecordIcon, RepeatIcon, StandIcon } from '../ui/icons'
import { Button, Checkbox } from '../ui/kit'

/// Right panel before a session: the pasted plan with «Начать», the paste zone, the previous plan, record only.
export function NewTrainingPanel() {
  const app = useApp()
  const plan = app.pendingPlan
  return (
    <div className="panel-scroll">
      <div className="new-training">
        <h2 className="h2">{t('Новая тренировка')}</h2>
        {plan ? (
          <>
            <TodayCard plan={plan} />
            <PasteZone compact />
          </>
        ) : (
          <PasteZone compact={false} />
        )}
        <LastPlan />
        <hr className="divider" />
        <Button block size="lg" icon={<RecordIcon />} shortcut="Ctrl+R" disabled={!isConfigured(app.settings)} onClick={() => void call('recording.start')}>
          {t('Только запись')}
        </Button>
        <p className="caption muted">{t('Видео без расписания и лога — например, посмотреть, что собака делает одна.')}</p>
      </div>
    </div>
  )
}

function TodayCard({ plan }: { plan: TrainingPlan }) {
  const app = useApp()
  return (
    <div className="card card--padded today">
      <div className="row">
        <span className="section-title">{t('СЕГОДНЯ')}</span>
        <span className="spacer" />
        <button className="btn btn--link" onClick={() => ui.set({ reviewingPlan: true })} title={t('Как прочитан текст тренера')}>
          {t('Показать разбор')}
        </button>
      </div>
      <div>
        <div className="today__title">{plan.title}</div>
        <div className="muted tabular" style={{ fontSize: 13 }}>
          {summary(plan)}
        </div>
      </div>
      <Button variant="primary" size="lg" block icon={<PlayFilledIcon />} shortcut="Ctrl+Enter" onClick={() => void startPending()}>
        {t('Начать тренировку')}
      </Button>
      <div className="row">
        {isConfigured(app.settings) && (
          <Checkbox checked={app.settings.autoRecord} onChange={(value) => void call('settings.update', { autoRecord: value })}>
            {t('Записывать видео')}
          </Checkbox>
        )}
        <span className="spacer" />
        <button className="btn btn--link muted" style={{ color: 'var(--text-secondary)' }} onClick={() => void call('pending.set', null)}>
          {t('Убрать')}
        </button>
      </div>
    </div>
  )
}

function summary(plan: TrainingPlan): string {
  const parts: string[] = []
  if (plan.trainers) parts.push(plan.trainers)
  parts.push(plural(plan.exits.length, ['%d выход', '%d выхода', '%d выходов'], ['%d exit', '%d exits']))
  const estimated = TrainingPlan.estimatedDuration(plan)
  parts.push(`≈ ${DurationText.short(Math.round(estimated / 60) * 60)}`)
  parts.push(t('конец ≈ %@', formatTime(Date.now() + estimated * 1000)))
  return parts.join(' · ')
}

/// Dashed drop zone: paste the trainer's message (Ctrl+Shift+V, or Ctrl+V anywhere on the page) or drop text on it.
function PasteZone({ compact }: { compact: boolean }) {
  const [targeted, setTargeted] = useState(false)
  const onDrop = (event: React.DragEvent) => {
    event.preventDefault()
    setTargeted(false)
    const text = event.dataTransfer.getData('text/plain')
    if (text && TrainingPlan.isValid(PlanParser.parse(text))) void pasteSchedule(text)
  }
  const handlers = {
    onDragOver: (event: React.DragEvent) => {
      event.preventDefault()
      setTargeted(true)
    },
    onDragLeave: () => setTargeted(false),
    onDrop,
  }
  if (compact) {
    return (
      <div className={'paste-zone paste-zone--compact' + (targeted ? ' paste-zone--targeted' : '')} {...handlers}>
        <PasteIcon style={{ color: 'var(--accent-text)' }} />
        <span className="grow">{t('Другое расписание')}</span>
        <Button size="sm" icon={<PasteIcon />} shortcut="Ctrl+Shift+V" onClick={() => void pasteSchedule()}>
          {t('Вставить')}
        </Button>
      </div>
    )
  }
  return (
    <div className={'paste-zone' + (targeted ? ' paste-zone--targeted' : '')} {...handlers}>
      <PasteIcon style={{ width: 28, height: 28, color: 'var(--accent-text)' }} />
      <div className="h3">{t('Вставьте расписание от тренера')}</div>
      <div className="muted" style={{ fontSize: 13, textAlign: 'center' }}>
        {t('Текст из Telegram или WhatsApp — выходы, перерывы и заметки разберутся сами.')}
      </div>
      <Button variant="primary" size="lg" icon={<PasteIcon />} shortcut="Ctrl+Shift+V" onClick={() => void pasteSchedule()}>
        {t('Вставить')}
      </Button>
    </div>
  )
}

function LastPlan() {
  const revision = useStore((store) => store.app?.historyRevision)
  const [plan, setPlan] = useState<TrainingPlan | null>(null)
  useEffect(() => {
    void lastPlan().then(setPlan)
  }, [revision])
  if (!plan) return null
  return (
    <div className="col" style={{ gap: 8 }}>
      <div className="row">
        <span className="section-title">{t('Прошлое расписание')}</span>
        <span className="spacer" />
        {plan.date !== null && <span className="faint" style={{ fontSize: 12 }}>{formatShortDate(plan.date)}</span>}
      </div>
      <span className="h3 ellipsis">{plan.title}</span>
      <ExitChips plan={plan} />
      <span className="faint" style={{ fontSize: 12 }}>
        {t('%lld вых. · ≈ %@ · перерывы %@', plan.exits.length, DurationText.short(Math.round(TrainingPlan.estimatedDuration(plan) / 60) * 60), DurationText.short(plan.defaultBreak))}
      </span>
      <div className="row">
        <Button size="sm" icon={<RepeatIcon />} shortcut="Ctrl+Shift+R" onClick={() => void repeatLast()}>
          {t('Повторить прошлое')}
        </Button>
      </div>
    </div>
  )
}

/// The exits of a plan as small duration chips.
export function ExitChips({ plan }: { plan: TrainingPlan }) {
  return (
    <div className="chips">
      {plan.exits.map((exit) => (
        <span className="chip tabular" key={exit.id}>
          {DurationText.compact(exit.duration)}
          {exit.untilStanding && <StandIcon style={{ width: 11, height: 11 }} />}
        </span>
      ))}
    </div>
  )
}
