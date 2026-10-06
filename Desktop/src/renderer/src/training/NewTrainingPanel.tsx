import { useState } from 'react'
import { t, plural } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { TrainingPlan } from '@core/models'
import { PlanParser } from '@core/planParser'
import { call, ui, useApp } from '../store'
import { formatTime, isConfigured } from '../model'
import { pasteSchedule, startPending, startTitle } from '../actions'
import { PasteIcon, PlayFilledIcon, RecordIcon } from '../ui/icons'
import { Button, Checkbox } from '../ui/kit'

/// Right panel before a session: the pasted plan with «Начать», the paste zone, record only.
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
        {startTitle(app)}
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
