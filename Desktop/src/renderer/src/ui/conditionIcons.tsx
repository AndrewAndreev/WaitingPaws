// Icons of an exit's triggers, conditions and notes, drawn here (Fluent has no matching set): the SF-like line
// drawings of the Mac and iPhone apps on a 24 px grid, in currentColor. Sized by CSS like the Fluent icons
// (20 px by default). Imported through `icons.ts` by meaning.
import type { SVGProps } from 'react'

type IconProps = SVGProps<SVGSVGElement>

function Icon({ children, ...props }: IconProps) {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden {...props}>
      {children}
    </svg>
  )
}

/// ⚡ What to take or do on the way out («куртка», «звякнуть ключами»).
export function TriggerIcon(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M13.4 2.6 5.6 13.2h5.6l-1.2 8.2 7.9-10.8h-5.6l1.1-8z" fill="currentColor" stroke="none" />
    </Icon>
  )
}

/// 🏃 Coming back early: a figure on the move.
export function EarlyEntryIcon(props: IconProps) {
  return (
    <Icon {...props}>
      <circle cx="15.2" cy="4.3" r="2.1" fill="currentColor" stroke="none" />
      <path d="M13.3 8.6 10.9 14M13.3 8.6l-3.2 2-2.6-1.4M13.3 8.6l3 2.5 3.2-.4M10.9 14l3.6 2.6-.9 4.7M10.9 14l-3 3.4-2.4 3" />
    </Icon>
  )
}

/// 📝 The exit's note: a speech bubble with two lines.
export function ExitNoteIcon(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M4 5.5A2.5 2.5 0 0 1 6.5 3h11A2.5 2.5 0 0 1 20 5.5v8a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 4v-4h-.5A2.5 2.5 0 0 1 4 13.5z" />
      <path d="M8 8h8M8 11.5h5" />
    </Icon>
  )
}

/// ⛔ When not to come in (the trainer's 🚩): the «no entry» sign, SF `minus.circle.fill` on the Mac and iPhone.
export function DoNotEnterIcon(props: IconProps) {
  return (
    <Icon {...props}>
      <path
        d="M12 2.5a9.5 9.5 0 1 1 0 19 9.5 9.5 0 0 1 0-19zM7.2 10.7a1.3 1.3 0 0 0 0 2.6h9.6a1.3 1.3 0 0 0 0-2.6z"
        fill="currentColor"
        fillRule="evenodd"
        stroke="none"
      />
    </Icon>
  )
}

/// ➡️ What to do before the training (the trainer's preparation points).
export function PrepIcon(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M4 12h15M14 7l5 5-5 5" />
    </Icon>
  )
}

/// «Развернуть»: the trainer's text in a larger window.
export function ExpandIcon(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M14 4h6v6M10 20H4v-6M20 4l-7 7M4 20l7-7" />
    </Icon>
  )
}
