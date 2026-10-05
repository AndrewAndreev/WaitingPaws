import type { ReactNode } from 'react'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { call, ui } from '../store'
import { formatTime } from '../model'
import { CheckIcon, FalseStartIcon, FinishIcon, NoteIcon, OutsideIcon, StandIcon, WalkIcon } from '../ui/icons'
import { Button, Kbd } from '../ui/kit'
import type { LiveSession } from './live'

/// Right panel during a session: the big readout and the four steps with their keys.
export function Readout({ live }: { live: LiveSession }) {
  const exit = live.currentExit
  return (
    <div className="readout">
      <div className={`readout__card tint-${live.tint}`}>
        <div className="readout__header">
          <span>{live.isBreak ? t('ПЕРЕРЫВ') : t('ВЫХОД %lld', exit?.number ?? 0)}</span>
          {live.session.attempt > 1 && !live.isBreak && <span className="readout__attempt">{t('ПОПЫТКА %lld', live.session.attempt)}</span>}
          <span className="spacer" />
          <span className={`phase-badge tint-${live.tint}`}>{live.overdue ? t('Сверх плана') : live.phaseName}</span>
        </div>
        <div className={'readout__timer tabular' + (live.isLeaving || live.isReady ? ' readout__timer--neutral' : '')}>{live.timerText}</div>
        <div className="readout__detail tabular">{live.detail}</div>
        <div className="progress">
          <div className="progress__bar" style={{ width: `${Math.min(100, Math.max(0, (live.isAway || live.isBreak ? live.progress : 0) * 100))}%` }} />
        </div>
        <div className="readout__stats">
          <Stat value={t('%lld из %lld', live.completedExits, live.plan.exits.length)} label={t('выходов')} />
          <Stat value={String(live.falseStarts)} label={t('фальстартов')} warn={live.falseStarts > 0} />
          <Stat value={DurationText.clock((live.now - live.session.startedAt) / 1000)} label={t('идёт тренировка')} />
          <Stat value={`≈ ${formatTime(live.eta)}`} label={t('конец по плану')} />
        </div>
      </div>

      <Transport live={live} />

      {exit?.untilStanding && !live.isBreak && (
        <div className="readout__note">
          <StandIcon style={{ color: 'var(--info)' }} />
          <span>{t('Выход «или до вставания»: собака встала — сразу возвращайтесь.')}</span>
        </div>
      )}
      {exit?.note && !live.isBreak && (
        <div className="readout__note">
          <NoteIcon />
          <span>{exit.note}</span>
        </div>
      )}
      <div className="spacer" />
      <div className="readout__footer">
        <Button icon={<FinishIcon />} shortcut="Ctrl+E" onClick={() => ui.set({ confirmFinish: true })}>
          {t('Завершить')}
        </Button>
        <span className="spacer" />
        <span className="faint" style={{ fontSize: 12 }}>
          <Kbd keys="Пробел" /> {t('следующий шаг')}
        </span>
      </div>
    </div>
  )
}

function Stat({ value, label, warn }: { value: string; label: string; warn?: boolean }) {
  return (
    <div className="stat">
      <div className="stat__value tabular" style={warn ? { color: 'var(--warning)' } : undefined}>
        {value}
      </div>
      <div className="stat__label">{label}</div>
    </div>
  )
}

function Transport({ live }: { live: LiveSession }) {
  const phase = live.phase
  const canStart = phase.kind === 'ready' || (phase.kind === 'breakTime' && phase.nextExitIndex !== null)
  const canDoor = phase.kind === 'leaving'
  const canReturn = phase.kind === 'leaving' || phase.kind === 'away'
  const primary = canDoor ? 1 : live.isAway ? 2 : canStart ? 0 : -1
  const startTitle =
    phase.kind === 'breakTime' && phase.nextExitIndex !== null
      ? t('Начать выход %lld', live.plan.exits[phase.nextExitIndex].number)
      : phase.kind === 'ready'
        ? t('Начать выход %lld', live.currentExit?.number ?? 1)
        : t('Начать выход')
  const finishInstead = phase.kind === 'breakTime' && phase.nextExitIndex === null
  return (
    <div className="transport">
      {finishInstead ? (
        <Step icon={<FinishIcon />} title={t('Завершить')} keys="Пробел" prominent enabled onClick={() => void call('session.command', 'finish')} />
      ) : (
        <Step icon={<WalkIcon />} title={startTitle} keys={primary === 0 ? 'Пробел' : undefined} prominent={primary === 0} enabled={canStart} onClick={() => void call('session.command', 'startExit')} />
      )}
      <Step icon={<OutsideIcon />} title={t('За дверью')} keys={primary === 1 ? 'Пробел' : undefined} prominent={primary === 1} enabled={canDoor} onClick={() => void call('session.command', 'markBehindDoor')} />
      <Step icon={<CheckIcon />} title={t('Вернулись')} keys={primary === 2 ? 'Пробел' : undefined} prominent={primary === 2} tone="done" enabled={canReturn} onClick={() => void call('session.command', 'endExit')} />
      <Step icon={<FalseStartIcon />} title={t('Фальстарт')} keys={canReturn ? 'Backspace' : undefined} enabled={canReturn} tone="warn" onClick={() => void call('session.command', 'resetExit')} />
    </div>
  )
}

function Step({ icon, title, keys, enabled, prominent, tone, onClick }: { icon: ReactNode; title: string; keys?: string; enabled: boolean; prominent?: boolean; tone?: 'done' | 'warn'; onClick: () => void }) {
  return (
    <button className={'step' + (prominent ? ' step--primary' : '') + (prominent && tone === 'done' ? ' step--done' : '') + (tone === 'warn' ? ' step--warn' : '')} disabled={!enabled} onClick={onClick} title={keys ? `${title} (${t(keys)})` : title}>
      {icon}
      <span className="step__text">
        <span className="ellipsis">{title}</span>
        {keys && <span className="step__key">{t(keys)}</span>}
      </span>
    </button>
  )
}
