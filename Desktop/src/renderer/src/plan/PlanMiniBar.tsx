import { TrainingPlan } from '@core/models'

/// The whole plan as one proportional bar: exits pink, breaks blue (own breaks brighter).
export function PlanMiniBar({ plan, className }: { plan: TrainingPlan; className?: string }) {
  return (
    <div className={'plan-minibar ' + (className ?? '')} aria-hidden>
      {plan.exits.flatMap((exit, index) => {
        const parts = [<span key={exit.id} className="plan-minibar__exit" style={{ flexGrow: exit.duration }} />]
        if (index < plan.exits.length - 1) {
          parts.push(
            <span
              key={exit.id + ':break'}
              className={'plan-minibar__break' + (exit.breakAfter !== null ? ' plan-minibar__break--own' : '')}
              style={{ flexGrow: TrainingPlan.breakAfter(plan, index) }}
            />,
          )
        }
        return parts
      })}
    </div>
  )
}
