import { useEffect, useState, type ReactNode } from 'react'
import { Popover, Tooltip as RTooltip } from 'radix-ui'
import { t } from '@shared/i18n'
import { DurationText } from '@core/durationText'
import { AddIcon, SubtractIcon } from '../ui/icons'
import { Button, Checkbox } from '../ui/kit'
import { PlanFormat, stepDuration, withMinutes, withSeconds } from './planEdit'

export interface DurationEditorProps {
  /// Seconds; null means «как у всех» (only with `defaultValue`).
  value: number | null
  onChange: (value: number | null) => void
  title: string
  presets: readonly number[]
  /// The common value an exit follows when `value` is null.
  defaultValue?: number
  /// Step of the stepper below a minute (30 s from a minute up).
  step?: number
  tint: 'exit' | 'break'
  /// How the 0 preset reads («сразу» for a condition); «0 с» without it.
  zeroLabel?: string
}

/// A duration chip/cell that opens the editor in a popover (the Mac's `MacDurationEditor`, the iPhone's wheels):
/// minutes and seconds with a stepper, ready-made values, and «Как у всех — 2 мин» where a default exists.
export function DurationPopover({
  children,
  side = 'bottom',
  tooltip,
  onOpenChange,
  ...editor
}: DurationEditorProps & { children: ReactNode; side?: 'top' | 'bottom'; tooltip?: ReactNode; onOpenChange?: (open: boolean) => void }) {
  const [open, setOpenState] = useState(false)
  // Told when it opens and closes (the live timeline applies a typed value once, on closing).
  const setOpen = (value: boolean) => {
    setOpenState(value)
    onOpenChange?.(value)
  }
  const trigger = <Popover.Trigger asChild>{children}</Popover.Trigger>
  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      {tooltip ? (
        // The kit's Tooltip cannot wrap another trigger; the same look, composed by hand.
        <RTooltip.Root open={open ? false : undefined}>
          <RTooltip.Trigger asChild>{trigger}</RTooltip.Trigger>
          <RTooltip.Portal>
            <RTooltip.Content className="tooltip" side="bottom" sideOffset={6} collisionPadding={8}>
              {tooltip}
            </RTooltip.Content>
          </RTooltip.Portal>
        </RTooltip.Root>
      ) : (
        trigger
      )}
      <Popover.Portal>
        <Popover.Content className="popover duration-editor" side={side} align="start" sideOffset={4} collisionPadding={12}>
          <DurationEditor {...editor} onClose={() => setOpen(false)} />
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  )
}

export function DurationEditor({ value, onChange, title, presets, defaultValue, step = 5, tint, zeroLabel, onClose }: DurationEditorProps & { onClose: () => void }) {
  const total = Math.max(0, Math.round(value ?? defaultValue ?? 0))
  const set = (seconds: number) => onChange(Math.max(0, seconds))
  return (
    <div className="col" style={{ gap: 12 }}>
      <div className="h3">{title}</div>
      <div className="row duration-editor__fields">
        <NumberField label={t('Minutes')} value={Math.floor(total / 60)} max={120} autoFocus onValue={(minutes) => set(withMinutes(total, minutes))} onSubmit={onClose} />
        <span className="muted">{t('min')}</span>
        <NumberField label={t('Seconds')} value={total % 60} max={59} onValue={(seconds) => set(withSeconds(total, seconds))} onSubmit={onClose} />
        <span className="muted">{t('s')}</span>
        <span className="spacer" />
        <div className="duration-editor__stepper" role="group" aria-label={t('Edit')}>
          <Button size="sm" iconOnly icon={<SubtractIcon />} aria-label={t('Less')} disabled={total <= 0} onClick={() => set(stepDuration(total, -1, step))} />
          <Button size="sm" iconOnly icon={<AddIcon />} aria-label={t('More|increase')} onClick={() => set(stepDuration(total, 1, step))} />
        </div>
      </div>
      <div className="duration-editor__presets">
        {presets.map((preset) => {
          const selected = value !== null && total === preset
          return (
            <button
              key={preset}
              type="button"
              className={'duration-chip tabular' + (selected ? ` duration-chip--${tint}` : '')}
              aria-pressed={selected}
              onClick={() => {
                onChange(preset)
                onClose()
              }}
            >
              {preset === 0 && zeroLabel ? zeroLabel : PlanFormat.cell(preset)}
            </button>
          )
        })}
      </div>
      {defaultValue !== undefined && (
        <>
          <hr className="divider" />
          <Checkbox
            checked={value === null}
            onChange={(checked) => {
              if (checked) {
                onChange(null)
                onClose()
              } else {
                onChange(defaultValue)
              }
            }}
          >
            {t('Default — %@', DurationText.short(defaultValue))}
          </Checkbox>
        </>
      )}
    </div>
  )
}

/// Whole number 0…max: typing applies at once, ↑/↓ change it by one, Enter closes the editor.
function NumberField({ label, value, max, autoFocus, onValue, onSubmit }: { label: string; value: number; max: number; autoFocus?: boolean; onValue: (value: number) => void; onSubmit: () => void }) {
  const [text, setText] = useState(String(value))
  const [focused, setFocused] = useState(false)
  useEffect(() => {
    // While typing, an empty field stays empty (the value follows the digits as they come).
    if (!focused || (text !== '' && Number(text) !== value)) setText(String(value))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value, focused])
  return (
    <input
      className="input duration-editor__field tabular"
      inputMode="numeric"
      aria-label={label}
      value={text}
      autoFocus={autoFocus}
      onFocus={(event) => {
        setFocused(true)
        event.currentTarget.select()
      }}
      onBlur={() => {
        setFocused(false)
        setText(String(value))
      }}
      onChange={(event) => {
        const digits = event.target.value.replace(/\D/g, '').slice(0, 3)
        setText(digits)
        if (digits !== '') onValue(Math.min(max, Number(digits)))
      }}
      onKeyDown={(event) => {
        if (event.key === 'Enter') {
          event.preventDefault()
          onSubmit()
        } else if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
          event.preventDefault()
          const next = Math.min(max, Math.max(0, value + (event.key === 'ArrowUp' ? 1 : -1)))
          setText(String(next))
          onValue(next)
        }
      }}
    />
  )
}
