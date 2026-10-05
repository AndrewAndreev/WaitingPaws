// Windows 11 Settings building blocks: a pane title, groups with a small heading, and setting cards — icon, title and
// description on the left, the control on the right. Every change applies at once (no Save button).
import type { ReactNode } from 'react'

export function PaneHeader({ title, description }: { title: string; description?: ReactNode }) {
  return (
    <header className="spane__header">
      <h1 className="h1">{title}</h1>
      {description && <p className="spane__description">{description}</p>}
    </header>
  )
}

/// A titled block of cards ("Изображение и звук"); `footer` is the small text under it.
export function Group({ title, busy, children, footer }: { title?: ReactNode; busy?: boolean; children: ReactNode; footer?: ReactNode }) {
  return (
    <section className="sgroup">
      {title && (
        <h2 className="sgroup__title">
          {title}
          {busy && <span className="spinner" style={{ width: 12, height: 12, borderWidth: 1.5 }} />}
        </h2>
      )}
      <div className="sgroup__items">{children}</div>
      {footer && <div className="sgroup__footer">{footer}</div>}
    </section>
  )
}

/// Rows inside one card, divided by lines (a setting with its sub-settings, a list of devices).
export function Card({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={'scard' + (className ? ' ' + className : '')}>{children}</div>
}

export interface RowProps {
  icon?: ReactNode
  title: ReactNode
  description?: ReactNode
  /// The control on the right (switch, button, select, value text).
  children?: ReactNode
  disabled?: boolean
  /// Content under the title line spanning the whole card (fields, lists).
  below?: ReactNode
  className?: string
}

export function Row({ icon, title, description, children, disabled, below, className }: RowProps) {
  return (
    <div className={'srow' + (disabled ? ' srow--disabled' : '') + (className ? ' ' + className : '')}>
      <div className="srow__main">
        {icon && <span className="srow__icon">{icon}</span>}
        <div className="srow__text">
          <div className="srow__title">{title}</div>
          {description && <div className="srow__description">{description}</div>}
        </div>
        {children !== undefined && children !== null && children !== false && <div className="srow__control">{children}</div>}
      </div>
      {below && <div className="srow__below">{below}</div>}
    </div>
  )
}

/// A value shown on the right of a row ("2304×1296", "1,2 ГБ · 13 видео").
export function Value({ children, mono, selectable }: { children: ReactNode; mono?: boolean; selectable?: boolean }) {
  return <span className={'srow__value tabular' + (mono ? ' mono' : '') + (selectable ? ' selectable' : '')}>{children}</span>
}

/// A radio row (Windows 11 radio button: ring with an accent dot), used for a choice whose options need a sentence each.
export function RadioRow({ checked, onSelect, title, description, disabled }: { checked: boolean; onSelect: () => void; title: ReactNode; description?: ReactNode; disabled?: boolean }) {
  return (
    <button type="button" role="radio" aria-checked={checked} className="srow sradio" disabled={disabled} onClick={onSelect}>
      <div className="srow__main">
        <span className="sradio__ring" aria-hidden />
        <div className="srow__text">
          <div className="srow__title">{title}</div>
          {description && <div className="srow__description">{description}</div>}
        </div>
      </div>
    </button>
  )
}

/// A native drop-down (combo box) with the kit's look.
export function Select<T extends string>({ value, options, onChange, disabled, label, width }: { value: T; options: { value: T; label: string }[]; onChange: (value: T) => void; disabled?: boolean; label?: string; width?: number }) {
  return (
    <select className="select" aria-label={label} value={value} disabled={disabled} style={{ minWidth: width ?? 200 }} onChange={(event) => onChange(event.target.value as T)}>
      {options.map((option) => (
        <option key={option.value} value={option.value}>
          {option.label}
        </option>
      ))}
    </select>
  )
}
