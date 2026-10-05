// Small UI kit on top of Radix primitives, styled by styles/base.css. One place for the look of buttons,
// menus, dialogs, tooltips and switches so screens stay consistent (Fluent-like, not macOS-like).
import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from 'react'
import { Dialog as RDialog, DropdownMenu as RMenu, Tooltip as RTooltip, ContextMenu as RContext } from 'radix-ui'
import { Checkmark16Regular as Check, ChevronRight16Regular as ChevronRight, Dismiss20Regular as X } from '@fluentui/react-icons'
import { t } from '@shared/i18n'

// ---------- Buttons ----------

type ButtonVariant = 'default' | 'primary' | 'subtle' | 'danger' | 'danger-solid' | 'link'
type ButtonSize = 'sm' | 'md' | 'lg' | 'xl'

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  size?: ButtonSize
  icon?: ReactNode
  /// Keyboard shortcut shown in a keycap at the end ("Ctrl+R", "Space").
  shortcut?: string
  block?: boolean
  iconOnly?: boolean
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = 'default', size = 'md', icon, shortcut, block, iconOnly, className, children, type = 'button', ...rest },
  ref,
) {
  const classes = ['btn']
  if (variant !== 'default') classes.push(`btn--${variant}`)
  if (size !== 'md') classes.push(`btn--${size}`)
  if (block) classes.push('btn--block')
  if (iconOnly) classes.push('btn--icon')
  if (className) classes.push(className)
  return (
    <button ref={ref} type={type} className={classes.join(' ')} {...rest}>
      {icon}
      {children !== undefined && children !== null && children !== false && (
        <span className={block ? 'grow ellipsis' : 'ellipsis'} style={block ? { textAlign: 'left' } : undefined}>
          {children}
        </span>
      )}
      {shortcut && <Kbd keys={shortcut} />}
    </button>
  )
})

/// "Ctrl+Shift+V" → a keycap. Keys are translated (Пробел/Space).
export function Kbd({ keys }: { keys: string }) {
  return <kbd className="kbd">{keys.split('+').map((key) => t(key)).join('+')}</kbd>
}

// ---------- Tooltip ----------

export function TooltipProvider({ children }: { children: ReactNode }) {
  return (
    <RTooltip.Provider delayDuration={500} skipDelayDuration={200}>
      {children}
    </RTooltip.Provider>
  )
}

export function Tooltip({ content, children, side = 'bottom' }: { content: ReactNode; children: ReactNode; side?: 'top' | 'bottom' | 'left' | 'right' }) {
  if (!content) return <>{children}</>
  return (
    <RTooltip.Root>
      <RTooltip.Trigger asChild>{children}</RTooltip.Trigger>
      <RTooltip.Portal>
        <RTooltip.Content className="tooltip" side={side} sideOffset={6} collisionPadding={8}>
          {content}
        </RTooltip.Content>
      </RTooltip.Portal>
    </RTooltip.Root>
  )
}

// ---------- Menus ----------

export const Menu = RMenu.Root
export const MenuTrigger = RMenu.Trigger

export function MenuContent({ children, align = 'start', side = 'bottom', className }: { children: ReactNode; align?: 'start' | 'center' | 'end'; side?: 'top' | 'bottom' | 'left' | 'right'; className?: string }) {
  return (
    <RMenu.Portal>
      <RMenu.Content className={'menu ' + (className ?? '')} align={align} side={side} sideOffset={4} collisionPadding={8} loop>
        {children}
      </RMenu.Content>
    </RMenu.Portal>
  )
}

export function MenuItem({
  icon,
  children,
  onSelect,
  shortcut,
  danger,
  disabled,
}: {
  icon?: ReactNode
  children: ReactNode
  onSelect?: () => void
  shortcut?: string
  danger?: boolean
  disabled?: boolean
}) {
  return (
    <RMenu.Item className={'menu__item' + (danger ? ' menu__item--danger' : '')} onSelect={onSelect} disabled={disabled}>
      <span className="menu__item-indicator-space">{icon}</span>
      <span className="grow ellipsis">{children}</span>
      {shortcut && <span className="menu__shortcut">{shortcut}</span>}
    </RMenu.Item>
  )
}

export function MenuCheckItem({ checked, children, onSelect, disabled }: { checked: boolean; children: ReactNode; onSelect: () => void; disabled?: boolean }) {
  return (
    <RMenu.Item
      className="menu__item"
      onSelect={(event) => {
        event.preventDefault()
        onSelect()
      }}
      disabled={disabled}
    >
      <span className="menu__check">{checked ? <Check /> : null}</span>
      <span className="grow ellipsis">{children}</span>
    </RMenu.Item>
  )
}

export function MenuSeparator() {
  return <RMenu.Separator className="menu__separator" />
}

export function MenuLabel({ children }: { children: ReactNode }) {
  return <RMenu.Label className="menu__label">{children}</RMenu.Label>
}

export function MenuNote({ children }: { children: ReactNode }) {
  return <div className="menu__note">{children}</div>
}

export function SubMenu({ icon, label, children }: { icon?: ReactNode; label: ReactNode; children: ReactNode }) {
  return (
    <RMenu.Sub>
      <RMenu.SubTrigger className="menu__item">
        <span className="menu__item-indicator-space">{icon}</span>
        <span className="grow ellipsis">{label}</span>
        <ChevronRight />
      </RMenu.SubTrigger>
      <RMenu.Portal>
        <RMenu.SubContent className="menu" sideOffset={4} collisionPadding={8}>
          {children}
        </RMenu.SubContent>
      </RMenu.Portal>
    </RMenu.Sub>
  )
}

// Context menus (right click) share the menu look.
export const ContextMenu = RContext.Root
export const ContextMenuTrigger = RContext.Trigger
export function ContextMenuContent({ children }: { children: ReactNode }) {
  return (
    <RContext.Portal>
      <RContext.Content className="menu" collisionPadding={8} loop>
        {children}
      </RContext.Content>
    </RContext.Portal>
  )
}
export function ContextMenuItem({ icon, children, onSelect, danger, disabled }: { icon?: ReactNode; children: ReactNode; onSelect?: () => void; danger?: boolean; disabled?: boolean }) {
  return (
    <RContext.Item className={'menu__item' + (danger ? ' menu__item--danger' : '')} onSelect={onSelect} disabled={disabled}>
      <span className="menu__item-indicator-space">{icon}</span>
      <span className="grow ellipsis">{children}</span>
    </RContext.Item>
  )
}
export function ContextMenuSeparator() {
  return <RContext.Separator className="menu__separator" />
}

// ---------- Dialogs ----------

export interface DialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  title?: ReactNode
  description?: ReactNode
  icon?: ReactNode
  width?: number | string
  height?: number | string
  children?: ReactNode
  footer?: ReactNode
  /// Hide the ✕ (dialogs that must be answered with a button).
  hideClose?: boolean
  bodyClassName?: string
  /// No padding / header: the content draws everything (large editors).
  bare?: boolean
}

export function Dialog({ open, onOpenChange, title, description, icon, width = 480, height, children, footer, hideClose, bodyClassName, bare }: DialogProps) {
  return (
    <RDialog.Root open={open} onOpenChange={onOpenChange}>
      <RDialog.Portal>
        <RDialog.Overlay className="dialog-scrim" />
        <RDialog.Content
          className="dialog"
          style={{ width, height }}
          aria-describedby={description ? undefined : undefined}
          // Focus goes to what the dialog asked for (`autoFocus`), else to the dialog itself — not to the ✕, which
          // Radix would pick as the first focusable element and draw with a focus ring.
          onOpenAutoFocus={(event) => {
            const content = event.currentTarget as HTMLElement
            event.preventDefault()
            requestAnimationFrame(() => {
              if (content.contains(document.activeElement) && !document.activeElement?.classList.contains('dialog__close')) return
              const wanted = content.querySelector<HTMLElement>('[data-autofocus], .dialog__footer .btn--primary')
              ;(wanted ?? content).focus({ preventScroll: true })
            })
          }}
          tabIndex={-1}
        >
          {bare ? (
            <>
              <RDialog.Title className="visually-hidden" style={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0 0 0 0)' }}>
                {title}
              </RDialog.Title>
              {children}
            </>
          ) : (
            <>
              {(title || !hideClose) && (
                <div className="dialog__header">
                  {icon}
                  <div className="grow">
                    {title && <RDialog.Title className="dialog__title">{title}</RDialog.Title>}
                    {description && <RDialog.Description className="dialog__description">{description}</RDialog.Description>}
                  </div>
                  {!hideClose && (
                    <RDialog.Close asChild>
                      <Button variant="subtle" iconOnly className="dialog__close" aria-label={t('Закрыть')}>
                        <X />
                      </Button>
                    </RDialog.Close>
                  )}
                </div>
              )}
              {children !== undefined && <div className={'dialog__body ' + (bodyClassName ?? '')}>{children}</div>}
              {footer && <div className="dialog__footer">{footer}</div>}
            </>
          )}
        </RDialog.Content>
      </RDialog.Portal>
    </RDialog.Root>
  )
}

// ---------- Form controls ----------

export function Switch({ checked, onChange, disabled, label }: { checked: boolean; onChange: (value: boolean) => void; disabled?: boolean; label?: string }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      className="switch"
      disabled={disabled}
      onClick={() => onChange(!checked)}
    />
  )
}

export function Segmented<T extends string>({ value, options, onChange, disabled }: { value: T; options: { value: T; label: ReactNode }[]; onChange: (value: T) => void; disabled?: boolean }) {
  return (
    <div className="segmented" role="group">
      {options.map((option) => (
        <button key={option.value} type="button" aria-pressed={option.value === value} disabled={disabled} onClick={() => onChange(option.value)}>
          {option.label}
        </button>
      ))}
    </div>
  )
}

export function Checkbox({ checked, onChange, children, disabled }: { checked: boolean; onChange: (value: boolean) => void; children: ReactNode; disabled?: boolean }) {
  return (
    <label className="checkbox" style={disabled ? { opacity: 0.5 } : undefined}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={(event) => onChange(event.target.checked)} />
      <span>{children}</span>
    </label>
  )
}

export function Spinner({ large }: { large?: boolean }) {
  return <span className={'spinner' + (large ? ' spinner--lg' : '')} aria-label={t('Загрузка')} />
}

export function InfoBar({ kind = 'info', icon, title, children, action }: { kind?: 'info' | 'warning' | 'danger' | 'neutral'; icon?: ReactNode; title?: ReactNode; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className={'infobar' + (kind !== 'neutral' ? ` infobar--${kind}` : '')}>
      {icon}
      <div className="grow">
        {title && <div style={{ fontWeight: 600 }}>{title}</div>}
        {children && <div className="muted" style={{ fontSize: 13 }}>{children}</div>}
      </div>
      {action}
    </div>
  )
}
